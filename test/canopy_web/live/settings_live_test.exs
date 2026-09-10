defmodule CanopyWeb.SettingsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.{MCP, Settings}

  setup :set_mox_global
  setup :verify_on_exit!

  test "renders the three panels with the current values", %{conn: conn} do
    setting = Settings.get()
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#opencode-panel")
    assert has_element?(view, "#profile-panel")
    assert has_element?(view, "#mcp-panel")

    assert has_element?(
             view,
             "#opencode-form input[name='setting[opencode_url]'][value='#{setting.opencode_url}']"
           )

    assert has_element?(
             view,
             "#profile-form input[name='setting[user_display_name]'][value='#{setting.user_display_name}']"
           )
  end

  test "saves the OpenCode server URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#opencode-form", setting: %{opencode_url: "http://127.0.0.1:5555"})
    |> render_submit()

    assert Settings.get().opencode_url == "http://127.0.0.1:5555"
    assert has_element?(view, "#opencode-form input[value='http://127.0.0.1:5555']")
  end

  test "rejects an invalid OpenCode URL inline", %{conn: conn} do
    original = Settings.get().opencode_url
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#opencode-form", setting: %{opencode_url: "not a url"})
    |> render_submit()

    assert has_element?(view, "#opencode-form", "must be an http or https URL")
    assert Settings.get().opencode_url == original
  end

  test "saves the display name and syncs the local user", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#profile-form", setting: %{user_display_name: "Steven"})
    |> render_submit()

    assert Settings.get().user_display_name == "Steven"
    assert Canopy.Users.local().display_name == "Steven"
  end

  test "check connection shows the server version on success", %{conn: conn} do
    stub(OC, :health, fn opts ->
      assert Keyword.fetch!(opts, :base_url) == Settings.get().opencode_url
      {:ok, %{"healthy" => true, "version" => "1.18.11"}}
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-connection") |> render_click()
    render_async(view)

    assert has_element?(view, "#health-result", "Connected")
    assert has_element?(view, "#health-result", "1.18.11")
  end

  test "check connection uses the URL typed in the form, before saving", %{conn: conn} do
    test_pid = self()

    stub(OC, :health, fn opts ->
      send(test_pid, {:checked, Keyword.fetch!(opts, :base_url)})
      {:ok, %{"healthy" => true}}
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#opencode-form", setting: %{opencode_url: "http://127.0.0.1:9999"})
    |> render_change()

    view |> element("#check-connection") |> render_click()
    render_async(view)

    assert_receive {:checked, "http://127.0.0.1:9999"}
    assert has_element?(view, "#health-result", "Connected")
  end

  test "check connection shows a readable error when the server is down", %{conn: conn} do
    stub(OC, :health, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-connection") |> render_click()
    render_async(view)

    assert has_element?(view, "#health-result", "connection refused")
  end

  test "check connection reports an unhealthy server", %{conn: conn} do
    stub(OC, :health, fn _opts -> {:ok, %{"healthy" => false, "version" => "0.9.0"}} end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#check-connection") |> render_click()
    render_async(view)

    assert has_element?(view, "#health-result", "unhealthy")
  end

  test "rotating the token replaces the MCP token", %{conn: conn} do
    before = Settings.mcp_token()
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#rotate-token") |> render_click()

    after_token = Settings.mcp_token()
    assert after_token != before
    assert has_element?(view, "#mcp-token[data-token='#{after_token}']")
  end

  test "the token is masked until revealed", %{conn: conn} do
    token = Settings.mcp_token()
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute has_element?(view, "#mcp-token", token)

    view |> element("#toggle-token") |> render_click()

    assert has_element?(view, "#mcp-token", token)
  end

  test "shows the MCP endpoint URL and the identity plugin source", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#mcp-url", MCP.url())
    assert has_element?(view, "#plugin-source", "CanopyIdentity")
    assert has_element?(view, "#plugin-source", "canopy_session_id")
    assert has_element?(view, "#plugin-path", "canopy.js")
  end

  test "the conversation brake can be tuned or turned off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#chatter-form input[name='setting[chatter_pause]'][checked]")
    assert has_element?(view, "#chatter-form input[name='setting[chatter_limit]'][value='6']")

    view
    |> form("#chatter-form", setting: %{chatter_pause: "true", chatter_limit: "12"})
    |> render_submit()

    assert Canopy.Settings.chatter_limit() == 12
    assert render(view) =~ "pause after 12 agent turns"

    view
    |> form("#chatter-form", setting: %{chatter_pause: "false", chatter_limit: "12"})
    |> render_submit()

    assert Canopy.Settings.chatter_limit() == nil
    assert render(view) =~ "Pausing is off"

    view
    |> form("#chatter-form", setting: %{chatter_pause: "true", chatter_limit: "0"})
    |> render_submit()

    assert has_element?(view, "#chatter-form", "must be greater than or equal to 1")
    assert Canopy.Settings.chatter_limit() == nil
  end
end
