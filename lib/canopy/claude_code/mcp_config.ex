defmodule Canopy.ClaudeCode.MCPConfig do
  @moduledoc """
  Claude Code's MCP config files, as far as Canopy cares.

  Every turn runs with `--strict-mcp-config --mcp-config <file>`, where the
  file Canopy writes holds its own `canopy` server plus the servers of the
  repository's `.mcp.json` (`project_servers/1`). Everything else Claude Code
  would normally load stays out: the user and local scopes in `~/.claude.json`
  (or the `.claude.json` inside the configured `CLAUDE_CONFIG_DIR`) and an
  organisation's `managed-mcp.json`. `other_sources/2` lists those for the
  repository page.

  The files are read on demand and never cached. `~/.claude.json` can be large
  and holds much more than MCP servers: only its two MCP keys are kept, and
  nothing from it is logged. Errors never quote file content, only where the
  JSON broke.
  """

  alias Canopy.MCP.Inventory.Server
  alias Canopy.MCP.Redact

  @doc "The repository's project-scope config file."
  def project_path(repository_path), do: Path.join(repository_path, ".mcp.json")

  @doc """
  The servers in the repository's `.mcp.json`, as Claude Code's own config
  maps (`%{name => %{"command", "args", "env"} | %{"type", "url", "headers"}}`).
  `{:ok, %{}}` when there is no file; `{:error, reason}` when it cannot be used.
  """
  @spec project_servers(String.t()) :: {:ok, map()} | {:error, String.t()}
  def project_servers(repository_path) do
    path = project_path(repository_path)

    case File.read(path) do
      {:ok, text} -> parse_servers(text)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "could not read: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  def parse_servers(text) do
    with {:ok, decoded} <- decode(text) do
      case decoded do
        %{"mcpServers" => servers} when is_map(servers) ->
          case Enum.reject(servers, fn {_name, config} -> is_map(config) end) do
            [] -> {:ok, servers}
            [{name, _} | _] -> {:error, "server #{inspect(name)} is not a JSON object"}
          end

        %{"mcpServers" => _} ->
          {:error, "\"mcpServers\" is not a JSON object"}

        %{} ->
          {:ok, %{}}

        _ ->
          {:error, "the file is not a JSON object"}
      end
    end
  end

  @doc """
  The MCP servers configured outside the repository that Canopy's agents do
  not load: `{[%{name, config, kind, path}], errors}` where `kind` is `:user`,
  `:local` (the repository's entry in `.claude.json`), or `:managed`.

  Options (tests point them at fixtures): `:home` (default the user's home),
  `:config_dir` (a `CLAUDE_CONFIG_DIR`; its `.claude.json` replaces the one in
  home), `:managed_path`.
  """
  def other_sources(repository_path, opts \\ []) do
    claude_json = claude_json_path(opts)
    managed = opts[:managed_path] || default_managed_path()

    {from_claude, claude_errors} =
      case read_json(claude_json) do
        :missing ->
          {[], []}

        {:ok, %{} = json} ->
          user = entries(json["mcpServers"], :user, claude_json)

          local =
            json
            |> get_in(["projects", repository_path, "mcpServers"])
            |> entries(:local, claude_json)

          {local ++ user, []}

        {:ok, _} ->
          {[], ["#{claude_json}: not a JSON object"]}

        {:error, reason} ->
          {[], ["#{claude_json}: #{reason}"]}
      end

    {from_managed, managed_errors} =
      case read_json(managed) do
        :missing -> {[], []}
        {:ok, %{} = json} -> {entries(json["mcpServers"], :managed, managed), []}
        {:ok, _} -> {[], ["#{managed}: not a JSON object"]}
        {:error, reason} -> {[], ["#{managed}: #{reason}"]}
      end

    {from_claude ++ from_managed, claude_errors ++ managed_errors}
  end

  @doc "Where Claude Code keeps its user-level `.claude.json` for these options."
  def claude_json_path(opts \\ []) do
    case Keyword.get(opts, :config_dir) do
      dir when is_binary(dir) and dir != "" ->
        Path.join(dir, ".claude.json")

      _ ->
        Path.join(opts[:home] || System.user_home!(), ".claude.json")
    end
  end

  defp default_managed_path do
    case :os.type() do
      {:unix, :darwin} -> "/Library/Application Support/ClaudeCode/managed-mcp.json"
      _ -> "/etc/claude-code/managed-mcp.json"
    end
  end

  defp entries(servers, kind, path) when is_map(servers) do
    for {name, config} <- Enum.sort_by(servers, &elem(&1, 0)), is_map(config) do
      %{name: name, config: config, kind: kind, path: path}
    end
  end

  defp entries(_servers, _kind, _path), do: []

  @doc """
  A server config as an inventory row, redacted: `stdio` (the default when a
  `command` is given) shows the command line, `http` and `sse` the URL; `env`
  and `headers` keys are listed as secrets.
  """
  def to_server(name, config, source) when is_map(config) do
    {_env, env_keys} = Redact.map(config["env"] || %{})
    {_headers, header_keys} = Redact.map(config["headers"] || %{})
    transport = transport(config)

    target =
      case transport do
        :stdio -> Redact.command([config["command"] | List.wrap(config["args"])])
        _ -> Redact.url(config["url"])
      end

    %Server{
      name: name,
      transport: transport,
      target: target,
      secrets: Enum.uniq(env_keys ++ header_keys),
      source: source
    }
  end

  defp transport(%{"type" => "http"}), do: :http
  defp transport(%{"type" => "sse"}), do: :sse
  defp transport(%{"type" => "streamable-http"}), do: :http
  defp transport(%{"url" => url}) when is_binary(url), do: :http
  defp transport(_), do: :stdio

  defp read_json(path) do
    case File.read(path) do
      {:ok, text} -> decode(text)
      {:error, :enoent} -> :missing
      {:error, :enotdir} -> :missing
      {:error, reason} -> {:error, "could not read: #{:file.format_error(reason)}"}
    end
  end

  # The error says where the JSON broke, never what it held.
  defp decode(text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, {:unexpected_end, _}} -> {:error, "invalid JSON: unexpected end of file"}
      {:error, {_kind, offset, _}} -> {:error, "invalid JSON at byte #{offset}"}
      {:error, {_kind, offset}} -> {:error, "invalid JSON at byte #{offset}"}
      {:error, _} -> {:error, "invalid JSON"}
    end
  end
end
