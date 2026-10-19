defmodule Canopy.Codex.Approvals do
  @moduledoc """
  Codex's approval and question requests as Canopy cards, and the cards'
  replies as JSON-RPC results (§7 of the design).

  `handle/3` takes one server request and decides:

    * `{:answer, result}` — Canopy answers it itself, with no card: the
      ask-first allowance (`Canopy.Codex.Allowance`), a remembered Always
      rule, or plan mode's refusals (file changes, write access);
    * `{:card, request}` — an `:approval_required` card request, in the shape
      of the contract (§3.6): `permission` `"Bash"`, `"file_change"`,
      `"permissions"` or `"mcp__<server>__<tool>"`, with `metadata["action"]`;
    * `{:question, request}` — a `:question_required` card request;
    * `{:error, code, message}` — a request Canopy does not support.

  `result/3` maps a card's reply (`:once | :always | :global | :reject |
  :expired`) to the result Codex reads, plus the rule an Always remembers.

  Plan agents' command cards are `once_only`: their command would run
  outside the read-only sandbox, so Always and Allow globally are answered as
  Once, and no remembered rule answers one without a card.

  A command rule remembers whether its card was `unsandboxed`: in
  `acceptEdits` Codex asks only to run a command outside the sandbox, so only
  a rule from such a card answers it there. An Always given in ask-first mode
  (where the command ran sandboxed) never widens into an unsandboxed run.

  A git command outside the ask-first allowlist (`git push`) can never be
  matched by a rule (§7.4), so its card is `no_always`: Always is answered as
  Once and nothing is remembered.

  `acceptForSession` lasts only as long as one app-server process, and every
  turn is its own process, so Always rules are kept here, per engine session,
  for as long as Canopy runs (the counterpart of Claude Code's
  `Prompts.always_list/1`). This module is also that store: an Agent started
  by `Canopy.Codex.Supervisor`.
  """

  use Agent

  alias Canopy.Codex.Allowance

  @diff_max 4_000

  @type ctx :: %{
          required(:session_id) => String.t(),
          required(:card_prefix) => String.t(),
          required(:permission_mode) => String.t(),
          required(:repository_path) => String.t(),
          optional(:items) => map(),
          optional(:rules) => [term()]
        }

  # -- The Always store ----------------------------------------------------------------

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "The Always rules remembered for an engine session."
  def rules(session_id) do
    Agent.get(__MODULE__, &Map.get(&1, session_id, []))
  catch
    :exit, _ -> []
  end

  @doc "Remembers an Always rule for the session."
  def remember(_session_id, nil), do: :ok

  def remember(session_id, rule) do
    Agent.update(__MODULE__, fn rules ->
      Map.update(rules, session_id, [rule], &Enum.uniq(&1 ++ [rule]))
    end)
  catch
    :exit, _ -> :ok
  end

  @doc "Moves a session's rules to its new id (the thread id rename)."
  def rename(old, new) do
    Agent.update(__MODULE__, fn rules ->
      case Map.pop(rules, old) do
        {nil, rules} -> rules
        {list, rules} -> Map.update(rules, new, list, &Enum.uniq(&1 ++ list))
      end
    end)
  catch
    :exit, _ -> :ok
  end

  @doc "Forgets a session's rules (its session was reset)."
  def forget(session_id) do
    Agent.update(__MODULE__, &Map.delete(&1, session_id))
  catch
    :exit, _ -> :ok
  end

  # -- Requests ------------------------------------------------------------------------

  @doc "Decides one server request; see the moduledoc."
  def handle(method, rpc_id, params, ctx)

  def handle("item/commandExecution/requestApproval", rpc_id, params, ctx) do
    raw = params["command"] || ""
    words = Allowance.simple_words(raw)
    mode = ctx.permission_mode
    prefix = always_prefix(params, raw)

    cond do
      mode == "plan" ->
        {:card, command_card(rpc_id, params, ctx, prefix)}

      mode == "default" and Allowance.plain_git?(raw) ->
        {:answer, %{"decision" => "accept"}}

      command_rule?(ctx_rules(ctx), words, mode) ->
        {:answer, %{"decision" => "acceptForSession"}}

      true ->
        {:card, command_card(rpc_id, params, ctx, prefix)}
    end
  end

  def handle("item/fileChange/requestApproval", rpc_id, params, ctx) do
    changes = changes(ctx, params["itemId"])
    abs_paths = for c <- changes, is_binary(c["path"]), do: c["path"]
    repo = ctx.repository_path

    cond do
      ctx.permission_mode == "plan" ->
        {:answer, %{"decision" => "decline"}}

      ctx.permission_mode == "default" and Allowance.in_repo_files?(abs_paths, repo) ->
        {:answer, %{"decision" => "accept"}}

      :file_change in ctx_rules(ctx) and Allowance.in_repo_files?(abs_paths, repo) ->
        {:answer, %{"decision" => "acceptForSession"}}

      true ->
        paths = Enum.map(abs_paths, &Allowance.display_path(&1, repo))

        metadata =
          %{
            "action" => "file_change",
            "paths" => paths,
            "outside_repo" => Enum.any?(abs_paths, &(not Allowance.inside?(&1, repo))),
            "reason" => reason(params["reason"], params["grantRoot"], repo),
            "diff" => diff(changes, repo)
          }
          |> reject_nil()

        {:card, card(rpc_id, ctx, params, "file_change", paths, metadata)}
    end
  end

  def handle("item/permissions/requestApproval", rpc_id, params, ctx) do
    profile = params["permissions"] || %{}
    repo = ctx.repository_path
    {read, write} = profile_paths(profile)
    network? = get_in(profile, ["network", "enabled"]) == true

    cond do
      ctx.permission_mode == "plan" and write != [] ->
        {:answer, %{"permissions" => %{}, "scope" => "turn"}}

      Enum.any?(ctx_rules(ctx), &covers_permissions?(&1, profile)) ->
        {:answer, %{"permissions" => granted(profile), "scope" => "session"}}

      true ->
        paths = Enum.map(Enum.uniq(read ++ write), &Allowance.display_path(&1, repo))

        metadata =
          %{
            "action" => "permissions",
            "network" => network?,
            "paths" => paths,
            "reason" => params["reason"]
          }
          |> reject_nil()

        {:card, card(rpc_id, ctx, params, "permissions", paths, metadata)}
    end
  end

  # A tool approval for one of the user's own MCP servers (Canopy's never ask).
  def handle("mcpServer/elicitation/request", rpc_id, params, ctx) do
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}

    case meta["codex_approval_kind"] do
      "mcp_tool_call" ->
        server = params["serverName"] || "mcp"
        tool = pending_mcp_tool(ctx, server) || meta["tool_name"] || "tool"

        if {:mcp_tool, server, tool} in ctx_rules(ctx) do
          {:answer, %{"action" => "accept", "content" => nil}}
        else
          request = %{
            "id" => card_id(ctx, rpc_id),
            "permission" => "mcp__#{server}__#{tool}",
            "patterns" => [],
            "metadata" => %{"input" => meta["tool_params"] || %{}},
            "tool" => %{"callID" => meta["call_id"] || card_id(ctx, rpc_id)}
          }

          {:card, request}
        end

      _ ->
        {:answer, %{"action" => "decline", "content" => nil}}
    end
  end

  def handle("item/tool/requestUserInput", rpc_id, params, ctx) do
    questions =
      for q <- List.wrap(params["questions"]), is_map(q) do
        %{
          "id" => q["id"],
          "question" => q["question"] || "",
          "header" => q["header"],
          "options" =>
            for o <- List.wrap(q["options"]), is_map(o) do
              %{"label" => o["label"] || "", "description" => o["description"]}
            end,
          "multiple" => false,
          "custom" => q["isOther"] == true,
          "secret" => q["isSecret"] == true
        }
      end

    case questions do
      [] ->
        {:answer, %{"answers" => %{}}}

      _ ->
        {:question,
         %{
           "id" => card_id(ctx, rpc_id),
           "questions" => questions,
           "tool" => %{"callID" => params["itemId"] || card_id(ctx, rpc_id)}
         }}
    end
  end

  def handle(_method, _rpc_id, _params, _ctx),
    do: {:error, -32601, "not supported by Canopy"}

  # -- Replies -------------------------------------------------------------------------

  @doc """
  The result for a card's reply and the Always rule it remembers (nil when
  none). `kind` is the card request's permission; `request` the card request
  map; `params` Codex's original params.
  """
  def result(request, params, reply)

  def result(%{"permission" => "Bash"} = request, params, reply) do
    reply = once_only(request, reply)
    reply = if no_always?(request) and reply == :always, do: :once, else: reply

    case reply do
      :always ->
        {%{"decision" => "acceptForSession"}, command_rule(params, unsandboxed?(request))}

      r when r in [:once, :global] ->
        {%{"decision" => "accept"}, nil}

      _ ->
        {%{"decision" => "decline"}, nil}
    end
  end

  def result(%{"permission" => "file_change"}, _params, reply) do
    case reply do
      :always -> {%{"decision" => "acceptForSession"}, :file_change}
      r when r in [:once, :global] -> {%{"decision" => "accept"}, nil}
      _ -> {%{"decision" => "decline"}, nil}
    end
  end

  def result(%{"permission" => "permissions"}, params, reply) do
    profile = params["permissions"] || %{}

    case reply do
      :always ->
        {%{"permissions" => granted(profile), "scope" => "session"}, {:permissions, profile}}

      r when r in [:once, :global] ->
        {%{"permissions" => granted(profile), "scope" => "turn"}, nil}

      _ ->
        {%{"permissions" => %{}, "scope" => "turn"}, nil}
    end
  end

  def result(%{"permission" => "mcp__" <> name}, params, reply) do
    case reply do
      r when r in [:once, :global] ->
        {%{"action" => "accept", "content" => nil}, nil}

      :always ->
        server = params["serverName"] || "mcp"
        tool = String.replace_prefix(name, server <> "__", "")
        {%{"action" => "accept", "content" => nil}, {:mcp_tool, server, tool}}

      _ ->
        {%{"action" => "decline", "content" => nil}, nil}
    end
  end

  def result(_request, _params, _reply), do: {%{"decision" => "decline"}, nil}

  @doc "A reply as Canopy treats it on a once-only card: Always and Allow globally count as Once."
  def once_only(%{"metadata" => %{"once_only" => true}}, reply) when reply in [:always, :global],
    do: :once

  def once_only(_request, reply), do: reply

  @doc "Whether a permission card request is once-only (a plan agent's command)."
  def once_only?(request), do: get_in(request, ["metadata", "once_only"]) == true

  @doc "Whether a command card offers no Always (a git command no rule can match)."
  def no_always?(request), do: get_in(request, ["metadata", "no_always"]) == true

  defp unsandboxed?(request), do: get_in(request, ["metadata", "unsandboxed"]) == true

  @doc """
  Whether Always can remember `prefix` usefully: a git prefix must itself be
  a plain git command, or no later command could match it (§7.4).
  """
  def rememberable_prefix?(["git" | _] = prefix), do: Allowance.plain_git_words?(prefix)
  def rememberable_prefix?(_prefix), do: true

  @doc "The answer to a question card."
  def question_result(request, {:answered, answers}) do
    ids = for q <- request["questions"], do: q["id"]

    map =
      ids
      |> Enum.zip(List.wrap(answers))
      |> Map.new(fn {id, labels} -> {id, %{"answers" => List.wrap(labels)}} end)

    %{"answers" => map}
  end

  def question_result(request, :rejected),
    do: all_answers(request, "The user declined to answer.")

  def question_result(request, :expired),
    do:
      all_answers(
        request,
        "The user hasn't answered yet. The question stays open in the channel. " <>
          "End your turn now; their answer will reach you as a new message."
      )

  defp all_answers(request, text),
    do: %{
      "answers" => Map.new(request["questions"], &{&1["id"], %{"answers" => [text]}})
    }

  # -- Rules ---------------------------------------------------------------------------

  @doc """
  What Always on a command remembers: the proposed execpolicy prefix when it
  has at least two words, else the command's first two words (or its only one).
  """
  def always_prefix(params, raw \\ nil) do
    raw = raw || params["command"] || ""
    proposed = for w <- List.wrap(params["proposedExecpolicyAmendment"]), is_binary(w), do: w

    cond do
      length(proposed) >= 2 ->
        proposed

      true ->
        case Allowance.lex(Allowance.unwrap(raw) || raw) do
          {:ok, [_ | _] = words} -> Enum.take(words, 2)
          _ -> [Allowance.unwrap(raw) || raw]
        end
    end
  end

  @doc """
  The rule an Always on a command card remembers: the prefix, and whether the
  card was for a command outside the sandbox.
  """
  def command_rule(params, unsandboxed?), do: {:command, always_prefix(params), unsandboxed?}

  # In acceptEdits every request is to run outside the sandbox, so only a rule
  # from an unsandboxed card answers it.
  defp command_rule?(rules, {:ok, words}, mode) do
    Enum.any?(rules, fn
      {:command, prefix, unsandboxed?} ->
        (mode != "acceptEdits" or unsandboxed?) and List.starts_with?(words, prefix) and
          (not match?(["git" | _], prefix) or Allowance.plain_git_words?(words))

      _ ->
        false
    end)
  end

  defp command_rule?(_rules, :error, _mode), do: false

  # A remembered more-access grant covers a request asking for nothing beyond it.
  defp covers_permissions?({:permissions, granted}, asked) do
    {gr, gw} = profile_paths(granted)
    {ar, aw} = profile_paths(asked)
    granted_net = get_in(granted, ["network", "enabled"]) == true
    asked_net = get_in(asked, ["network", "enabled"]) == true

    (not asked_net or granted_net) and Enum.all?(aw, &(&1 in gw)) and
      Enum.all?(ar, &(&1 in gr or &1 in gw))
  end

  defp covers_permissions?(_rule, _asked), do: false

  defp ctx_rules(%{rules: rules}) when is_list(rules), do: rules
  defp ctx_rules(%{session_id: sid}), do: rules(sid)

  # -- Cards ---------------------------------------------------------------------------

  defp command_card(rpc_id, params, ctx, prefix) do
    raw = params["command"] || ""
    command = display_command(params, raw)
    mode = ctx.permission_mode

    metadata =
      %{
        "action" => "command",
        "command" => command,
        "reason" => params["reason"],
        "cwd" => params["cwd"] && Allowance.display_path(params["cwd"], ctx.repository_path),
        "always_prefix" => Enum.join(prefix, " ")
      }
      |> put_if(params["networkApprovalContext"] != nil, "network", true)
      |> put_if(mode in ["acceptEdits", "plan"], "unsandboxed", true)
      |> put_if(mode == "plan", "once_only", true)
      |> put_if(mode != "plan" and not rememberable_prefix?(prefix), "no_always", true)
      |> reject_nil()

    card(rpc_id, ctx, params, "Bash", [command], metadata)
  end

  @doc "The command as a card shows it: Codex's parsed actions, else the unwrapped command."
  def display_command(params, raw \\ nil) do
    raw = raw || params["command"] || ""

    case for(%{"command" => c} <- List.wrap(params["commandActions"]), is_binary(c), do: c) do
      [] -> Allowance.unwrap(raw) || raw
      commands -> Enum.join(commands, " && ")
    end
  end

  defp card(rpc_id, ctx, params, permission, patterns, metadata) do
    %{
      "id" => card_id(ctx, rpc_id),
      "permission" => permission,
      "patterns" => patterns,
      "metadata" => metadata,
      "tool" => %{"callID" => params["itemId"]}
    }
  end

  @doc "The card id: unique across processes, turns and restarts."
  def card_id(ctx, rpc_id), do: "#{ctx.card_prefix}-#{rpc_id}"

  defp changes(ctx, item_id) do
    case get_in(ctx, [:items, item_id]) do
      %{"changes" => changes} when is_list(changes) -> for c <- changes, is_map(c), do: c
      _ -> []
    end
  end

  defp pending_mcp_tool(ctx, server) do
    (ctx[:items] || %{})
    |> Map.values()
    |> Enum.filter(&match?(%{"type" => "mcpToolCall", "server" => ^server}, &1))
    |> List.last()
    |> case do
      %{"tool" => tool} when is_binary(tool) -> tool
      _ -> nil
    end
  end

  defp reason(reason, nil, _repo), do: reason

  defp reason(reason, root, repo) when is_binary(root) do
    grant =
      "asks to write under #{Allowance.display_path(root, repo)} for the rest of the session"

    if is_binary(reason) and reason != "", do: reason <> " (" <> grant <> ")", else: grant
  end

  defp reason(reason, _root, _repo), do: reason

  # read and write paths of a requested (or granted) profile
  defp profile_paths(profile) do
    fs = profile["fileSystem"] || %{}

    entries =
      for %{"path" => %{"type" => "path", "path" => p}, "access" => access} <-
            List.wrap(fs["entries"]),
          is_binary(p),
          do: {access, p}

    read = strings(fs["read"]) ++ for({"read", p} <- entries, do: p)
    write = strings(fs["write"]) ++ for({"write", p} <- entries, do: p)
    {Enum.uniq(read), Enum.uniq(write)}
  end

  defp strings(list), do: for(s <- List.wrap(list), is_binary(s), do: s)

  # What Codex is granted when the user allows a more-access request: what it asked.
  defp granted(profile) do
    %{}
    |> put_if(is_map(profile["network"]), "network", profile["network"])
    |> put_if(is_map(profile["fileSystem"]), "fileSystem", profile["fileSystem"])
  end

  @doc """
  The proposed change as a unified diff, per file: Codex sends one for an
  update only, so an add is every line `+` and a delete every line `-`.
  Capped at #{@diff_max} characters.
  """
  def diff(changes, repo) do
    text =
      changes
      |> Enum.map(fn change ->
        path = Allowance.display_path(change["path"] || "file", repo)
        body = change["diff"] || ""

        case get_in(change, ["kind", "type"]) do
          "add" ->
            Enum.join(["--- /dev/null", "+++ " <> path | prefix_lines(body, "+")], "\n")

          "delete" ->
            Enum.join(["--- " <> path, "+++ /dev/null" | prefix_lines(body, "-")], "\n")

          _ ->
            if String.starts_with?(body, ["---", "diff "]),
              do: String.trim_trailing(body),
              else: Enum.join(["--- " <> path, "+++ " <> path, String.trim_trailing(body)], "\n")
        end
      end)
      |> Enum.join("\n")

    case text do
      "" -> nil
      text -> String.slice(text, 0, @diff_max)
    end
  end

  defp prefix_lines(body, prefix) do
    body
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map(&(prefix <> &1))
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _cond, _key, _value), do: map

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
