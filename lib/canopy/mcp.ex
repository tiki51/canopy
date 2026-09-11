defmodule Canopy.MCP do
  @moduledoc """
  The Canopy MCP server as seen from OpenCode.

  Two pieces travel to OpenCode: the registration config posted to `/mcp`
  (`registration_config/1`) and the identity plugin the user installs once
  (`plugin_source/0`). The plugin stamps the real OpenCode session id into
  every `canopy_*` tool call; `Canopy.MCP.Identity` resolves it.
  """

  alias Canopy.Settings

  @registration_name "canopy"

  @plugin_source """
  // Canopy identity plugin for OpenCode.
  // Install at ~/.config/opencode/plugins/canopy.js and restart `opencode serve`.
  // Overwrites `canopy_session_id` in every canopy_* tool call with the real
  // OpenCode session id, so Canopy can tell which agent is calling.
  export const CanopyIdentity = async () => ({
    "tool.execute.before": async (input, output) => {
      if (typeof input.tool === "string" && input.tool.startsWith("canopy_")) {
        output.args.canopy_session_id = input.sessionID
      }
    },
  })
  """

  @doc "The name under which Canopy registers its MCP server with OpenCode."
  def registration_name, do: @registration_name

  @doc "The public URL of the MCP endpoint, derived from the Phoenix endpoint."
  def url, do: CanopyWeb.Endpoint.url() <> "/mcp"

  @doc """
  The config map to POST to OpenCode's `/mcp` as `%{name: registration_name(), config: ...}`.

  Accepts the bearer token, a `%Canopy.Settings.Setting{}`, or `:current` to
  read the token from settings.
  """
  def registration_config(token) when is_binary(token) do
    %{
      type: "remote",
      url: url(),
      headers: %{"Authorization" => "Bearer " <> token},
      enabled: true
    }
  end

  def registration_config(%Settings.Setting{mcp_token: token}), do: registration_config(token)
  def registration_config(:current), do: registration_config(Settings.mcp_token())

  @doc "JavaScript source of the OpenCode identity plugin."
  def plugin_source, do: @plugin_source

  # -- Identity plugin, per repository ------------------------------------------
  #
  # OpenCode loads project plugins from `<repo>/.opencode/plugins/` when it
  # creates its instance for that directory. Installing ours there means every
  # registered repository stamps session ids, whether or not the user set up
  # the global copy. The directory is kept out of git via `.git/info/exclude`.

  @doc "The path of the project-local plugin for a repository."
  def project_plugin_path(repository_path),
    do: Path.join([repository_path, ".opencode", "plugins", "canopy.js"])

  @doc """
  Writes the identity plugin into the repository if missing or outdated.
  Returns `{:ok, :installed}` when the file changed (OpenCode's instance for the
  directory must then be disposed to load it), `{:ok, :present}` when it was
  already current, or `{:error, reason}`.
  """
  def ensure_project_plugin(repository_path) when is_binary(repository_path) do
    path = project_plugin_path(repository_path)

    case File.read(path) do
      {:ok, current} when current == @plugin_source ->
        {:ok, :present}

      _ ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, @plugin_source),
             :ok <- exclude_from_git(repository_path, ".opencode/") do
          {:ok, :installed}
        end
    end
  end

  defp exclude_from_git(repository_path, line) do
    git_dir = Path.join(repository_path, ".git")

    if File.dir?(git_dir) do
      exclude = Path.join([git_dir, "info", "exclude"])

      with :ok <- File.mkdir_p(Path.dirname(exclude)) do
        current =
          case File.read(exclude) do
            {:ok, c} -> c
            _ -> ""
          end

        if line in String.split(current, "\n") do
          :ok
        else
          sep = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
          File.write(exclude, current <> sep <> "# Canopy identity plugin\n" <> line <> "\n")
        end
      end
    else
      :ok
    end
  end

  # -- Registration bookkeeping ------------------------------------------------
  #
  # OpenCode reads Canopy's tool list when it connects to the MCP server and
  # keeps it for the life of that connection, so a Canopy upgrade that adds a
  # tool would go unseen by a running OpenCode. Re-registering forces a fresh
  # connection. These marks make that happen once per repository per Canopy
  # boot, and again after the token rotates.

  @doc """
  True if this Canopy process already registered with OpenCode for the
  repository, with the current token and the current set of tools. OpenCode
  reads the tool list at registration, so a tool added since (a code reload in
  dev, an upgrade) needs a new registration or agents never see it.
  """
  def registered_this_boot?(repository_id) do
    :persistent_term.get({__MODULE__, :registered, repository_id}, nil) == registration_key()
  end

  @doc "Records that the registration for the repository was posted by this Canopy process."
  def mark_registered(repository_id) do
    :persistent_term.put({__MODULE__, :registered, repository_id}, registration_key())
  end

  defp registration_key, do: {Settings.mcp_token(), Canopy.MCP.Server.tool_names()}
end
