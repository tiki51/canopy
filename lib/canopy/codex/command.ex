defmodule Canopy.Codex.Command do
  @moduledoc """
  Builds the `codex app-server` command line for one turn, and maps an
  agent's permission mode to Codex's sandbox and approval settings. Pure.

  The process is spawned through `/bin/sh -c 'exec "$0" "$@" 2>>stderr'` so
  Codex's tracing logs go to a file and never touch the JSON-RPC on stdout.
  Canopy's MCP server is configured with `-c` overrides; the session's bearer
  token travels in the environment only (`bearer_token_env_var`), so `ps`
  never shows it, and `shell_environment_policy.exclude` keeps it, and every
  other `CANOPY_*` variable (the database path, the URL), out of the agent's
  own shell commands.

  Sandbox and approval are not flags: they go on `thread/start`,
  `thread/resume` and `turn/start` (`policy/1`, `sandbox_policy/2`), so a
  changed permission mode takes effect on the next turn. No permission mode
  maps to `danger-full-access` or to `never`.
  """

  alias Canopy.ClaudeCode.Command, as: ClaudeCommand

  @type t :: %{
          executable: String.t(),
          args: [String.t()],
          env: [{charlist(), charlist() | false}],
          cwd: String.t()
        }

  @token_var "CANOPY_MCP_TOKEN"

  @doc "The environment variable the session's MCP token travels in."
  def token_var, do: @token_var

  @doc """
  Options:

    * `:binary` (required) — the `codex` executable
    * `:cwd` (required) — the repository path
    * `:stderr_file` (required) — where stderr is appended
    * `:mcp_url` — Canopy's MCP endpoint; with `:token`, Canopy's server is configured
    * `:token` — the session's MCP bearer token (environment only)
    * `:config_dir` — `CODEX_HOME`, only when set
    * `:shell_exclude` — the user's own `shell_environment_policy.exclude`
    * `:mcp_tool_timeout_ms` — how long a Canopy tool call may block
    * `:extra_env` — `[{"KEY", "value"}]`, appended last (tests point the fake at a script)
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    binary = Keyword.fetch!(opts, :binary)
    stderr = Keyword.fetch!(opts, :stderr_file)

    %{
      executable: "/bin/sh",
      args: ["-c", ~s(exec "$0" "$@" 2>>"#{stderr}"), binary | args(opts)],
      env: env(opts),
      cwd: Keyword.fetch!(opts, :cwd)
    }
  end

  @doc "The arguments after the binary: `app-server` and its `-c` overrides."
  def args(opts) do
    canopy = Canopy.MCP.registration_name()

    mcp =
      case opts[:mcp_url] do
        url when is_binary(url) ->
          timeout = div(opts[:mcp_tool_timeout_ms] || :timer.minutes(30), 1000)

          config("mcp_servers.#{canopy}.url", url) ++
            config("mcp_servers.#{canopy}.bearer_token_env_var", @token_var) ++
            config("mcp_servers.#{canopy}.default_tools_approval_mode", "approve") ++
            config("mcp_servers.#{canopy}.tool_timeout_sec", timeout) ++
            config("mcp_servers.#{canopy}.startup_timeout_sec", 20)

        _ ->
          []
      end

    exclude = Enum.uniq(List.wrap(opts[:shell_exclude]) ++ [@token_var, "CANOPY_*"])

    ["app-server", "--listen", "stdio://"] ++
      mcp ++
      config("shell_environment_policy.exclude", exclude) ++
      config("notify", [])
  end

  # `-c key=value`, where value is TOML. A JSON string or array of strings
  # is valid TOML.
  defp config(key, value), do: ["-c", "#{key}=#{JSON.encode!(value)}"]

  @doc "The environment for the port: release cleanup, `CODEX_HOME`, the token."
  def env(opts) do
    release =
      Enum.map(ClaudeCommand.release_env(), fn
        {k, nil} -> {String.to_charlist(k), false}
        {k, v} -> {String.to_charlist(k), String.to_charlist(v)}
      end)

    home =
      case opts[:config_dir] do
        dir when is_binary(dir) and dir != "" -> [{~c"CODEX_HOME", String.to_charlist(dir)}]
        _ -> []
      end

    token =
      case opts[:token] do
        t when is_binary(t) and t != "" ->
          [{String.to_charlist(@token_var), String.to_charlist(t)}]

        _ ->
          [{String.to_charlist(@token_var), false}]
      end

    extra =
      Enum.map(opts[:extra_env] || [], fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    release ++ home ++ token ++ extra
  end

  @doc """
  `{sandbox, approvalPolicy}` for an agent's permission mode, as spelled in
  codex 0.163: plan is read-only and asks before leaving the sandbox; ask
  only outside the sandbox writes in the repository; anything else (ask
  first) writes in the repository and asks before every command.
  """
  def policy("plan"), do: {"read-only", "on-request"}
  def policy("acceptEdits"), do: {"workspace-write", "on-request"}
  def policy(_mode), do: {"workspace-write", "untrusted"}

  @doc """
  The structured sandbox pinned on every `turn/start`, so the user's own
  `[sandbox_workspace_write]` (writable roots, network) never widens a Canopy
  agent: writes only in the repository (and the tmp dirs builds need), no
  network. Plan is read-only, no network.
  """
  def sandbox_policy("plan", _repository_path),
    do: %{"type" => "readOnly", "networkAccess" => false}

  def sandbox_policy(_mode, repository_path) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [resolve(repository_path)],
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  @doc "Where approval requests are reviewed: always by the user, through Canopy's cards."
  def approvals_reviewer, do: "user"

  @doc "The repository path expanded with its symlinks resolved, as Codex compares paths."
  # Every component is resolved, so `/var/…` on macOS becomes `/private/var/…`;
  # a component that does not exist (yet) is kept as it is. A link's target is
  # resolved in turn (a chain of links, or a target under another link), up
  # to a depth that stops a loop.
  def resolve(path), do: resolve(path, 0)

  @max_links 40

  defp resolve(path, depth) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce(nil, fn
      part, nil ->
        part

      part, acc ->
        next = Path.join(acc, part)

        case depth < @max_links and :file.read_link_all(String.to_charlist(next)) do
          {:ok, target} -> resolve(Path.expand(to_string(target), acc), depth + 1)
          _ -> next
        end
    end)
  end

  @doc "The `clientInfo` Canopy introduces itself with on `initialize`."
  def client_info do
    %{
      "clientInfo" => %{
        "name" => "canopy",
        "title" => "Canopy",
        "version" => to_string(Application.spec(:canopy, :vsn) || "0")
      },
      "capabilities" => %{"experimentalApi" => false, "requestAttestation" => false}
    }
  end
end
