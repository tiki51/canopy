defmodule CanopyWeb.AgentGalleryLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.Agents
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  setup do
    # OpenCode is away; Claude Code (the fake binary) is installed
    stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    stub(OC, :agents, fn _dir, _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    :ok
  end

  test "lists the starter agents and bundles by group", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/gallery")

    assert has_element?(
             view,
             "#gallery-group-review-research #gallery-security-reviewer",
             "Security Reviewer"
           )

    assert has_element?(view, "#gallery-security-reviewer", "read-only")
    assert has_element?(view, "#gallery-release-manager", "edits")
    assert has_element?(view, "#gallery-bundle-bug-fix", "Bug-fix team and playbook")
  end

  test "Add goes through the preview, then the card says Added", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents/gallery")

    {:ok, view, _html} =
      view
      |> element("#gallery-add-security-reviewer")
      |> render_click()
      |> follow_redirect(conn, ~p"/agents/import?gallery=security-reviewer")

    assert has_element?(view, "#import-item-1[data-status=new]", "@security-reviewer")
    view |> form("#import-choices") |> render_submit()
    {path, flash} = assert_redirect(view)
    assert path == ~p"/agents/gallery"
    assert flash["info"] == "Imported @security-reviewer."

    agent = Agents.get_by_name("security-reviewer")
    # engine-neutral: OpenCode is away in this test but Claude Code is
    # installed, so the agent goes there, read-only as its mode says
    assert %{engine: "claude_code", permission_mode: "plan", model_id: nil} = agent

    {:ok, view, _html} = live(conn, ~p"/agents/gallery")
    assert has_element?(view, "#gallery-added-security-reviewer")
    refute has_element?(view, "#gallery-add-security-reviewer")
  end

  test "an agent that was changed Differs; Compare opens the preview in replace mode", %{
    conn: conn
  } do
    Fixtures.agent_fixture(%{name: "release-manager", role: "My own take"})
    {:ok, view, _html} = live(conn, ~p"/agents/gallery")
    assert has_element?(view, "#gallery-release-manager[data-status=differs]")

    {:ok, view, _html} =
      view
      |> element("#gallery-compare-release-manager")
      |> render_click()
      |> follow_redirect(conn, ~p"/agents/import?gallery=release-manager&replace=1")

    assert has_element?(view, "#import-item-1[data-status=conflict][data-action=replace]")
    assert has_element?(view, "#import-item-1-changes", "role")
  end
end
