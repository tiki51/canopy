defmodule Canopy.Engine.Codex do
  @moduledoc """
  `Canopy.Engine` adapter for OpenAI's Codex CLI (`codex app-server`).

  Every turn is its own app-server process speaking JSON-RPC on stdio
  (`Canopy.Codex.Turn`): `thread/start` on a session's first turn,
  `thread/resume` after that, then `turn/start`. Codex keeps the thread in
  its rollout files between turns. Codex picks a thread's id, so a session
  starts under a placeholder id and is renamed to the thread id by its first
  turn (§5.5 of the design).

  Settings carry the binary (`codex_binary`, a name on `PATH` or a path),
  the optional `codex_config_dir` (`CODEX_HOME`; nil keeps the user's own
  login and config), and the default and light models and efforts. The agent
  carries its own model and effort and the permission mode, which maps to
  Codex's sandbox and approval policy (`Canopy.Codex.Command.policy/1`).
  `config :canopy, :codex` overrides `:binary` and `:config_dir` (tests point
  at a fake), and adds `:env`, `:stall_ms`, `:item_stall_ms`,
  `:mcp_tool_timeout_ms`, `:models_cache_ms` and `:default_config_dir`.

  Identity: every session gets its own MCP bearer token, passed to Codex in
  the environment (`bearer_token_env_var`), so `Canopy.MCP.AuthPlug` knows
  the agent without any tool argument. Codex's approval requests become
  permission cards (`Canopy.Codex.Approvals`).

  Cost: Codex reports tokens, not money. Each turn's usage is priced at
  OpenAI's list prices (`Canopy.Codex.Pricing`) and marked as an estimate.
  """

  @behaviour Canopy.Engine

  require Logger

  alias Canopy.{Agents, AgentSessions, Codex, Documents, Settings}
  alias Canopy.Codex.{Approvals, Client, Command, McpConfig, Models}
  alias Canopy.MCP.Inventory
  alias Canopy.MCP.Redact
  alias Canopy.Settings.Setting

  @context_cap 200_000
  @min_version "0.163.0"
  @rename_ack_ms 5_000

  @impl true
  def name, do: "codex"

  @impl true
  def attach(_ctx, opts),
    do: %{binary: Keyword.get(opts, :binary) || binary_name(), binary_path: nil}

  @doc "The configured binary: the config override, else Settings, else `codex`."
  def binary_name do
    case {config(:binary, nil), Map.get(Settings.get(), :codex_binary)} do
      {name, _} when is_binary(name) and name != "" -> name
      {_, name} when is_binary(name) and name != "" -> name
      _ -> "codex"
    end
  end

  @doc "The minimum codex-cli version Canopy speaks to."
  def min_version, do: @min_version

  # -- Check ------------------------------------------------------------------------------

  @doc """
  Checks the binary: its version, and the login from a short app-server's
  `account/read` (which also warms the model list). `{:ok, %{path, version,
  logged_in, auth_method, email, plan}}` or `{:error, reason}`.

  The check knows no repository, so it reports only a `[mcp_servers.canopy]`
  in `$CODEX_HOME/config.toml`. A clash in a repository's own
  `.codex/config.toml` is caught when a turn starts (`start_turn/6`): the turn
  fails with the same message, naming that file.
  """
  def check(binary \\ binary_name(), config_dir \\ configured_config_dir()) do
    with {:ok, config_dir} <- existing_config_dir(config_dir),
         {:ok, path} <- find(binary),
         {:ok, version} <- version(path, config_dir),
         :ok <- McpConfig.canopy_clash(config_dir) do
      result =
        Client.with_server([binary: path, config_dir: config_dir], fn call ->
          with {:ok, account} <- call.("account/read", %{"refreshToken" => false}) do
            _ = Models.fetch_with(call, path, config_dir)
            {:ok, account}
          end
        end)

      case result do
        {:ok, %{} = read} ->
          account = read["account"]

          {:ok,
           %{
             path: path,
             version: version,
             logged_in: is_map(account),
             auth_method: auth_method(account),
             email: if(is_map(account), do: account["email"]),
             plan: if(is_map(account), do: plan(account["planType"]))
           }}

        {:ok, _} ->
          {:error, "codex did not say who is signed in"}

        {:error, reason} ->
          {:error, "codex account check failed: #{reason}"}
      end
    end
  end

  @doc "The badge a check result maps to."
  def readiness({:ok, %{logged_in: true}}), do: :ready
  def readiness({:ok, _}), do: :signed_out

  def readiness({:error, reason}) when is_binary(reason),
    do: if(String.ends_with?(reason, "not found on PATH"), do: :not_found, else: :failed)

  def readiness(_), do: :failed

  defp auth_method(%{"type" => "chatgpt"}), do: "chatgpt"
  defp auth_method(%{"type" => "apiKey"}), do: "api_key"
  defp auth_method(_), do: nil

  @doc "A ChatGPT plan as people read it (`\"pro\"` → `\"Pro\"`)."
  def plan(nil), do: nil
  def plan("plus"), do: "Plus"
  def plan("pro"), do: "Pro"
  def plan("prolite"), do: "Pro Lite"
  def plan(other) when is_binary(other), do: String.capitalize(other)
  def plan(_), do: nil

  defp find(binary) do
    case System.find_executable(binary) do
      nil -> {:error, "#{binary} not found on PATH"}
      path -> {:ok, path}
    end
  end

  @doc """
  The binary's version from `codex --version` (cached per path and mtime);
  `{:error, …}` below `#{@min_version}`. An unparseable version passes.
  """
  def version(path, config_dir \\ nil) do
    key = {:version, path, mtime(path)}

    cached =
      try do
        case :ets.lookup(Codex.Supervisor.cache(), key) do
          [{_, version}] -> {:ok, version}
          _ -> nil
        end
      rescue
        ArgumentError -> nil
      end

    with {:ok, version} <- cached || run_version(path, config_dir, key) do
      check_min(version)
    end
  end

  defp run_version(path, config_dir, key) do
    env =
      Command.env(config_dir: config_dir, extra_env: config(:env, []))
      |> Enum.map(fn {k, v} -> {to_string(k), if(v == false, do: nil, else: to_string(v))} end)

    case System.cmd(path, ["--version"], env: env, stderr_to_stdout: true) do
      {out, 0} ->
        version =
          case Regex.run(~r/(\d+\.\d+\.\d+[^\s]*)/, out) do
            [_, v] -> v
            _ -> String.trim(out)
          end

        try do
          :ets.insert(Codex.Supervisor.cache(), {key, version})
        rescue
          ArgumentError -> :ok
        end

        {:ok, version}

      {out, status} ->
        {:error, "codex --version failed (#{status}): #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "could not run #{path}: #{Exception.message(e)}"}
  end

  defp check_min(version) do
    case Version.parse(version) do
      {:ok, have} ->
        if Version.compare(have, Version.parse!(@min_version)) == :lt,
          do: {:error, "codex #{version} is older than #{@min_version}; upgrade it"},
          else: {:ok, version}

      :error ->
        Logger.info("codex: could not read the version #{inspect(version)}; going on")
        {:ok, version}
    end
  end

  defp mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  # -- Sessions ---------------------------------------------------------------------------

  @impl true
  def invalidate(state, _reason), do: state

  @impl true
  def prepare(_ctx, %{binary_path: path} = state) when is_binary(path), do: state
  def prepare(_ctx, state), do: %{state | binary_path: System.find_executable(state.binary)}

  # The id is a placeholder until the first turn learns Codex's thread id.
  @impl true
  def create_session(_ctx, _state, _agent, _opts),
    do:
      {:ok,
       %{engine_session_id: Ecto.UUID.generate(), mcp_token: AgentSessions.generate_mcp_token()}}

  @impl true
  def subscribe(session), do: Canopy.Engine.subscribe_session(session.engine_session_id)

  @impl true
  def send_prompt(ctx, state, session, agent, %{text: text} = prompt) do
    {input, attached} = input(text, Map.get(prompt, :attachments, []), session.engine_session_id)

    with {:ok, _pid} <-
           start_turn(ctx, state, session, agent, input,
             system: prompt.system,
             profile: Map.get(prompt, :profile, :main)
           ) do
      {:ok, %{attachments: attached}}
    end
  end

  @impl true
  def steer(_ctx, _state, session, %{text: text, ref: ref} = message) do
    case Codex.Supervisor.whereis(session.engine_session_id) do
      nil ->
        {:error, :not_running}

      pid ->
        {input, _} =
          input(text, Map.get(message, :attachments, []), session.engine_session_id)

        with :ok <- Codex.Turn.steer(pid, input, ref), do: {:ok, %{confirms: true}}
    end
  end

  @impl true
  def abort(_ctx, _state, session) do
    case Codex.Supervisor.whereis(session.engine_session_id) do
      nil ->
        {:error, :no_turn}

      pid ->
        case Codex.Turn.abort(pid) do
          :ok -> {:ok, :aborted}
          {:ok, _} -> {:ok, :aborted}
          other -> other
        end
    end
  end

  @impl true
  def compact(ctx, state, session, agent) do
    with {:ok, _pid} <- start_turn(ctx, state, session, agent, [], compact?: true, profile: :main) do
      {:ok, :turn}
    end
  end

  # A late Always (the turn that asked is gone) still counts for the rest of
  # the session, as for Claude Code; never on a once-only card.
  @impl true
  def reply_permission(_ctx, _state, request, reply) do
    sid = session_id_of(request)

    result =
      case sid && Codex.Supervisor.whereis(sid) do
        pid when is_pid(pid) -> Codex.Turn.answer(pid, request.opencode_permission_id, reply)
        _ -> {:error, :gone}
      end

    with {:error, :gone} <- result,
         :always <- reply,
         false <- get_in(request.metadata || %{}, ["once_only"]) == true,
         rule when rule != nil <- late_rule(request) do
      Approvals.remember(sid, rule)
    end

    result
  end

  defp late_rule(%{permission: "Bash", metadata: %{"always_prefix" => prefix} = metadata})
       when is_binary(prefix) do
    with false <- metadata["no_always"] == true,
         {:ok, [_ | _] = words} <- Codex.Allowance.lex(prefix),
         true <- Approvals.rememberable_prefix?(words) do
      {:command, words, metadata["unsandboxed"] == true}
    else
      _ -> nil
    end
  end

  defp late_rule(%{permission: "file_change"}), do: :file_change
  defp late_rule(_request), do: nil

  @impl true
  def reply_question(_ctx, _state, request, outcome) do
    case session_id_of(request) && Codex.Supervisor.whereis(session_id_of(request)) do
      pid when is_pid(pid) -> Codex.Turn.answer(pid, request.opencode_question_id, outcome)
      _ -> {:error, :gone}
    end
  end

  defp session_id_of(%{agent_session: %{engine_session_id: sid}}), do: sid

  defp session_id_of(%{agent_session_id: id}) when is_binary(id) do
    case AgentSessions.get(id) do
      %{engine_session_id: sid} -> sid
      _ -> nil
    end
  end

  defp session_id_of(_request), do: nil

  @impl true
  def reconcile(_ctx, _state) do
    pids = Map.keys(Codex.Supervisor.turns())

    # The turn names its own id (the thread id once renamed): the Registry
    # lists a renamed turn under both ids in no particular order.
    retrying =
      for pid <- pids, %{} = retry <- [Codex.Turn.retrying(pid)] do
        Map.take(retry, [:session_id, :message, :attempt])
      end

    open = Enum.flat_map(pids, &Codex.Turn.open_events/1)

    %{
      busy: Codex.Supervisor.running(),
      retrying: retrying,
      permissions: Enum.filter(open, &(&1.type == :approval_required)),
      questions: Enum.filter(open, &(&1.type == :question_required))
    }
  end

  @impl true
  def model_label(agent, profile \\ :main) do
    case resolve_profile(agent, profile, nil) do
      %{model_id: model} when is_binary(model) -> model
      _ -> "codex default"
    end
  end

  @impl true
  def model_error?(reason) when is_binary(reason),
    do:
      Regex.match?(
        ~r/model.{0,60}(not found|does not exist|not supported|is not available|unsupported)|unknown model|invalid model/i,
        reason
      )

  def model_error?(_reason), do: false

  @impl true
  def context_cap, do: @context_cap

  defp resolve_profile(agent, :light, settings),
    do:
      Agents.effective_profile(agent, :light, settings) ||
        Agents.effective_profile(agent, :main, settings)

  defp resolve_profile(agent, _main, settings),
    do: Agents.effective_profile(agent, :main, settings)

  # -- Transcripts ------------------------------------------------------------------------

  @impl true
  def transcript(_ctx, ref, opts) do
    case find(binary_name()) do
      {:ok, path} ->
        config_dir =
          case normalize_config_dir(configured_config_dir()) do
            {:ok, dir} -> dir
            _ -> nil
          end

        Codex.Transcript.read([binary: path, config_dir: config_dir], ref, opts)

      _ ->
        {:error, :unreachable}
    end
  end

  @doc """
  Where Codex keeps its threads: the config dir from the config override or
  Settings, else `config :canopy, :codex, default_config_dir:`, else
  `CODEX_HOME`, else `~/.codex`. Only used to tell people where history lives.
  """
  def transcripts_dir(settings \\ Settings.get()) do
    case normalize_config_dir(configured_config_dir(settings)) do
      {:ok, dir} when is_binary(dir) ->
        dir

      _ ->
        config(:default_config_dir, nil) || McpConfig.codex_home(nil)
    end
  end

  # -- MCP inventory ----------------------------------------------------------------------

  @doc """
  What a turn in the repository loads: Canopy's server, the user's
  `[mcp_servers.*]` from `$CODEX_HOME/config.toml`, and the repository's
  `.codex/config.toml` servers (when Codex trusts the project), with the
  status the newest turn reported. A user server named `canopy`, and the
  repository's `.mcp.json`, are listed as not loaded. Options: `:config_dir`.
  """
  @impl true
  def mcp_inventory(repository, opts) do
    canopy_name = Canopy.MCP.registration_name()

    config_dir =
      Keyword.get_lazy(opts, :config_dir, fn ->
        case normalize_config_dir(configured_config_dir()) do
          {:ok, dir} -> dir
          _ -> nil
        end
      end)

    user_path = McpConfig.user_path(config_dir)
    project_path = McpConfig.project_path(repository.path)

    {user, user_notes} = servers_from(user_path)
    {project, project_notes} = servers_from(project_path)

    canopy = %Inventory.Server{
      name: canopy_name,
      transport: :http,
      target: Redact.url(Canopy.MCP.url()),
      secrets: [Command.token_var()],
      source: %{kind: :canopy, path: nil},
      note: "Per-session token through bearer_token_env_var; Canopy's tools never ask."
    }

    clash =
      for {source, kind, path} <- [{user, :user, user_path}, {project, :project, project_path}],
          config = source[canopy_name],
          config != nil do
        %{
          McpConfig.to_server(canopy_name, config, %{kind: kind, path: path})
          | note:
              "Codex can't load Canopy's own server while this one has the same name; rename it."
        }
      end

    rows = fn servers, kind, path, note ->
      for {n, c} <- Enum.sort_by(servers, &elem(&1, 0)), n != canopy_name do
        %{McpConfig.to_server(n, c, %{kind: kind, path: path}) | note: note}
      end
    end

    loaded =
      ([canopy] ++
         rows.(user, :user, user_path, "From your Codex config.") ++
         rows.(project, :project, project_path, "Loaded when Codex trusts this project."))
      |> observe(AgentSessions.latest_mcp_servers(repository.id, name()))

    mcp_json = Path.join(repository.path, ".mcp.json")

    claude_format =
      if File.regular?(mcp_json) do
        [
          %Inventory.Server{
            name: ".mcp.json",
            transport: nil,
            source: %{kind: :project, path: mcp_json},
            enabled?: false,
            note: "Claude Code's format; Codex reads .codex/config.toml."
          }
        ]
      else
        []
      end

    {:ok,
     %Inventory.Engine{
       engine: name(),
       servers: loaded,
       ignored: clash ++ claude_format,
       notes: user_notes ++ project_notes
     }}
  end

  defp servers_from(path) do
    case McpConfig.read(path) do
      {:ok, config} -> {McpConfig.servers(config), []}
      {:error, reason} -> {%{}, ["Could not read #{reason}"]}
    end
  end

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

  # -- Turns ------------------------------------------------------------------------------

  defp start_turn(ctx, state, session, agent, input, opts) do
    settings = Settings.get()
    repo = ctx.repository.path

    with {:ok, config_dir} <- normalize_config_dir(configured_config_dir(settings)),
         {:ok, binary} <- binary(state),
         {:ok, _version} <- version(binary, config_dir),
         :ok <- McpConfig.canopy_clash(config_dir, repo),
         {:ok, fresh} <- AgentSessions.ensure_mcp_token(AgentSessions.get!(session.id)) do
      sid = fresh.engine_session_id
      dir = work_dir(sid)
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      mode = Map.get(agent, :permission_mode) || "default"
      {sandbox, approval} = Command.policy(mode)

      %{model_id: model, effort: effort} =
        resolve_profile(agent, Keyword.get(opts, :profile, :main), settings)

      effort = turn_effort(model, effort, binary, config_dir)

      shell_exclude =
        case McpConfig.read(McpConfig.user_path(config_dir)) do
          {:ok, config} ->
            McpConfig.shell_exclude(config)

          {:error, reason} ->
            Logger.warning("Codex: #{reason}; the turn runs without your shell env excludes")
            []
        end

      command =
        Command.build(
          binary: binary,
          cwd: repo,
          stderr_file: Path.join(dir, "stderr.log"),
          mcp_url: Canopy.MCP.url(),
          token: fresh.mcp_token,
          config_dir: config_dir,
          shell_exclude: shell_exclude,
          mcp_tool_timeout_ms: config(:mcp_tool_timeout_ms, :timer.minutes(30)),
          extra_env: config(:env, [])
        )

      thread_params = %{
        "cwd" => repo,
        "sandbox" => sandbox,
        "approvalPolicy" => approval,
        "approvalsReviewer" => Command.approvals_reviewer()
      }

      turn_params =
        %{
          "input" => input,
          "cwd" => repo,
          "approvalPolicy" => approval,
          "approvalsReviewer" => Command.approvals_reviewer(),
          "sandboxPolicy" => Command.sandbox_policy(mode, repo)
        }
        |> put_present("model", model)
        |> put_present("effort", effort)

      row_id = fresh.id
      repository_id = ctx.repository.id

      turn_opts =
        [
          repository_id: repository_id,
          cwd: repo,
          command: command,
          flag: if(fresh.last_seen_at != nil, do: :resume, else: :new),
          thread_params: thread_params,
          turn_params: turn_params,
          system: opts[:system],
          compact?: Keyword.get(opts, :compact?, false),
          permission_mode: mode,
          work_dir: &work_dir/1,
          on_thread_id: fn old, new -> rename_session(row_id, old, new) end
        ]
        |> put_config(:stall_ms)
        |> put_config(:item_stall_ms)

      case Codex.Supervisor.start_turn(sid, turn_opts) do
        {:ok, pid} ->
          # A new session is marked seen by its rename, once Codex has started
          # its thread: a turn that dies before that starts a thread next time.
          if fresh.last_seen_at, do: {:ok, _} = AgentSessions.touch(fresh)
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A stranded effort (the model doesn't offer it) is left out, so Codex
  # uses the model's default, when the cached list says so. Never fetched
  # at turn time.
  defp turn_effort(nil, effort, _binary, _config_dir), do: effort
  defp turn_effort(_model, nil, _binary, _config_dir), do: nil

  defp turn_effort(model, effort, binary, config_dir) do
    case Models.cached(binary: binary, config_dir: config_dir) do
      {:ok, models} ->
        case Models.find(models, model) do
          %{efforts: [_ | _] = efforts} ->
            if effort in efforts do
              effort
            else
              Logger.warning("Codex: #{model} doesn't offer effort #{effort}; using its default")
              nil
            end

          _ ->
            effort
        end

      _ ->
        effort
    end
  end

  @doc """
  Renames a session to its Codex thread id (§5.5): the row, its timeline
  events (so the transcript never lists the placeholder), the Always rules,
  then the runtime, told on the old topic. The channel server
  resubscribes and acks; the transcript page follows. Runs in the turn
  process, before any event goes out under the new id. `{:error,
  :session_gone}` when the row was reset meanwhile: the turn ends quietly.
  """
  def rename_session(row_id, old, new) do
    case AgentSessions.put_engine_session_id(row_id, new) do
      {:ok, _} ->
        _ = Canopy.Timeline.rename_engine_session(row_id, old, new)
        result = renamed(old, new)
        # The channel server writes the turn's agent_started after send_prompt
        # returns, so a fast rename can beat it; the ack comes from that same
        # process, so by now the event exists. The rewrite is idempotent. If no
        # ack came within :rename_ack_ms (no runtime listening, or a busy one)
        # an agent_started written later keeps the placeholder id.
        _ = Canopy.Timeline.rename_engine_session(row_id, old, new)
        result

      {:error, :not_found} ->
        Logger.info("Codex: session #{old} was reset before its rename to #{new}")
        {:error, :session_gone}
    end
  end

  defp renamed(old, new) do
    Approvals.rename(old, new)
    ref = make_ref()

    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      Canopy.Engine.session_topic(old),
      {:engine_session_renamed, old, new, {self(), ref}}
    )

    receive do
      {:engine_session_renamed_ack, ^ref} -> :ok
    after
      config(:rename_ack_ms, @rename_ack_ms) ->
        Logger.info("Codex: no runtime acknowledged the rename of #{old} to #{new}")
        :ok
    end
  end

  defp put_config(opts, key) do
    case config(key, nil) do
      ms when is_integer(ms) and ms > 0 -> Keyword.put(opts, key, ms)
      _ -> opts
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp binary(%{binary_path: path}) when is_binary(path), do: {:ok, path}
  defp binary(%{binary: name}), do: {:error, "#{name} not found on PATH"}

  @doc "The session's scratch dir: stderr, the instructions hash, image attachments."
  def work_dir(sid), do: Path.join([System.tmp_dir!(), "canopy-codex", sid])

  # The prompt as Codex input items: the text, then each attachment the plan
  # marks as a part (images written to the work dir as local images, text
  # files inline). Path-mode documents were materialised under the
  # repository and the text names them.
  defp input(text, plan, sid) do
    {items, attached} =
      Enum.reduce(plan, {[], 0}, fn
        {document, :part}, {items, n} ->
          case attachment_item(document, sid) do
            nil -> {items, n}
            item -> {[item | items], n + 1}
          end

        {_document, :path}, acc ->
          acc
      end)

    {[text_item(text) | Enum.reverse(items)], attached}
  end

  defp text_item(text), do: %{"type" => "text", "text" => text, "text_elements" => []}

  defp attachment_item(%{kind: "image"} = document, sid) do
    with {:ok, bytes} <- Documents.read(document) do
      dir = work_dir(sid)
      File.mkdir_p!(dir)
      path = Path.join(dir, "#{document.id}#{Path.extname(document.filename || "")}")
      File.write!(path, bytes)
      %{"type" => "localImage", "path" => path}
    else
      _ -> nil
    end
  end

  defp attachment_item(%{kind: "text"} = document, _sid) do
    case Documents.read(document) do
      {:ok, bytes} ->
        text = if String.valid?(bytes), do: bytes, else: String.replace_invalid(bytes)
        text_item("Attached file #{document.filename}:\n\n" <> text)

      _ ->
        nil
    end
  end

  defp attachment_item(_document, _sid), do: nil

  # -- Config -----------------------------------------------------------------------------

  @doc "The config dir from the config override or Settings; nil for the user's own."
  def configured_config_dir(settings \\ Settings.get()) do
    (config(:config_dir, nil) || Map.get(settings, :codex_config_dir))
    |> Setting.normalize_config_dir()
  end

  defp normalize_config_dir(nil), do: {:ok, nil}

  defp normalize_config_dir(value) do
    case Setting.normalize_config_dir(value) do
      nil ->
        {:ok, nil}

      path ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, "Codex config directory must be an absolute path"}
    end
  end

  # Codex refuses a CODEX_HOME that does not exist, so the check says so.
  defp existing_config_dir(value) do
    with {:ok, dir} <- normalize_config_dir(value) do
      if dir == nil or File.dir?(dir),
        do: {:ok, dir},
        else: {:error, "Codex config directory #{dir} does not exist"}
    end
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:canopy, :codex, []), key, default)
end
