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

  describe "collaboration prompt" do
    alias Canopy.Runtime.Prompts

    defp agent, do: %{name: "x", display_name: "X", role: "r", system_prompt: nil}

    defp rendered_system,
      do: Prompts.system(agent(), %{name: "c"}, %{id: "r", path: "/r"})

    test "the panel starts from the prompt Canopy ships", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#prompt-panel")
      refute has_element?(view, "#prompt-customised")
      refute has_element?(view, "#reset-prompt")

      html = render(view)
      assert html =~ "canopy_message_send"
      assert html =~ "{{display_name}}"
    end

    test "a custom prompt reaches the agents, with variables still filled in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#prompt-form",
        setting: %{
          collaboration_prompt: "You are {{display_name}} in channel {{channel}}. Be terse."
        }
      )
      |> render_submit()

      assert Settings.get().collaboration_prompt =~ "Be terse."

      text = rendered_system()
      assert text =~ "You are X in channel c. Be terse."
      refute text =~ "canopy_message_send"
      refute text =~ "{{"

      assert has_element?(view, "#prompt-customised")
    end

    test "saving the shipped text unchanged keeps the default in force", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#prompt-form", setting: %{collaboration_prompt: Prompts.default_preamble()})
      |> render_submit()

      assert Settings.get().collaboration_prompt == nil
      refute has_element?(view, "#prompt-customised")
    end

    test "reset puts the shipped prompt back", %{conn: conn} do
      {:ok, _} = Settings.update(%{"collaboration_prompt" => "Only this."})
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#prompt-customised")
      assert rendered_system() =~ "Only this."

      view |> element("#reset-prompt") |> render_click()

      assert Settings.get().collaboration_prompt == nil
      refute has_element?(view, "#prompt-customised")
      assert rendered_system() =~ "canopy_message_send"
    end

    test "an over-long prompt is rejected instead of saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#prompt-form", setting: %{collaboration_prompt: String.duplicate("x", 20_001)})
        |> render_submit()

      assert html =~ "should be at most 20000 character(s)"
      assert Settings.get().collaboration_prompt == nil
    end
  end

  test "the conversation brake can be tuned or turned off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#chatter-form input[name='setting[chatter_pause]'][checked]")
    assert has_element?(view, "#chatter-form input[name='setting[chatter_limit]'][value='6']")

    assert has_element?(view, "#chatter-form input[name='setting[serialize_turns]'][checked]")

    view
    |> form("#chatter-form",
      setting: %{chatter_pause: "true", chatter_limit: "12", serialize_turns: "false"}
    )
    |> render_submit()

    refute Canopy.Settings.serialize_turns?()

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
