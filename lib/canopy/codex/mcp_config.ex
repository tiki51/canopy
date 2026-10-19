defmodule Canopy.Codex.McpConfig do
  @moduledoc """
  Reads the Codex config files a turn loads: the user's
  `$CODEX_HOME/config.toml` and the repository's `.codex/config.toml` (loaded
  by Codex when it trusts the project). Canopy needs three things from them:

    * the `[mcp_servers.*]` tables, for the repository page's inventory;
    * whether one is named `canopy`: Canopy's own `-c mcp_servers.canopy.…`
      overrides merge into such a table and Codex then refuses the turn, so
      the check and the turn report the clash instead;
    * the user's `shell_environment_policy.exclude`, because Canopy's own
      `-c` list replaces it and has to carry the user's entries along.

  A file that is missing reads as empty; one that cannot be parsed is an
  `{:error, reason}` that never quotes the file's contents.
  """

  alias Canopy.ClaudeCode.MCPConfig, as: ClaudeConfig

  @doc """
  The directory Codex uses as `CODEX_HOME` for a turn: the configured
  directory, else `config :canopy, :codex, default_config_dir:` (tests point
  it at fixtures), else the `CODEX_HOME` Canopy's own turns inherit, else
  `~/.codex`.
  """
  def codex_home(config_dir) do
    default = Keyword.get(Application.get_env(:canopy, :codex, []), :default_config_dir)

    case config_dir || default do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        case System.get_env("CODEX_HOME") do
          home when is_binary(home) and home != "" -> home
          _ -> Path.join(System.user_home!(), ".codex")
        end
    end
  end

  def user_path(config_dir), do: Path.join(codex_home(config_dir), "config.toml")
  def project_path(repository_path), do: Path.join([repository_path, ".codex", "config.toml"])

  @doc "A config file as a map; `{:ok, %{}}` when it does not exist."
  def read(path) do
    case File.read(path) do
      {:ok, text} ->
        case Toml.decode(text) do
          {:ok, %{} = map} -> {:ok, map}
          {:error, _reason} -> {:error, "#{path} is not valid TOML"}
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "The `[mcp_servers.*]` tables of a config, by name."
  def servers(%{"mcp_servers" => servers}) when is_map(servers),
    do: for({name, c} <- servers, is_map(c), into: %{}, do: {name, c})

  def servers(_config), do: %{}

  @doc "The user's own `shell_environment_policy.exclude` patterns."
  def shell_exclude(%{"shell_environment_policy" => %{"exclude" => list}}) when is_list(list),
    do: for(item <- list, is_binary(item), do: item)

  def shell_exclude(_config), do: []

  @doc """
  `{:error, reason}` when the user's config or the repository's defines an
  MCP server with Canopy's name; `:ok` otherwise (an unreadable file is not a
  clash: Codex reports its own error for it).
  """
  def canopy_clash(config_dir, repository_path \\ nil) do
    name = Canopy.MCP.registration_name()

    paths =
      [user_path(config_dir)] ++
        if(repository_path, do: [project_path(repository_path)], else: [])

    Enum.find_value(paths, :ok, fn path ->
      case read(path) do
        {:ok, config} ->
          if Map.has_key?(servers(config), name),
            do:
              {:error,
               "#{path} defines an MCP server named #{name}; rename it so Canopy's own can load"}

        _ ->
          nil
      end
    end)
  end

  @doc """
  A Codex server table as an inventory row, redacted: the command line for a
  stdio server, the URL for an HTTP one. `env`, `http_headers` and the name of
  `bearer_token_env_var` are listed as secrets.
  """
  def to_server(name, config, source) when is_map(config) do
    headers = config["http_headers"] || config["headers"] || %{}

    row =
      ClaudeConfig.to_server(name, Map.put(config, "headers", headers), source)

    case config["bearer_token_env_var"] do
      var when is_binary(var) -> %{row | secrets: Enum.uniq(row.secrets ++ [var])}
      _ -> row
    end
  end
end
