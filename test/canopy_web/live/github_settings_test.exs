defmodule CanopyWeb.GitHubSettingsTest do
  @moduledoc "The GitHub panel on the Settings page: the gh binary watches use, and its check."
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.Settings
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(OC, :providers, fn _opts -> {:ok, %{"providers" => [], "default" => %{}}} end)
    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
    :ok
  end

  test "saves the gh binary and checks its version and login", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#gh-panel")

    view |> form("#gh-form", setting: %{gh_binary: "/opt/homebrew/bin/gh"}) |> render_submit()
    assert Settings.get().gh_binary == "/opt/homebrew/bin/gh"

    expect(Canopy.GitHub.Mock, :status, fn ->
      {:ok, %{version: "2.5.2", too_old?: false, logged_in?: true, account: "octocat"}}
    end)

    view |> element("#check-gh") |> render_click()
    assert render_async(view) =~ "gh 2.5.2"
    assert has_element?(view, "#gh-check-result", "logged in as octocat")

    expect(Canopy.GitHub.Mock, :status, fn ->
      {:ok, %{version: "1.14.0", too_old?: true, logged_in?: false, account: nil}}
    end)

    view |> element("#check-gh") |> render_click()
    render_async(view)
    assert has_element?(view, "#gh-check-result", "too old")
    assert has_element?(view, "#gh-check-result", "not logged in: run gh auth login")

    expect(Canopy.GitHub.Mock, :status, fn -> {:error, "gh is not installed (no `gh` found)"} end)
    view |> element("#check-gh") |> render_click()
    render_async(view)
    assert has_element?(view, "#gh-check-result", "gh is not installed")
  end
end
