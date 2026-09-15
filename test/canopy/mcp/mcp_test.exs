defmodule Canopy.MCPTest do
  use Canopy.DataCase, async: false

  alias Canopy.MCP
  alias Canopy.Settings

  test "registration_config/1 points OpenCode at the /mcp endpoint with the bearer token" do
    previous = Application.get_env(:canopy, :public_url)
    Application.put_env(:canopy, :public_url, "http://127.0.0.1:4567")
    on_exit(fn -> Application.put_env(:canopy, :public_url, previous) end)

    config = MCP.registration_config("tok_123")

    assert config == %{
             type: "remote",
             url: "http://127.0.0.1:4567/mcp",
             headers: %{"Authorization" => "Bearer tok_123"},
             enabled: true
           }

    assert String.ends_with?(config.url, "/mcp")

    assert MCP.registration_config(Settings.get()) ==
             MCP.registration_config(Settings.mcp_token())

    assert MCP.registration_config(:current) == MCP.registration_config(Settings.mcp_token())
    assert MCP.registration_name() == "canopy"
  end

  test "global_plugin_path/0 honors XDG_CONFIG_HOME" do
    previous = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", "/tmp/canopy-config")

    on_exit(fn ->
      if previous,
        do: System.put_env("XDG_CONFIG_HOME", previous),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    assert MCP.global_plugin_path() == "/tmp/canopy-config/opencode/plugins/canopy.js"
  end

  test "plugin_source/0 stamps the session id into canopy_ tool calls" do
    source = MCP.plugin_source()
    assert source =~ "tool.execute.before"
    assert source =~ ~s|startsWith("canopy_")|
    assert source =~ "output.args.canopy_session_id = input.sessionID"
    assert source =~ "export const"
  end

  test "ensure_project_plugin/1 writes the plugin once, keeps it out of git, and refreshes a stale copy" do
    path = Canopy.Fixtures.git_dir_fixture()
    plugin = Canopy.MCP.project_plugin_path(path)

    assert {:ok, :installed} = Canopy.MCP.ensure_project_plugin(path)
    assert File.read!(plugin) == Canopy.MCP.plugin_source()
    assert File.read!(Path.join(path, ".git/info/exclude")) =~ "\n.opencode/\n"
    assert {:ok, []} = Canopy.Repositories.status(path)

    assert {:ok, :present} = Canopy.MCP.ensure_project_plugin(path)

    File.write!(plugin, "// old version\n")
    assert {:ok, :installed} = Canopy.MCP.ensure_project_plugin(path)
    assert File.read!(plugin) == Canopy.MCP.plugin_source()

    assert length(String.split(File.read!(Path.join(path, ".git/info/exclude")), ".opencode/")) ==
             2
  end
end
