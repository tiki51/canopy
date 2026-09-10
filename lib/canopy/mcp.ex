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

  # -- Registration bookkeeping ------------------------------------------------
  #
  # OpenCode reads Canopy's tool list when it connects to the MCP server and
  # keeps it for the life of that connection, so a Canopy upgrade that adds a
  # tool would go unseen by a running OpenCode. Re-registering forces a fresh
  # connection. These marks make that happen once per repository per Canopy
  # boot, and again after the token rotates.

  @doc "True if this Canopy process already registered with OpenCode for the repository, with the current token."
  def registered_this_boot?(repository_id) do
    :persistent_term.get({__MODULE__, :registered, repository_id}, nil) == Settings.mcp_token()
  end

  @doc "Records that the registration for the repository was posted by this Canopy process."
  def mark_registered(repository_id) do
    :persistent_term.put({__MODULE__, :registered, repository_id}, Settings.mcp_token())
  end
end
