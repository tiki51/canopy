defmodule CanopyWeb.TeamsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Teams}

  setup do
    backend = Fixtures.agent_fixture(%{name: "backend", group: "Engineering"})
    frontend = Fixtures.agent_fixture(%{name: "frontend", group: "Engineering"})
    tester = Fixtures.agent_fixture(%{name: "tester", group: "Review"})
    %{backend: backend, frontend: frontend, tester: tester}
  end

  test "the list starts empty and links to the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/teams")
    assert has_element?(view, "#teams-empty")
    assert has_element?(view, "#new-team[href='/teams/new']")
    assert has_element?(view, "#back-to-agents[href='/agents']")
  end

  test "creates a team; the lead select follows the chosen members", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/teams/new")
    assert has_element?(view, "#team-lead option", "Pick members first")

    view
    |> form("#team-form", team: %{name: "qa-team", agent_ids: [ctx.frontend.id, ctx.tester.id]})
    |> render_change()

    # the first member becomes the lead; only members are offered
    assert has_element?(view, "#team-lead option[selected][value='#{ctx.frontend.id}']")
    assert has_element?(view, "#team-lead option[value='#{ctx.tester.id}']")
    refute has_element?(view, "#team-lead option[value='#{ctx.backend.id}']")

    # on a new team the lead follows the members
    view
    |> form("#team-form", team: %{agent_ids: [ctx.tester.id]})
    |> render_change()

    assert has_element?(view, "#team-lead option[selected][value='#{ctx.tester.id}']")

    view
    |> form("#team-form", team: %{agent_ids: [ctx.frontend.id, ctx.tester.id]})
    |> render_change()

    view
    |> form("#team-form",
      team: %{
        name: "qa-team",
        description: "Checks things",
        agent_ids: [ctx.frontend.id, ctx.tester.id],
        lead_agent_id: ctx.tester.id
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/teams")
    team = Teams.get_by_name("qa-team")
    assert team.lead_agent_id == ctx.tester.id
    assert team.description == "Checks things"

    {:ok, view, _html} = live(ctx.conn, ~p"/teams")
    assert has_element?(view, "#team-#{team.id}", "@qa-team")
    assert has_element?(view, "#team-#{team.id}", "Checks things")
    assert has_element?(view, "#team-#{team.id}", "lead")

    assert has_element?(
             view,
             "#new-channel-team-#{team.id}[href='/channels/new?team=#{team.id}']"
           )
  end

  test "rejects an agent's name and an empty team", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/teams/new")

    html =
      view
      |> form("#team-form", team: %{name: "backend", agent_ids: [ctx.backend.id]})
      |> render_submit()

    assert html =~ "is already an agent&#39;s name"

    html = view |> form("#team-form", team: %{name: "nobody", agent_ids: [""]}) |> render_submit()
    assert html =~ "pick at least one member"
    assert Teams.list() == []
  end

  test "editing: removing the lead asks for a new lead first", ctx do
    team = Fixtures.team_fixture([ctx.backend, ctx.frontend], name: "crew")
    {:ok, view, _html} = live(ctx.conn, ~p"/teams/#{team.id}/edit")

    assert has_element?(view, "#team-member-#{ctx.backend.id}[checked]")

    html =
      view
      |> form("#team-form", team: %{agent_ids: [ctx.frontend.id]})
      |> render_change()

    assert html =~ "choose a new lead before removing the current one"

    assert has_element?(
             view,
             "#team-lead option[selected][value='#{ctx.backend.id}']",
             "no longer a member"
           )

    view
    |> form("#team-form", team: %{agent_ids: [ctx.frontend.id], lead_agent_id: ctx.frontend.id})
    |> render_submit()

    assert_redirect(view, ~p"/teams")
    team = Teams.get!(team.id)
    assert team.lead_agent_id == ctx.frontend.id
    assert Enum.map(team.members, & &1.id) == [ctx.frontend.id]
  end

  test "delete asks first, then removes the team", ctx do
    team = Fixtures.team_fixture([ctx.backend], name: "solo")
    {:ok, view, _html} = live(ctx.conn, ~p"/teams")

    assert has_element?(view, "#delete-team-#{team.id}[data-canopy-confirm]")
    view |> element("#delete-team-#{team.id}") |> render_click()
    refute has_element?(view, "#team-#{team.id}")
    assert Teams.get(team.id) == nil
  end
end
