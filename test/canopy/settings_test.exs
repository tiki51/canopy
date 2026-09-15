defmodule Canopy.SettingsTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Settings, Users}

  test "get/0 creates the default row with a token on first call" do
    setting = Settings.get()
    assert setting.id == "default"
    assert setting.opencode_url == "http://127.0.0.1:4096"
    assert setting.user_display_name == "You"
    assert byte_size(setting.mcp_token) >= 43
    assert Settings.get().mcp_token == setting.mcp_token
  end

  test "rotate_mcp_token/0 replaces the token" do
    before = Settings.get().mcp_token
    assert {:ok, rotated} = Settings.rotate_mcp_token()
    assert rotated.mcp_token != before
    assert Settings.get().mcp_token == rotated.mcp_token
  end

  test "update/1 validates the url and syncs the local user's name" do
    user = Users.local()
    assert user.display_name == "You"

    assert {:error, changeset} = Settings.update(%{opencode_url: "not a url"})
    assert %{opencode_url: [_]} = errors_on(changeset)

    assert {:ok, setting} =
             Settings.update(%{
               opencode_url: "http://localhost:5000",
               user_display_name: "Steven"
             })

    assert setting.opencode_url == "http://localhost:5000"
    assert Users.get!(user.id).display_name == "Steven"
  end

  test "Claude config directory expands HOME and must be absolute" do
    assert {:ok, setting} = Settings.update(%{claude_config_dir: "~/.claude-agents"})
    assert setting.claude_config_dir == Path.join(System.user_home!(), ".claude-agents")

    assert {:error, changeset} = Settings.update(%{claude_config_dir: "relative/path"})
    assert %{claude_config_dir: ["must be an absolute path"]} = errors_on(changeset)
  end
end
