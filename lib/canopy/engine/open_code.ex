defmodule Canopy.Engine.OpenCode do
  @moduledoc """
  `Canopy.Engine` adapter for an OpenCode server (`opencode serve`).

  One server multiplexes every repository through `?directory=`; sessions live
  on the server, so "resuming" one is just naming it. Events arrive through the
  per-repository SSE stream (`Canopy.OpenCode.EventStream`) and are normalized
  by `Canopy.OpenCode.Events`. The MCP registration and the identity plugin are
  re-checked before the first prompt after every (re)connect.

  Adapter state per channel: `client_opts` (the server URL from settings),
  `start_stream?`, and the `mcp_registered?` memo.
  """

  @behaviour Canopy.Engine

  alias Canopy.{Agents, Documents, MCP, PermissionRequests, QuestionRequests, Settings}
  alias Canopy.Engine.Event
  alias Canopy.MCP.{Inventory, Redact}
  alias Canopy.OpenCode
  alias Canopy.OpenCode.{Client, MCPConfig}

  @impl true
  def name, do: "opencode"

  @impl true
  def attach(ctx, opts) do
    state = %{
      client_opts: [base_url: Keyword.get(opts, :base_url) || Settings.get().opencode_url],
      start_stream?: Keyword.get(opts, :start_stream, stream_default()),
      mcp_registered?: false
    }

    if state.start_stream?, do: ensure_stream(ctx, state)
    state
  end

  # A reconnect usually means OpenCode restarted, and its MCP registrations are
  # process-local; a rotated token makes the registration it holds stale.
  @impl true
  def invalidate(state, _reason), do: %{state | mcp_registered?: false}

  @impl true
  def prepare(ctx, state), do: ensure_mcp(ctx, state)

  @impl true
  def create_session(ctx, state, agent, opts) do
    body = %{title: Keyword.get(opts, :title), agent: agent.opencode_agent || "build"}

    case client().create_session(ctx.repository.path, body, state.client_opts) do
      {:ok, %{"id" => id}} -> {:ok, %{engine_session_id: id}}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def subscribe(session), do: Canopy.Engine.subscribe_session(session.engine_session_id)

  @impl true
  def send_prompt(ctx, state, session, agent, %{text: text, system: system} = prompt) do
    # Documents the plan marks as parts ride along; the rest were materialised
    # under the repository and the prompt names their paths.
    parts =
      Enum.flat_map(Map.get(prompt, :attachments, []), fn
        {document, :part} -> List.wrap(Documents.prompt_part(document))
        {_document, :path} -> []
      end)

    body = %{
      parts: [%{type: "text", text: text} | parts],
      agent: agent.opencode_agent || "build",
      system: system,
      tools: %{"canopy_*" => true}
    }

    # The agent's own model, else Canopy's OpenCode default; with neither the
    # OpenCode agent's (or the server's) own default applies.
    body =
      case Agents.effective_model(agent) do
        %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) ->
          Map.put(body, :model, %{providerID: p, modelID: m})

        _ ->
          body
      end

    case client().prompt_async(
           ctx.repository.path,
           session.engine_session_id,
           body,
           state.client_opts
         ) do
      {:ok, _} -> {:ok, %{attachments: length(parts)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def abort(ctx, state, session),
    do: client().abort(ctx.repository.path, session.engine_session_id, state.client_opts)

  # OpenCode summarizes the session with a model: the agent's own, else
  # Canopy's OpenCode default, else the server's default for the first provider.
  @impl true
  def compact(ctx, state, session, agent) do
    case compaction_model(agent, state) do
      {provider, model} ->
        case client().summarize(
               ctx.repository.path,
               session.engine_session_id,
               %{providerID: provider, modelID: model},
               state.client_opts
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :no_model}
    end
  end

  @impl true
  def reply_permission(ctx, state, request, reply) do
    case client().reply_permission(
           ctx.repository.path,
           request.opencode_permission_id,
           reply,
           state.client_opts
         ) do
      {:ok, _} -> :ok
      # OpenCode no longer holds this prompt: it restarted, or the session died.
      {:error, {:http, status, _}} when status in [400, 404] -> {:error, :gone}
      {:error, reason} -> {:error, reason}
    end
  end

  # OpenCode's question tool allows a typed answer unless the question says
  # `custom: false` (custom is on by default; verified in 1.18.11). Whether an
  # explicit `custom: false` question refuses one is unverified (see the
  # Phase 0 notes), so such an answer is never sent: the question is rejected,
  # which releases the agent's tool call, and the runtime posts the answer to
  # the channel as a message instead.
  @impl true
  def reply_question(ctx, state, request, {:answered, answers} = outcome) do
    if free_text_without_custom?(request.questions, answers) do
      case reply_question(ctx, state, request, :rejected) do
        :ok -> {:ok, :as_message}
        other -> other
      end
    else
      ctx.repository.path
      |> client().reply_question(request.opencode_question_id, answers, state.client_opts)
      |> question_reply(outcome)
    end
  end

  def reply_question(ctx, state, request, :rejected = outcome) do
    ctx.repository.path
    |> client().reject_question(request.opencode_question_id, state.client_opts)
    |> question_reply(outcome)
  end

  defp question_reply({:ok, _}, _outcome), do: :ok

  # OpenCode no longer holds this question: it restarted, or the session died
  # still carrying it.
  defp question_reply({:error, {:http, status, _}}, _outcome) when status in [400, 404],
    do: {:error, :gone}

  defp question_reply({:error, reason}, _outcome), do: {:error, reason}

  # Any answer that is not one of the question's own option labels is free
  # text; only a question that turned `custom` off explicitly may refuse it.
  defp free_text_without_custom?(questions, answers) do
    questions
    |> Enum.zip(answers)
    |> Enum.any?(fn {question, chosen} ->
      labels = question |> Map.get("options") |> List.wrap() |> Enum.map(& &1["label"])
      question["custom"] == false and Enum.any?(List.wrap(chosen), &(&1 not in labels))
    end)
  end

  @impl true
  def reconcile(ctx, state) do
    dir = ctx.repository.path

    # The status map lists non-idle sessions only; a session whose model call
    # keeps failing shows as `retry` with the provider's message and the attempt.
    {busy, retrying} =
      case client().session_status(dir, state.client_opts) do
        {:ok, statuses} when is_map(statuses) ->
          active = Enum.reject(statuses, fn {_, st} -> st["type"] == "idle" end)

          retrying =
            for {sid, %{"type" => "retry"} = st} <- active,
                do: %{session_id: sid, message: st["message"], attempt: st["attempt"]}

          {Enum.map(active, &elem(&1, 0)), retrying}

        _ ->
          {:unknown, :unknown}
      end

    repository_id = ctx.repository.id

    %{
      busy: busy,
      retrying: retrying,
      permissions:
        prompts(
          client().pending_permissions(dir, state.client_opts),
          :approval_required,
          fn -> known_permissions(repository_id) end
        ),
      questions:
        prompts(
          client().pending_questions(dir, state.client_opts),
          :question_required,
          fn -> known_questions(repository_id) end
        )
    }
  end

  # A 400/404 means this OpenCode build does not serve the endpoint (or, for
  # permissions, fails to serialize a pending patch prompt; see the Phase 0
  # notes). The list then falls back to the cards Canopy itself holds open for
  # OpenCode sessions of this repository: those sessions count as blocked, and
  # any other orphaned turn is still finished. Any other failure leaves the
  # answer unknown.
  defp prompts({:ok, requests}, type, _known) when is_list(requests),
    do: Enum.map(requests, &replay_event(type, &1))

  defp prompts({:error, {:http, status, _}}, type, known) when status in [400, 404],
    do: Enum.map(known.(), &replay_event(type, &1))

  defp prompts(_, _type, _known), do: :unknown

  defp replay_event(type, req) do
    %Event{
      type: type,
      session_id: req["sessionID"],
      data: %{request: req, replay: true},
      raw_type: "reconcile"
    }
  end

  defp known_questions(repository_id) do
    for r <- QuestionRequests.waiting_in_repository(repository_id, name()) do
      %{
        "id" => r.opencode_question_id,
        "sessionID" => r.agent_session.engine_session_id,
        "questions" => r.questions,
        "tool" => %{"callID" => r.tool_call_id}
      }
    end
  end

  defp known_permissions(repository_id) do
    for r <- PermissionRequests.waiting_in_repository(repository_id, name()) do
      %{
        "id" => r.opencode_permission_id,
        "sessionID" => r.agent_session.engine_session_id,
        "permission" => r.permission,
        "patterns" => r.patterns,
        "metadata" => r.metadata,
        "tool" => %{"callID" => r.tool_call_id}
      }
    end
  end

  # "provider/model" the agent runs on, its own or Canopy's default; OpenCode's
  # own default otherwise.
  @impl true
  def model_label(agent) do
    case Agents.effective_model(agent) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) -> p <> "/" <> m
      _ -> "opencode default"
    end
  end

  @impl true
  def context_cap, do: Canopy.Runtime.ChannelServer.context_cap()

  # -- Streams and MCP ----------------------------------------------------------

  defp ensure_stream(ctx, state) do
    OpenCode.Supervisor.start_stream(ctx.repository.id, ctx.repository.path,
      base_url: state.client_opts[:base_url]
    )
  end

  defp ensure_mcp(_ctx, %{mcp_registered?: true} = state), do: state

  # A registration OpenCode still reports as connected is reused only if this
  # Canopy process made it: an older one carries the tool list from before
  # Canopy last restarted. Otherwise it is (re)posted, which is idempotent.
  defp ensure_mcp(ctx, state) do
    dir = ctx.repository.path
    name = MCP.registration_name()
    install_plugin(dir, state.client_opts)

    connected? =
      match?(
        {:ok, %{^name => %{"status" => "connected"}}},
        client().mcp_status(dir, state.client_opts)
      )

    registered? =
      (connected? and MCP.registered_this_boot?(ctx.repository.id)) or
        register(ctx.repository, state.client_opts) == :ok

    %{state | mcp_registered?: registered?}
  end

  # The identity plugin must be in this repository; a fresh install only
  # takes effect once OpenCode recreates its instance for the directory.
  defp install_plugin(dir, client_opts) do
    case MCP.ensure_project_plugin(dir) do
      {:ok, :installed} -> client().dispose_instance(dir, client_opts)
      _ -> :ok
    end
  end

  defp register(repository, client_opts) do
    config = MCP.registration_config(:current)

    case client().add_mcp(repository.path, MCP.registration_name(), config, client_opts) do
      {:ok, _} ->
        MCP.mark_registered(repository.id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Repository page actions --------------------------------------------------

  @doc """
  Posts Canopy's registration for the repository again (with the plugin
  check first), as the next prompt would. Channels that already registered
  keep their memo: it stays true.
  """
  def reregister(repository, opts \\ []) do
    client_opts = client_opts(opts)
    install_plugin(repository.path, client_opts)
    register(repository, client_opts)
  end

  @doc "Asks OpenCode to reconnect one of the repository's MCP servers."
  def reconnect(repository, name, opts \\ []) when is_binary(name) do
    case client().mcp_connect(repository.path, name, client_opts(opts)) do
      {:ok, false} -> {:error, :not_connected}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rewrites the repository's identity plugin and restarts OpenCode's instance
  for the directory so it loads, then registers Canopy again (a disposed
  instance forgets runtime registrations). Interrupts any OpenCode session
  running there, so the page offers it only while no agent is busy.
  """
  def reinstall_plugin(repository, opts \\ []) do
    client_opts = client_opts(opts)

    with {:ok, _} <- MCP.ensure_project_plugin(repository.path),
         {:ok, _} <- client().dispose_instance(repository.path, client_opts) do
      register(repository, client_opts)
    end
  end

  defp client_opts(opts),
    do: [base_url: Keyword.get(opts, :base_url) || Settings.get().opencode_url]

  # -- MCP inventory --------------------------------------------------------------

  @doc """
  What OpenCode gives agents in the repository. What is loaded and enabled
  comes from OpenCode (`GET /config`, `GET /mcp`); the config files are read
  only to say where each server came from and to show values as written.
  With OpenCode away, the files stand in, with unknown status. Options:
  `:base_url` (default Settings), `:config_home`, `:opencode_config`.
  """
  @impl true
  def mcp_inventory(repository, opts) do
    client_opts = client_opts(opts)
    dir = repository.path
    canopy = MCP.registration_name()
    files = MCPConfig.sources(dir, opts)

    {status, config, error} =
      case {client().mcp_status(dir, client_opts), client().config(dir, client_opts)} do
        {{:ok, status}, {:ok, config}} when is_map(status) and is_map(config) ->
          {status, config["mcp"] || %{}, nil}

        {{:ok, status}, other} when is_map(status) ->
          {status, nil, failure(other)}

        {other, _} ->
          {nil, nil, failure(other)}
      end

    reachable? = is_map(status)

    # The API says what is loaded; with it away, the files are the best guess.
    loaded =
      cond do
        is_map(config) -> Map.keys(config)
        reachable? -> []
        true -> Map.keys(files.servers)
      end

    names =
      (loaded ++ if(reachable?, do: Map.keys(status), else: []))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == canopy))
      |> Enum.sort()

    servers =
      [canopy_row(status, files) | Enum.map(names, &server_row(&1, files, config, status))]

    ignored =
      if is_map(config),
        do:
          for(
            {name, file} <- Enum.sort_by(files.servers, &elem(&1, 0)),
            name != canopy and not Map.has_key?(config, name),
            do: %{
              file_row(name, file)
              | note:
                  "In this file, but the OpenCode server does not load it (its config differs from what Canopy reads)."
            }
          ),
        else: []

    notes =
      Enum.map(files.errors, &"Could not read #{&1}") ++
        if(Map.has_key?(files.servers, canopy),
          do: [
            "A config file defines its own \"#{canopy}\" server; Canopy's runtime registration replaces it."
          ],
          else: []
        )

    {:ok,
     %Inventory.Engine{
       engine: name(),
       reachable?: reachable?,
       error: error,
       servers: servers,
       ignored: ignored,
       notes: notes,
       canopy: %{
         registered_this_boot?: MCP.registered_this_boot?(repository.id),
         plugin: MCP.project_plugin_state(dir),
         global_plugin?: File.exists?(MCP.global_plugin_path())
       }
     }}
  end

  defp failure({:error, {:transport, reason}}),
    do: Redact.text("OpenCode did not answer: #{transport_reason(reason)}")

  defp failure({:error, {:http, status, _body}}), do: "OpenCode answered HTTP #{status}"

  defp failure({:ok, other}),
    do: Redact.text("unexpected answer from OpenCode: #{inspect(other)}")

  defp failure(other), do: Redact.text(inspect(other))

  defp transport_reason(%{reason: reason}), do: inspect(reason)
  defp transport_reason(reason), do: inspect(reason)

  defp canopy_row(status, files) do
    name = MCP.registration_name()

    {row_status, error, note} =
      case status do
        %{^name => s} ->
          {Inventory.Server.status(s["status"]), Redact.text(s["error"]),
           "Registered by Canopy at runtime."}

        %{} ->
          {:unknown, nil,
           "Not registered yet: Canopy registers before an agent's next prompt here."}

        nil ->
          {:unknown, nil, "Registered by Canopy at runtime."}
      end

    %Inventory.Server{
      name: name,
      transport: :remote,
      target: Redact.url(MCP.url()),
      secrets: ["Authorization"],
      source: %{kind: :canopy, path: nil},
      status: row_status,
      error: error,
      note:
        if(Map.has_key?(files.servers, name),
          do: note <> " Replaces the entry in a config file.",
          else: note
        )
    }
  end

  # Values as written in the file when one defines the server, else as the
  # API resolved them; enabled and status as OpenCode reports.
  defp server_row(name, files, config, status) do
    api = if is_map(config), do: config[name], else: nil

    row =
      case files.servers[name] do
        nil -> server(name, api || %{}, %{kind: :server, path: nil})
        file -> file_row(name, file)
      end

    enabled? =
      Map.get(api || get_in(files.servers, [name, :config]) || %{}, "enabled", true) != false

    {row_status, error} =
      case status && status[name] do
        %{"status" => s} = st -> {Inventory.Server.status(s), Redact.text(st["error"])}
        _ when not enabled? -> {:disabled, nil}
        _ -> {:unknown, nil}
      end

    note =
      case row_status do
        :needs_auth ->
          "Needs OAuth: run `opencode mcp auth #{name}` in a terminal."

        _ ->
          if row.source.kind == :server,
            do: "OpenCode server: remote config, environment, or added at runtime."
      end

    %{row | enabled?: enabled?, status: row_status, error: error, note: note}
  end

  defp file_row(name, %{config: config, kind: kind, path: path}),
    do: server(name, config, %{kind: kind, path: path})

  defp server(name, config, source) do
    {_env, env_keys} = Redact.map(config["environment"] || %{})
    {_headers, header_keys} = Redact.map(config["headers"] || %{})

    {transport, target} =
      case config do
        %{"type" => "remote", "url" => url} -> {:remote, Redact.url(url)}
        %{"url" => url} when is_binary(url) -> {:remote, Redact.url(url)}
        %{"command" => command} -> {:local, Redact.command(List.wrap(command))}
        _ -> {nil, nil}
      end

    %Inventory.Server{
      name: name,
      transport: transport,
      target: target,
      secrets: Enum.uniq(env_keys ++ header_keys),
      source: source,
      enabled?: Map.get(config, "enabled", true) != false
    }
  end

  defp compaction_model(agent, state) do
    case Agents.effective_model(agent) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) ->
        {p, m}

      _ ->
        case OpenCode.Providers.list(state.client_opts) do
          {:ok, %{defaults: defaults}} -> OpenCode.Providers.server_default(defaults)
          {:error, _} -> nil
        end
    end
  end

  defp client, do: Client.impl()

  defp stream_default,
    do: Keyword.get(Application.get_env(:canopy, :opencode, []), :start_streams, true)
end
