defmodule Canopy.MCPTest do
  use Canopy.DataCase, async: false

  alias Canopy.MCP
  alias Canopy.Settings

  test "registration_config/1 points OpenCode at the /mcp endpoint with the bearer token" do
    config = MCP.registration_config("tok_123")

    assert config == %{
             type: "remote",
             url: CanopyWeb.Endpoint.url() <> "/mcp",
             headers: %{"Authorization" => "Bearer tok_123"},
             enabled: true
           }

    assert String.ends_with?(config.url, "/mcp")

    assert MCP.registration_config(Settings.get()) ==
             MCP.registration_config(Settings.mcp_token())

    assert MCP.registration_config(:current) == MCP.registration_config(Settings.mcp_token())
    assert MCP.registration_name() == "canopy"
  end

  test "plugin_source/0 stamps the session id into canopy_ tool calls" do
    source = MCP.plugin_source()
    assert source =~ "tool.execute.before"
    assert source =~ ~s|startsWith("canopy_")|
    assert source =~ "output.args.canopy_session_id = input.sessionID"
    assert source =~ "export const"
  end
end
