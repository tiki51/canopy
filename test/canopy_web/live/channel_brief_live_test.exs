defmodule CanopyWeb.ChannelBriefLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Channels, Fixtures, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "reviewer" <> Fixtures.unique_suffix()})
    scenario = Fixtures.scenario(members: [reviewer])

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    Map.merge(scenario, %{reviewer: reviewer})
  end

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  defp details(view), do: view |> element("#toggle-details") |> render_click()

  test "Details › Task's Brief Add opens the editor; the counter follows the text; Save pins it",
       %{conn: conn} = ctx do
    {:ok, view, _html} = open(conn, ctx.channel)
    # a window from lg up, where Details sits beside the editor (below lg it closes for it)
    view
    |> element("#channel-details-pref")
    |> render_hook("pref", %{"key" => "channel-details", "value" => "", "media" => true})

    details(view)

    refute has_element?(view, "#channel-brief")
    assert has_element?(view, "#details-brief", "none")
    refute has_element?(view, "#brief-form")

    view |> element("#edit-brief", "Add") |> render_click()
    assert has_element?(view, "#brief-form")
    # the composer's focus ring
    assert has_element?(view, "#brief-form textarea.focus\\:ring-primary\\/40")
    assert has_element?(view, "#brief-chars", "0 / 4,000 chars")
    # two members (the owner and the reviewer) each get it
    assert has_element?(view, "#brief-tokens", "≈ 0 tokens × 2 agents")
    refute has_element?(view, "#clear-brief")

    view
    |> form("#brief-form", brief: %{brief: "Goal: stop double charges at checkout."})
    |> render_change()

    assert has_element?(view, "#brief-chars", "38 / 4,000 chars")
    assert has_element?(view, "#brief-tokens", "≈ 10 tokens × 2 agents")
    refute has_element?(view, "#brief-long")

    view
    |> form("#brief-form", brief: %{brief: String.duplicate("x", 2_500)})
    |> render_change()

    assert has_element?(view, "#brief-long")

    view
    |> form("#brief-form", brief: %{brief: "Goal: stop double charges at checkout."})
    |> render_submit()

    refute has_element?(view, "#brief-form")
    assert has_element?(view, "#channel-brief")
    assert has_element?(view, "#brief-summary", "Goal: stop double charges at checkout.")
    assert has_element?(view, "#details-brief", "set by #{Canopy.Users.local().display_name}")
    assert has_element?(view, "#edit-brief", "Edit")
    assert Channels.get!(ctx.channel.id).brief == "Goal: stop double charges at checkout."

    [event] = Channels.brief_history(ctx.channel.id)
    assert has_element?(view, "#line-#{event.id}", "updated the channel brief")
    assert has_element?(view, "#brief-change-#{event.id}")
  end

  test "over the limit shows an error and saves nothing", %{conn: conn} = ctx do
    {:ok, view, _html} = open(conn, ctx.channel)
    details(view)
    view |> element("#edit-brief") |> render_click()

    too_long = String.duplicate("x", 4_001)
    view |> form("#brief-form", brief: %{brief: too_long}) |> render_change()
    assert has_element?(view, "#brief-chars.text-error", "4,001 / 4,000 chars")

    view |> form("#brief-form", brief: %{brief: too_long}) |> render_submit()
    assert has_element?(view, "#brief-form")
    assert render(view) =~ "should be at most 4000 character"
    assert Channels.get!(ctx.channel.id).brief == nil
    assert Channels.brief_history(ctx.channel.id) == []
  end

  test "the strip expands to the rendered brief and the choice is remembered",
       %{conn: conn} = ctx do
    {:ok, _} = Channels.set_brief(ctx.channel, "Goal: **no** double charges.\n- one", "user")
    {:ok, view, _html} = open(conn, ctx.channel)

    assert has_element?(view, "#channel-brief[data-expanded=false]")
    refute has_element?(view, "#brief-body")

    view |> element("#brief-toggle") |> render_click()
    assert has_element?(view, "#brief-body strong", "no")
    assert has_element?(view, "#brief-cost", "in every prompt of 2 agents")
    assert_push_event(view, "pref", %{key: "channel-brief", value: "expanded"})

    view |> element("#brief-toggle") |> render_click()
    refute has_element?(view, "#brief-body")
    assert_push_event(view, "pref", %{key: "channel-brief", value: "collapsed"})

    # a browser that remembered "expanded" opens it on mount
    {:ok, view, _html} = open(conn, ctx.channel)

    view
    |> element("#channel-brief-pref")
    |> render_hook("pref", %{"key" => "channel-brief", "value" => "expanded"})

    assert has_element?(view, "#brief-body")
  end

  test "History lists versions; View shows one and Restore brings it back", %{conn: conn} = ctx do
    {:ok, _} = Channels.set_brief(ctx.channel, "First version.", "user")
    {:ok, _} = Channels.set_brief(ctx.channel, "Second version.", ctx.agent.id)
    [newest, oldest] = Channels.brief_history(ctx.channel.id)

    {:ok, view, _html} = open(conn, ctx.channel)
    view |> element("#brief-toggle") |> render_click()
    view |> element("#brief-history-toggle") |> render_click()

    assert has_element?(view, "#brief-history-#{newest.id}", "@#{ctx.agent.name}")
    assert has_element?(view, "#brief-history-#{newest.id}", "current")
    refute has_element?(view, "#brief-restore-#{newest.id}")
    assert has_element?(view, "#brief-history-#{oldest.id}", "First version.")

    view |> element("#brief-version-#{oldest.id}") |> render_click()
    assert has_element?(view, "#brief-version-body-#{oldest.id}", "First version.")

    view |> element("#brief-restore-#{oldest.id}") |> render_click()
    assert Channels.get!(ctx.channel.id).brief == "First version."

    # the restore is a new version of its own, so it can be undone too
    assert [
             %{payload: %{"body" => "First version.", "previous" => "Second version."}} = restored
             | _
           ] =
             Channels.brief_history(ctx.channel.id)

    assert has_element?(view, "#brief-history-#{restored.id}", "current")
  end

  test "an agent's edit refreshes an open view; while editing, it says so", %{conn: conn} = ctx do
    {:ok, view, _html} = open(conn, ctx.channel)

    {:ok, _} = Channels.set_brief(ctx.channel, "Set by the owner.", ctx.agent.id)
    assert has_element?(view, "#brief-summary", "Set by the owner.")

    view |> element("#brief-edit") |> render_click()
    view |> form("#brief-form", brief: %{brief: "My draft."}) |> render_change()

    {:ok, _} = Channels.set_brief(ctx.channel, "Changed again.", ctx.agent.id)
    assert has_element?(view, "#brief-conflict", "@#{ctx.agent.name} changed the brief")
    # the draft is kept; saving still wins
    assert has_element?(view, "#brief-form textarea", "My draft.")

    view |> form("#brief-form", brief: %{brief: "My draft."}) |> render_submit()
    assert Channels.get!(ctx.channel.id).brief == "My draft."
    refute has_element?(view, "#brief-conflict")
  end

  test "Clear removes the brief and the strip", %{conn: conn} = ctx do
    {:ok, _} = Channels.set_brief(ctx.channel, "Temporary.", "user")
    {:ok, view, _html} = open(conn, ctx.channel)

    view |> element("#brief-edit") |> render_click()
    view |> element("#clear-brief") |> render_click()

    refute has_element?(view, "#channel-brief")
    details(view)
    assert has_element?(view, "#details-brief", "none")
    assert Channels.get!(ctx.channel.id).brief == nil
    assert render(view) =~ "cleared the channel brief"
  end

  test "a DM has the brief too", %{conn: conn} = ctx do
    {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
    on_exit(fn -> Runtime.stop_channel(dm.id) end)
    {:ok, view, _html} = open(conn, dm)
    details(view)

    view |> element("#edit-brief") |> render_click()
    view |> form("#brief-form", brief: %{brief: "Long-running DM context."}) |> render_submit()
    assert Channels.get!(dm.id).brief == "Long-running DM context."
    assert has_element?(view, "#channel-brief")
  end

  test "the strip's summary is the first line as plain text" do
    line = &CanopyWeb.ChannelLive.brief_first_line/1

    assert line.("\n## **Spec:** see [the plan](https://x.test/p) and `NOTES.md`") ==
             "Spec: see the plan and NOTES.md"

    assert line.("> - 1. _Goal_: ship *it*, @frontend in #toolbar") ==
             "Goal: ship it, @frontend in #toolbar"

    assert line.("---\nkeep snake_case_names") == "keep snake_case_names"
  end
end
