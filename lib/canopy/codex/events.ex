defmodule Canopy.Codex.Events do
  @moduledoc """
  Normalizes `codex app-server` notifications into `Canopy.Engine.Event`s
  (§6 of the design). Stateful across one turn, and pure.

  Tool names are chosen for `Canopy.Runtime.Activity`: a command is `bash`,
  a file change `apply_patch`, an MCP call `mcp__<server>__<tool>`, a web
  search `websearch`, so the activity code needs no Codex branch.

  ## Usage

  `thread/tokenUsage/updated` carries `total`, the thread's running total
  (restored on resume), and the same update can arrive twice. So each step's
  tokens are the change in `total` since the last update of this turn, and a
  zero change (a duplicate) emits nothing. Right after `thread/resume`, Codex
  replays the previous turn's totals under that turn's id: an update for
  another turn sets the base the turn counts from and is never counted. At
  `turn/completed` the turn's usage is `total − base`, priced with
  `Canopy.Codex.Pricing` and marked `cost_estimated: true`.
  """

  alias Canopy.Codex.{Allowance, Approvals, Pricing}
  alias Canopy.Engine.Event

  @zero %{
    "totalTokens" => 0,
    "inputTokens" => 0,
    "cachedInputTokens" => 0,
    "cacheWriteInputTokens" => 0,
    "outputTokens" => 0,
    "reasoningOutputTokens" => 0
  }

  @work_items ~w(commandExecution mcpToolCall fileChange webSearch dynamicToolCall collabAgentToolCall)

  @doc "The token breakdown Codex reports, all zero."
  def zero, do: @zero

  @doc """
  A fresh accumulator. `cwd` is the repository path (display paths); options:
  `:model`, the model the turn runs on (for pricing).
  """
  def new(cwd \\ nil, opts \\ []) do
    %{
      cwd: cwd,
      model: Keyword.get(opts, :model),
      turn_id: nil,
      base: nil,
      prev: nil,
      steps: 0,
      context: 0,
      # item id => the item as last seen (inputs for completion, changes for approvals)
      items: %{},
      # work items started and not completed (the stall rule)
      open: MapSet.new(),
      mcp: %{},
      mcp_sent?: false,
      error: nil,
      # the account's rate-limit snapshot (`account/rateLimits/updated`),
      # merged as it arrives: where a usage limit's reset time comes from
      rate_limits: nil
    }
  end

  @doc "Whether the snapshot so far has a rate-limit window with a reset time."
  def rate_limit_windows?(acc), do: windows(Map.get(acc, :rate_limits)) != []

  @doc "Merges a `RateLimitSnapshot` (sparse, rolling) into the accumulator."
  def merge_rate_limits(acc, %{} = snapshot) do
    merged =
      Map.merge(Map.get(acc, :rate_limits) || %{}, snapshot, fn
        _key, %{} = old, %{} = new -> Map.merge(old, new)
        _key, _old, new -> new
      end)

    Map.put(acc, :rate_limits, merged)
  end

  def merge_rate_limits(acc, _snapshot), do: acc

  @doc """
  Whether a failed `turn/completed` is a plan usage limit or an API quota
  (`codexErrorInfo`), the failure a reset time is looked up for. The error
  is the turn's, else the one the `error` notification left in `acc`, as
  `normalize/3` reads it.
  """
  def limit_failure?(%{"turn" => %{"status" => "failed"} = turn}, acc) do
    case turn["error"] || Map.get(acc, :error) do
      %{} = error ->
        error_name(error["codexErrorInfo"]) in ["usageLimitExceeded", "insufficient_quota"]

      _ ->
        false
    end
  end

  def limit_failure?(_params, _acc), do: false

  @doc "The `:session_updated` event for a `thread/start` or `thread/resume` response."
  def session_event(response, extra \\ %{}) do
    thread = response["thread"] || %{}

    session =
      %{
        "model" => response["model"] || thread["model"],
        "version" => thread["cliVersion"],
        "sandbox" => sandbox_name(response["sandbox"]),
        "approval" => response["approvalPolicy"]
      }
      |> Map.merge(extra)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    event(:session_updated, %{session: session})
  end

  defp sandbox_name(%{"type" => type}), do: type
  defp sandbox_name(other) when is_binary(other), do: other
  defp sandbox_name(_), do: nil

  @doc "Notes the turn id (from the `turn/start` response, before `turn/started`)."
  def put_turn(acc, turn_id), do: %{acc | turn_id: turn_id}

  @doc "Whether a work item is in flight (the Turn pauses its stall window)."
  def item_open?(acc), do: MapSet.size(acc.open) > 0

  @doc "The turn's error kept from an `error` notification, if any."
  def error(acc), do: acc.error

  @spec normalize(String.t(), map(), map()) :: {[Event.t()], map()}
  def normalize(method, params, acc)

  def normalize("turn/started", params, acc) do
    turn_id = get_in(params, ["turn", "id"]) || acc.turn_id
    acc = %{acc | turn_id: turn_id}

    {[event(:agent_status, %{status: :busy, raw: params})] ++ mcp_event(acc),
     %{acc | mcp_sent?: true}}
  end

  def normalize("mcpServer/startupStatus/updated", %{"name" => name} = params, acc)
      when is_binary(name) do
    acc = %{acc | mcp: Map.put(acc.mcp, name, mcp_status(params))}

    # After turn/started a late status still reaches the inventory.
    if acc.mcp_sent? and params["status"] in ["ready", "failed"],
      do: {mcp_event(acc), acc},
      else: {[], acc}
  end

  def normalize("item/agentMessage/delta", params, acc) do
    case params["delta"] do
      delta when is_binary(delta) and delta != "" ->
        {[
           event(:text_delta, %{
             message_id: acc.turn_id || params["turnId"],
             part_id: params["itemId"],
             delta: delta
           })
         ], acc}

      _ ->
        {[], acc}
    end
  end

  def normalize("item/started", %{"item" => %{"id" => id, "type" => type} = item} = params, acc) do
    acc = %{acc | items: Map.put(acc.items, id, item)}
    acc = if type in @work_items, do: %{acc | open: MapSet.put(acc.open, id)}, else: acc

    case tool(item, acc) do
      nil ->
        {[], acc}

      {tool, input, title} ->
        {[
           event(:tool_started, %{
             call_id: id,
             tool: tool,
             status: :running,
             input: input,
             title: title,
             time: time("start", params["startedAtMs"]),
             message_id: acc.turn_id,
             part_id: id
           })
         ], acc}
    end
  end

  def normalize("item/completed", %{"item" => %{"id" => id, "type" => type} = item} = params, acc) do
    started = Map.get(acc.items, id, %{})
    acc = %{acc | items: Map.put(acc.items, id, item), open: MapSet.delete(acc.open, id)}
    {completed(type, item, started, params, acc), acc}
  end

  def normalize("turn/diff/updated", %{"diff" => diff}, acc) when is_binary(diff) do
    case diff_files(diff) do
      [] -> {[], acc}
      files -> {[event(:diff, %{files: files})], acc}
    end
  end

  def normalize("thread/tokenUsage/updated", %{"tokenUsage" => usage} = params, acc)
      when is_map(usage) do
    total = breakdown(usage["total"])

    cond do
      # another turn's totals once this turn has counted: never counted
      (params["turnId"] != acc.turn_id or acc.turn_id == nil) and acc.steps > 0 ->
        {[], acc}

      # the totals replayed after resume (or before the turn is known): the base
      params["turnId"] != acc.turn_id or acc.turn_id == nil ->
        {[], %{acc | base: total, prev: total}}

      true ->
        prev = acc.prev || acc.base || @zero
        delta = subtract(total, prev)
        context = max(acc.context, number(get_in(usage, ["last", "inputTokens"])))
        acc = %{acc | prev: total, base: acc.base || @zero, context: context}

        if delta["totalTokens"] > 0 do
          n = acc.steps + 1
          step_tokens = tokens(delta)

          {[
             event(:step_completed, %{
               message_id: acc.turn_id,
               part_id: "usage-#{n}",
               reason: "completed",
               # the step's own estimate, for the activity card; the turn's
               # cost comes from :turn_usage, never a sum of these
               cost: Pricing.cost(acc.model, step_tokens),
               cost_estimated: true,
               tokens: step_tokens,
               context_window: usage["modelContextWindow"],
               snapshot: nil
             })
           ], %{acc | steps: n}}
        else
          {[], acc}
        end
    end
  end

  def normalize("error", %{"error" => error} = params, acc) when is_map(error) do
    if params["willRetry"] == true do
      {[event(:agent_status, %{status: :retry, raw: retry_raw(error)})], acc}
    else
      {[], %{acc | error: error}}
    end
  end

  def normalize("model/rerouted", %{"toModel" => model}, acc) when is_binary(model),
    do: {[event(:session_updated, %{session: %{"model" => model}})], %{acc | model: model}}

  def normalize("account/rateLimits/updated", %{"rateLimits" => snapshot}, acc),
    do: {[], merge_rate_limits(acc, snapshot)}

  def normalize("turn/completed", %{"turn" => turn}, acc) when is_map(turn) do
    status = turn["status"]
    usage = turn_usage(acc, status)

    outcome =
      case status do
        "failed" ->
          raw = turn["error"] || acc.error
          event(:agent_error, %{error: error_map(raw), limit: limit(raw, acc)})

        _ ->
          event(:agent_completed, %{})
      end

    {[usage, outcome], acc}
  end

  def normalize(_method, _params, acc), do: {[], acc}

  @doc "The turn's `:turn_usage`: its tokens since the base, priced as an estimate."
  def turn_usage(acc, finish) do
    used = subtract(acc.prev || acc.base || @zero, acc.base || @zero)
    tokens = tokens(used)

    event(:turn_usage, %{
      message_id: acc.turn_id,
      cost: Pricing.cost(acc.model, tokens),
      cost_estimated: true,
      tokens: tokens,
      finish: finish
    })
  end

  # -- Limits -----------------------------------------------------------------------

  @doc """
  The usage or billing limit a failed turn's error stands for, or nil: a
  plan usage limit (`usageLimitExceeded`) or an API quota
  (`insufficient_quota`), with its reset time from the rate-limit snapshot:
  the latest `resetsAt` among the windows used up (`usedPercent >= 100`),
  else the earliest window's.
  """
  def limit(%{} = error, acc) do
    name = error_name(error["codexErrorInfo"])

    if name in ["usageLimitExceeded", "insufficient_quota"] do
      snapshot = Map.get(acc, :rate_limits) || %{}
      all = windows(snapshot)
      full = Enum.filter(all, &(number(&1["usedPercent"]) >= 100))

      window =
        case full do
          [] -> Enum.min_by(all, &number(&1["resetsAt"]), fn -> nil end)
          full -> Enum.max_by(full, &number(&1["resetsAt"]))
        end

      {kind, reason} = limit_kind(name, snapshot, window)

      %{
        kind: kind,
        reason: reason,
        resets_at: window && Canopy.EnginePauses.epoch(window["resetsAt"]),
        detail: error_message(error)
      }
    end
  end

  def limit(_error, _acc), do: nil

  defp windows(%{} = snapshot) do
    for key <- ["primary", "secondary"],
        %{"resetsAt" => at} = window <- [snapshot[key]],
        is_integer(at),
        do: window
  end

  defp windows(_), do: []

  defp limit_kind("insufficient_quota", _snapshot, _window),
    do: {"billing", "insufficient balance"}

  defp limit_kind(_name, snapshot, window) do
    reached = snapshot["rateLimitReachedType"]

    cond do
      is_binary(reached) and String.ends_with?(reached, "credits_depleted") ->
        {"billing", "insufficient balance"}

      is_map(window) and number(window["windowDurationMins"]) >= 7 * 24 * 60 ->
        {"usage", "weekly usage limit"}

      true ->
        {"usage", "usage limit"}
    end
  end

  @doc "Codex's turn error as Canopy's error map (`name`, `data.message`)."
  def error_map(%{} = error) do
    %{
      "name" => error_name(error["codexErrorInfo"]),
      "data" => %{"message" => error_message(error)}
    }
  end

  def error_map(_), do: %{"name" => "codex", "data" => %{"message" => "the turn failed"}}

  defp error_message(error) do
    case error["codexErrorInfo"] do
      "unauthorized" -> "Codex is not signed in: run `codex login`"
      _ -> error["message"] || "the turn failed"
    end
  end

  @doc "The `codexErrorInfo` variant's name: a string, or the key of a one-key map."
  def error_name(name) when is_binary(name), do: name
  def error_name(%{} = map) when map_size(map) == 1, do: map |> Map.keys() |> hd()
  def error_name(_), do: "codex"

  defp retry_raw(error) do
    %{"message" => error["message"], "name" => error_name(error["codexErrorInfo"])}
  end

  @doc "Token buckets in Canopy's shape, from a Codex `TokenUsageBreakdown`."
  def tokens(%{} = b) do
    input = number(b["inputTokens"])
    cached = number(b["cachedInputTokens"])

    %{
      "input" => max(input - cached, 0),
      "output" => number(b["outputTokens"]),
      "reasoning" => number(b["reasoningOutputTokens"]),
      "cache" => %{"read" => cached, "write" => number(b["cacheWriteInputTokens"])}
    }
  end

  @doc "A breakdown with every field present."
  def breakdown(%{} = b), do: Map.new(@zero, fn {k, _} -> {k, number(b[k])} end)
  def breakdown(_), do: @zero

  @doc "`a − b`, field by field, never below zero."
  def subtract(a, b),
    do: Map.new(@zero, fn {k, _} -> {k, max(number(a[k]) - number(b[k]), 0)} end)

  # -- Items --------------------------------------------------------------------------

  defp tool(%{"type" => "commandExecution"} = item, _acc) do
    cmd = command_text(item)
    {"bash", %{"command" => cmd}, cmd}
  end

  defp tool(%{"type" => "fileChange"} = item, acc) do
    paths = for c <- List.wrap(item["changes"]), is_binary(c["path"]), do: display(c["path"], acc)
    {"apply_patch", %{"files" => paths}, title_files(paths)}
  end

  defp tool(%{"type" => "mcpToolCall", "server" => server, "tool" => name} = item, _acc) do
    args = if is_map(item["arguments"]), do: item["arguments"], else: %{}
    {"mcp__#{server}__#{name}", args, "#{server} #{name}"}
  end

  defp tool(%{"type" => "webSearch"} = item, _acc) do
    query = item["query"] || ""
    {"websearch", %{"query" => query}, if(query == "", do: "web search", else: query)}
  end

  defp tool(%{"type" => "dynamicToolCall", "tool" => name} = item, _acc) when is_binary(name) do
    args = if is_map(item["arguments"]), do: item["arguments"], else: %{}
    {name, args, name}
  end

  defp tool(%{"type" => "collabAgentToolCall"} = item, _acc),
    do: {"agent", %{"tool" => item["tool"]}, "agent"}

  defp tool(_item, _acc), do: nil

  defp completed("agentMessage", item, _started, _params, acc) do
    case item["text"] do
      text when is_binary(text) and text != "" ->
        [event(:text_done, %{message_id: acc.turn_id, part_id: item["id"], text: text})]

      _ ->
        []
    end
  end

  defp completed("contextCompaction", _item, _started, _params, _acc),
    do: [event(:message_updated, %{message: %{"compact" => %{}}})]

  defp completed("commandExecution", item, started, params, acc) do
    status = item["status"]
    exit_code = item["exitCode"]
    ok? = status == "completed" and exit_code in [0, nil]
    output = item["aggregatedOutput"]
    {tool, input, title} = tool(Map.merge(started, item), acc)

    data =
      %{
        call_id: item["id"],
        tool: tool,
        status: if(ok?, do: :ok, else: :error),
        input: input,
        title: title,
        output: output,
        stdout: output,
        error: if(not ok?, do: command_error(status, exit_code, output)),
        exit_code: exit_code,
        denied: if(status == "declined", do: true),
        time: duration_time(params["completedAtMs"], item["durationMs"]),
        message_id: acc.turn_id,
        part_id: item["id"]
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.put_new(:output, nil)
      |> Map.put_new(:error, nil)

    [event(:tool_completed, data)]
  end

  defp completed("fileChange", item, started, params, acc) do
    changes = List.wrap(item["changes"] || started["changes"])
    {tool, input, title} = tool(Map.merge(started, item), acc)
    status = item["status"]
    ok? = status == "completed"
    patch = Approvals.diff(changes, acc.cwd)
    {adds, dels} = count_lines(patch)

    data =
      %{
        call_id: item["id"],
        tool: tool,
        status: if(ok?, do: :ok, else: :error),
        input: input,
        title: title,
        output: nil,
        error: if(not ok?, do: "file change #{status || "failed"}"),
        denied: if(status == "declined", do: true),
        patch: patch,
        adds: adds,
        dels: dels,
        time: time("end", params["completedAtMs"]),
        message_id: acc.turn_id,
        part_id: item["id"]
      }
      |> Map.reject(fn {k, v} -> is_nil(v) and k not in [:output, :error] end)

    changed =
      if ok?,
        do: for(%{"path" => p} <- changes, is_binary(p), do: event(:file_changed, %{path: p})),
        else: []

    [event(:tool_completed, data) | changed]
  end

  defp completed("mcpToolCall", item, started, params, acc) do
    {tool, input, title} = tool(Map.merge(started, item), acc)
    error = get_in(item, ["error", "message"])
    ok? = item["status"] == "completed" and error == nil

    [
      event(:tool_completed, %{
        call_id: item["id"],
        tool: tool,
        status: if(ok?, do: :ok, else: :error),
        input: input,
        title: title,
        output: mcp_text(item["result"]),
        error: if(not ok?, do: error || "the tool call failed"),
        time: duration_time(params["completedAtMs"], item["durationMs"]),
        message_id: acc.turn_id,
        part_id: item["id"]
      })
    ]
  end

  defp completed(type, item, started, params, acc)
       when type in ~w(webSearch dynamicToolCall collabAgentToolCall) do
    case tool(Map.merge(started, item), acc) do
      nil ->
        []

      {tool, input, title} ->
        ok? = item["status"] in [nil, "completed"] and item["success"] != false

        [
          event(:tool_completed, %{
            call_id: item["id"],
            tool: tool,
            status: if(ok?, do: :ok, else: :error),
            input: input,
            title: title,
            output: nil,
            error: if(not ok?, do: "failed"),
            time: time("end", params["completedAtMs"]),
            message_id: acc.turn_id,
            part_id: item["id"]
          })
        ]
    end
  end

  defp completed(_type, _item, _started, _params, _acc), do: []

  @doc "The command an item or request runs, as people read it."
  def command_text(item) do
    case for(%{"command" => c} <- List.wrap(item["commandActions"]), is_binary(c), do: c) do
      [] -> Allowance.unwrap(item["command"] || "") || item["command"] || ""
      commands -> Enum.join(commands, " && ")
    end
  end

  defp command_error("declined", _code, _output), do: "the user declined the command"

  defp command_error(_status, code, output) when is_integer(code) and code != 0,
    do: output || "exit code #{code}"

  defp command_error(status, _code, output), do: output || "command #{status || "failed"}"

  defp mcp_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp mcp_text(_), do: nil

  defp title_files([]), do: "apply_patch"
  defp title_files([one]), do: "Edit " <> one
  defp title_files([one | rest]), do: "Edit #{one} +#{length(rest)}"

  defp display(path, %{cwd: cwd}), do: Allowance.display_path(path, cwd)

  defp count_lines(nil), do: {nil, nil}

  defp count_lines(patch) do
    lines = String.split(patch, "\n")
    body = Enum.reject(lines, &String.starts_with?(&1, ["+++", "---", "@@"]))

    {Enum.count(body, &String.starts_with?(&1, "+")),
     Enum.count(body, &String.starts_with?(&1, "-"))}
  end

  # A unified turn diff as per-file counts, repository-relative.
  defp diff_files(diff) do
    diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.flat_map(fn chunk ->
      case Regex.run(~r/\Aa\/(\S+) b\/(\S+)/, chunk) do
        [_, _a, b] ->
          lines = String.split(chunk, "\n")
          body = Enum.reject(lines, &String.starts_with?(&1, ["+++", "---"]))

          [
            %{
              "file" => b,
              "additions" => Enum.count(body, &String.starts_with?(&1, "+")),
              "deletions" => Enum.count(body, &String.starts_with?(&1, "-"))
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp mcp_status(params) do
    case params["status"] do
      "ready" -> "connected"
      "failed" -> "failed"
      other -> other
    end
  end

  defp mcp_event(%{mcp: mcp}) when map_size(mcp) == 0, do: []

  defp mcp_event(%{mcp: mcp}) do
    servers =
      for {name, status} <- Enum.sort_by(mcp, &elem(&1, 0)),
          do: %{name: name, status: status, tool_count: nil}

    [event(:mcp_servers, %{servers: servers})]
  end

  defp time(_key, nil), do: %{}
  defp time(key, ms) when is_integer(ms), do: %{key => ms}
  defp time(_key, _), do: %{}

  defp duration_time(end_ms, duration) when is_integer(end_ms) and is_integer(duration),
    do: %{"start" => end_ms - duration, "end" => end_ms}

  defp duration_time(end_ms, _duration), do: time("end", end_ms)

  defp event(type, data),
    do: %Event{type: type, data: data, raw_type: "codex:" <> Atom.to_string(type)}

  defp number(n) when is_integer(n), do: n
  defp number(n) when is_float(n), do: round(n)
  defp number(_), do: 0
end
