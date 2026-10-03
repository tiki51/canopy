defmodule Canopy.Engine.ClaudeCode do
  @moduledoc """
  `Canopy.Engine` adapter for Claude Code (`claude -p`).

  Every turn is its own process (`Canopy.ClaudeCode.Turn`): the first turn of
  a session passes `--session-id`, later ones `--resume`, and Claude Code keeps
  the transcript on disk between them. Events come from the process's
  stream-json output, normalized by `Canopy.ClaudeCode.Events`. Compaction is
  a `/compact` turn, so `compact/4` answers `{:ok, :turn}` and the runtime
  tracks it like any other turn.

  Settings carry the binary (`claude_binary`, a name on `PATH` or a path), the
  optional `claude_config_dir` (`CLAUDE_CONFIG_DIR`; nil keeps the user's own
  login), `claude_max_budget_usd` per turn, and the default model and effort
  (`claude_default_model`, `claude_default_effort`); the agent carries its own
  model and effort (blank inherits the defaults), the permission mode, and the
  tools allowed without asking.
  `config :canopy, :claude_code` overrides `:binary` and `:config_dir` (tests
  point at a fake), and adds `:mcp_tool_timeout_ms`, `:env`, and `:stall_ms`
  (the turn's no-output window; the e2e suite shortens it).

  Identity and prompts: every session gets its own MCP bearer token, written
  into the `--mcp-config` file the process is spawned with, so
  `Canopy.MCP.AuthPlug` knows the agent without any tool argument. That file
  also carries the repository's `.mcp.json` servers, re-read every turn
  (`Canopy.ClaudeCode.MCPConfig`); `--strict-mcp-config` keeps every other
  MCP config out, and Canopy's own `canopy` entry wins a name clash. Permission
  prompts (and `AskUserQuestion`) go through `--permission-prompt-tool
  mcp__canopy__permission`, a Canopy tool that blocks until the user answers
  from the channel (`Canopy.ClaudeCode.Prompts`). Agents run under
  `acceptEdits` with a read/edit/git allowance plus every `canopy_*` tool.
  """

  @behaviour Canopy.Engine

  require Logger

  alias Canopy.{Agents, AgentSessions, ClaudeCode, Documents, Settings}
  alias Canopy.Agents.Agent
  alias Canopy.ClaudeCode.{Command, MCPConfig, Prompts}
  alias Canopy.Engine.Event
  alias Canopy.MCP.Inventory
  alias Canopy.MCP.Redact
  alias Canopy.Settings.Setting

  @context_cap 120_000
  @allowed_tools [
    "Read",
    "Glob",
    "Grep",
    "Edit",
    "Write",
    "MultiEdit",
    "NotebookEdit",
    "Bash(git *)",
    "mcp__canopy__*"
  ]
  @permission_tool "mcp__canopy__permission"
  @default_mcp_tool_timeout_ms :timer.minutes(30)

  @impl true
  def name, do: "claude_code"

  @impl true
  def attach(_ctx, opts) do
    %{binary: Keyword.get(opts, :binary) || binary_name(), binary_path: nil}
  end

  @doc "The configured binary: the config override, else Settings, else `claude`."
  def binary_name do
    case {config(:binary, nil), Settings.get().claude_binary} do
      {name, _} when is_binary(name) and name != "" -> name
      {_, name} when is_binary(name) and name != "" -> name
      _ -> "claude"
    end
  end

  @doc """
  Checks the binary: its version and login state, from `claude --version` and
  `claude auth status`. `{:ok, %{version, logged_in, auth_method, subscription, email}}`
  or `{:error, reason}`.
  """
  def check(binary \\ binary_name(), config_dir \\ configured_config_dir()) do
    with {:ok, config_dir} <- normalize_config_dir(config_dir),
         {:ok, path} <- find(binary),
         {:ok, version} <- run(path, ["--version"], config_dir),
         {:ok, status} <- run(path, ["auth", "status"], config_dir) do
      auth =
        case JSON.decode(status) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end

      {:ok,
       %{
         path: path,
         version: version |> String.split(" ") |> List.first(),
         logged_in: auth["loggedIn"] == true,
         auth_method: auth["authMethod"],
         subscription: auth["subscriptionType"],
         email: auth["email"]
       }}
    end
  end

  defp find(binary) do
    case System.find_executable(binary) do
      nil -> {:error, "#{binary} not found on PATH"}
      path -> {:ok, path}
    end
  end

  defp run(path, args, config_dir) do
    env =
      [{"CLAUDECODE", nil}] ++
        ClaudeCode.Command.release_env() ++
        if(config_dir, do: [{"CLAUDE_CONFIG_DIR", config_dir}], else: []) ++
        Enum.map(config(:env, []), fn {key, value} -> {to_string(key), to_string(value)} end)

    case System.cmd(path, args, env: env, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, status} ->
        {:error,
         "#{Path.basename(path)} #{Enum.join(args, " ")} failed (#{status}): #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "could not run #{path}: #{Exception.message(e)}"}
  end

  @impl true
  def invalidate(state, _reason), do: state

  # The binary is looked up once per channel; a miss is reported by the first prompt.
  @impl true
  def prepare(_ctx, %{binary_path: path} = state) when is_binary(path), do: state
  def prepare(_ctx, state), do: %{state | binary_path: System.find_executable(state.binary)}

  @impl true
  def create_session(_ctx, _state, _agent, _opts),
    do:
      {:ok,
       %{engine_session_id: Ecto.UUID.generate(), mcp_token: AgentSessions.generate_mcp_token()}}

  @impl true
  def subscribe(session), do: Canopy.Engine.subscribe_session(session.engine_session_id)

  @impl true
  def send_prompt(ctx, state, session, agent, %{text: text} = prompt) do
    {blocks, attached} = content(text, Map.get(prompt, :attachments, []))

    with {:ok, _pid} <- start_turn(ctx, state, session, agent, blocks, system: prompt.system) do
      {:ok, %{attachments: attached}}
    end
  end

  @impl true
  def abort(_ctx, _state, session) do
    case ClaudeCode.Supervisor.whereis(session.engine_session_id) do
      nil -> {:error, :no_turn}
      pid -> {ClaudeCode.Turn.abort(pid), :aborted} |> then(fn {:ok, r} -> {:ok, r} end)
    end
  end

  @impl true
  def compact(ctx, state, session, agent) do
    with {:ok, _pid} <- start_turn(ctx, state, session, agent, "/compact", compact?: true) do
      {:ok, :turn}
    end
  end

  # A late Always (the tool call that asked is gone) still counts for the rest
  # of the session, so the agent redoing the action is not asked again.
  @impl true
  def reply_permission(_ctx, _state, request, reply) do
    case Prompts.answer(request.opencode_permission_id, reply) do
      {:error, :gone} = gone ->
        with :always <- reply,
             %{engine_session_id: sid} <- request.agent_session,
             do: Prompts.allow_always(sid, request.permission)

        gone

      other ->
        other
    end
  end

  @impl true
  def reply_question(_ctx, _state, request, outcome),
    do: Prompts.answer(request.opencode_question_id, outcome)

  @impl true
  def reconcile(_ctx, _state) do
    pending = Prompts.pending()

    %{
      busy: ClaudeCode.Supervisor.running(),
      # the CLI retries inside its own process; nothing to see from here
      retrying: [],
      permissions: prompt_events(pending, :permission, :approval_required),
      questions: prompt_events(pending, :question, :question_required)
    }
  end

  defp prompt_events(pending, kind, type) do
    for %{kind: ^kind, session_id: sid, request: request} <- pending do
      %Event{
        type: type,
        session_id: sid,
        data: %{request: request, replay: true},
        raw_type: "reconcile"
      }
    end
  end

  # The alias the agent runs on, its own or Canopy's default; Claude Code's own
  # default otherwise.
  @impl true
  def model_label(agent) do
    case Agents.effective_model(agent) do
      %{model_id: model} when is_binary(model) -> model
      _ -> "claude default"
    end
  end

  @impl true
  def context_cap, do: @context_cap

  # -- MCP inventory --------------------------------------------------------------

  @doc """
  What a turn in the repository loads: Canopy's server and the repository's
  `.mcp.json` servers, with the status the newest turn's `system/init`
  reported; and what `--strict-mcp-config` keeps out (`~/.claude.json` user
  and local scope, managed config). Options: `:home`, `:config_dir` (default
  the one in Settings), `:managed_path`.
  """
  @impl true
  def mcp_inventory(repository, opts) do
    canopy_name = Canopy.MCP.registration_name()
    project_path = MCPConfig.project_path(repository.path)
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> configured_config_dir() end)

    {project, project_notes} =
      case MCPConfig.project_servers(repository.path) do
        {:ok, servers} ->
          {servers, []}

        {:error, reason} ->
          {%{},
           [
             "#{project_path} could not be used (#{reason}), so agents run with Canopy's server only until it is fixed."
           ]}
      end

    canopy = %Inventory.Server{
      name: canopy_name,
      transport: :http,
      target: Redact.url(Canopy.MCP.url()),
      secrets: ["Authorization"],
      source: %{kind: :canopy, path: nil},
      note: "Per-session token, written into each turn's generated mcp.json."
    }

    {shadowed, project} = Map.split(project, [canopy_name])

    loaded =
      [
        canopy
        | for({n, c} <- Enum.sort_by(project, &elem(&1, 0)), do: project_row(n, c, project_path))
      ]
      |> observe(AgentSessions.latest_mcp_servers(repository.id, name()))

    clash =
      for {n, c} <- shadowed do
        %{
          project_row(n, c, project_path)
          | note: "Replaced by Canopy's own server of the same name."
        }
      end

    {others, other_errors} =
      MCPConfig.other_sources(repository.path,
        home: opts[:home],
        config_dir: config_dir,
        managed_path: opts[:managed_path]
      )

    ignored =
      clash ++
        for %{name: n, config: c, kind: kind, path: path} <- others do
          %{MCPConfig.to_server(n, c, %{kind: kind, path: path}) | note: ignored_note(kind)}
        end

    {:ok,
     %Inventory.Engine{
       engine: name(),
       servers: loaded,
       ignored: ignored,
       notes: project_notes ++ Enum.map(other_errors, &"Could not read #{&1}")
     }}
  end

  defp project_row(name, config, path) do
    %{
      MCPConfig.to_server(name, config, %{kind: :project, path: path})
      | note: "Loaded on every turn from the repository's .mcp.json."
    }
  end

  defp ignored_note(:managed),
    do:
      "Managed by your organisation. Not in Canopy's per-turn config; Claude Code may still enforce its policy."

  defp ignored_note(_kind), do: "Not loaded: --strict-mcp-config keeps personal servers out."

  # The status the newest turn reported for each loaded server.
  defp observe(rows, nil), do: rows

  defp observe(rows, %{servers: seen, seen_at: at}) do
    by_name = Map.new(seen, &{&1["name"], &1})

    Enum.map(rows, fn row ->
      case by_name[row.name] do
        nil ->
          row

        s ->
          %{
            row
            | status: Inventory.Server.status(s["status"]),
              tool_count: s["tool_count"],
              observed_at: at
          }
      end
    end)
  end

  # -- Turns --------------------------------------------------------------------

  defp start_turn(ctx, state, session, agent, content, opts) do
    settings = Settings.get()

    # The runtime's copy of the session may predate its first turn and its
    # token; the row says whether Claude Code has seen it (a wrong guess is
    # corrected by the turn) and carries the MCP token the process presents.
    with {:ok, config_dir} <- normalize_config_dir(configured_config_dir(settings)),
         {:ok, binary} <- binary(state),
         {:ok, fresh} <- AgentSessions.ensure_mcp_token(AgentSessions.get!(session.id)) do
      sid = session.engine_session_id
      dir = work_dir(sid)
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      stderr_file = Path.join(dir, "stderr.log")
      system_file = write_system(dir, opts[:system])
      mcp_file = write_mcp_config(dir, fresh.mcp_token, ctx.repository.path)
      seen? = fresh.last_seen_at != nil
      # the agent's own model and effort, else the defaults from Settings; nil
      # leaves the flag off and Claude Code picks
      %{model_id: model} = Agents.effective_model(agent, settings)
      %{effort: effort} = Agents.effective_effort(agent, settings)

      command = fn flag ->
        Command.build(
          binary: binary,
          cwd: ctx.repository.path,
          stderr_file: stderr_file,
          session: {flag, sid},
          model: model,
          effort: effort,
          system_file: system_file,
          mcp_config_file: mcp_file,
          permission_prompt_tool: @permission_tool,
          permission_mode: Map.get(agent, :permission_mode) || "default",
          allowed_tools: allowed_tools(agent) ++ Prompts.always_list(sid),
          max_budget_usd: settings.claude_max_budget_usd,
          config_dir: config_dir,
          mcp_tool_timeout_ms: config(:mcp_tool_timeout_ms, @default_mcp_tool_timeout_ms),
          extra_env: config(:env, [])
        )
      end

      turn_opts = [
        repository_id: ctx.repository.id,
        command: command,
        flag: if(seen?, do: :resume, else: :new),
        message: Command.user_message(content),
        stderr_file: stderr_file,
        cwd: ctx.repository.path,
        compact?: Keyword.get(opts, :compact?, false)
      ]

      turn_opts =
        case config(:stall_ms, nil) do
          ms when is_integer(ms) and ms > 0 -> Keyword.put(turn_opts, :stall_ms, ms)
          _ -> turn_opts
        end

      case ClaudeCode.Supervisor.start_turn(sid, turn_opts) do
        {:ok, pid} ->
          # From now on the session is resumed; a wrong guess is corrected by the turn.
          {:ok, _} = AgentSessions.touch(session)
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The agent's own allowance, else the default set; the Canopy tools always.
  defp allowed_tools(agent) do
    case Agent.allowed_tools_list(agent) do
      [] -> @allowed_tools
      list -> Enum.uniq(list ++ ["mcp__canopy__*"])
    end
  end

  defp binary(%{binary_path: path}) when is_binary(path), do: {:ok, path}
  defp binary(%{binary: name}), do: {:error, {:claude_not_found, name}}

  # The MCP config names Canopy's server with this session's bearer token,
  # plus the repository's own `.mcp.json` servers as they are on disk now. A
  # file rather than inline JSON, so the token never shows in `ps`. A broken
  # `.mcp.json` is skipped: the turn still runs, with Canopy's server only.
  defp write_mcp_config(dir, token, repository_path) do
    path = Path.join(dir, "mcp.json")

    project =
      case MCPConfig.project_servers(repository_path) do
        {:ok, servers} ->
          servers

        {:error, reason} ->
          Logger.warning(
            "Claude Code: skipping #{MCPConfig.project_path(repository_path)}: #{reason}"
          )

          %{}
      end

    canopy = %{
      "type" => "http",
      "url" => Canopy.MCP.url(),
      "headers" => %{"Authorization" => "Bearer " <> token}
    }

    config = %{mcpServers: Map.put(project, Canopy.MCP.registration_name(), canopy)}

    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
    path
  end

  defp write_system(_dir, nil), do: nil

  defp write_system(dir, system) do
    path = Path.join(dir, "system.md")
    File.write!(path, system)
    File.chmod!(path, 0o600)
    path
  end

  # Per-session scratch: the system prompt file and stderr, outside the repository.
  defp work_dir(sid), do: Path.join([System.tmp_dir!(), "canopy-claude", sid])

  # The prompt as content blocks: the text, then each attachment the plan
  # marks as a part (images as image blocks, text files inline). Path-mode
  # documents were materialised under the repository and the text names them.
  defp content(text, plan) do
    {blocks, attached} =
      Enum.reduce(plan, {[], 0}, fn
        {document, :part}, {blocks, n} ->
          case attachment_block(document) do
            nil -> {blocks, n}
            block -> {[block | blocks], n + 1}
          end

        {_document, :path}, acc ->
          acc
      end)

    {[%{type: "text", text: text} | Enum.reverse(blocks)], attached}
  end

  defp attachment_block(%{kind: "image"} = document) do
    case Documents.read(document) do
      {:ok, bytes} ->
        %{
          type: "image",
          source: %{
            type: "base64",
            media_type: Documents.prompt_mime(document),
            data: Base.encode64(bytes)
          }
        }

      _ ->
        nil
    end
  end

  defp attachment_block(%{kind: "text"} = document) do
    case Documents.read(document) do
      {:ok, bytes} ->
        text = if String.valid?(bytes), do: bytes, else: String.replace_invalid(bytes)
        %{type: "text", text: "Attached file #{document.filename}:\n\n" <> text}

      _ ->
        nil
    end
  end

  defp attachment_block(_document), do: nil

  defp configured_config_dir(settings \\ Settings.get()) do
    (config(:config_dir, nil) || settings.claude_config_dir)
    |> Setting.normalize_claude_config_dir()
  end

  defp normalize_config_dir(nil), do: {:ok, nil}

  defp normalize_config_dir(value) do
    case Setting.normalize_claude_config_dir(value) do
      nil ->
        {:ok, nil}

      path ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, "Claude config directory must be an absolute path"}
    end
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:canopy, :claude_code, []), key, default)
end
