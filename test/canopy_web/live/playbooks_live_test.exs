defmodule CanopyWeb.PlaybooksLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Fixtures, Playbooks}
  alias Canopy.Playbooks.Runs

  setup :set_mox_global

  test "the library starts empty and links to the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbooks-empty")
    assert has_element?(view, "#new-playbook[href='/playbooks/new']")
    assert has_element?(view, "#rail-playbooks")
  end

  test "each playbook can be exported as its file", %{conn: conn} do
    {:ok, playbook} = Playbooks.create(%{body: Playbooks.bug_fix_text()})
    {:ok, view, _html} = live(conn, ~p"/playbooks")

    assert has_element?(
             view,
             "#export-playbook-#{playbook.id}[href='/playbooks/#{playbook.id}/export']"
           )

    # Start and Edit are labelled; the rest sit in the ⋯ menu, labelled, delete last
    assert has_element?(view, "#edit-playbook-#{playbook.id}", "Edit")
    menu = "#playbook-menu-#{playbook.id}"
    assert has_element?(view, "#{menu} #duplicate-playbook-#{playbook.id}", "Duplicate")
    assert has_element?(view, "#{menu} #export-playbook-#{playbook.id}", "Export")
    assert has_element?(view, "#{menu} li:last-child #delete-playbook-#{playbook.id}", "Delete")
  end

  test "create: the text is checked as you type and its steps are previewed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/playbooks/new")
    # the editor starts from a template that parses
    assert has_element?(view, "#playbook-preview-steps #preview-step-plan")

    view
    |> form("#playbook-form", playbook: %{body: "---\nname: Bug_Fix\n---\n"})
    |> render_change()

    assert has_element?(view, "#playbook-errors", "description is missing")
    assert has_element?(view, "#playbook-errors", "kebab-case")
    assert has_element?(view, "#playbook-preview-none")

    body =
      playbook_text("release-notes", [{"draft", "Draft", "coordinator"}], "") <>
        "\n## extra\n\nx\n"

    view |> form("#playbook-form", playbook: %{body: body}) |> render_change()
    refute has_element?(view, "#playbook-errors")
    assert has_element?(view, "#preview-step-draft", "Draft")
    assert has_element?(view, "#playbook-warnings", "matches no step id")

    view |> form("#playbook-form", playbook: %{body: body}) |> render_submit()
    assert_redirect(view, ~p"/playbooks")

    playbook = Playbooks.get_by_name("release-notes")
    assert playbook.source == "user"
    assert playbook.enabled
  end

  test "edit, disable and enable, duplicate, and delete", %{conn: conn} do
    playbook = playbook_fixture("weekly", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-#{playbook.id}[data-enabled='true']", "weekly")
    assert has_element?(view, "#start-playbook-#{playbook.id}")

    view |> element("#toggle-playbook-#{playbook.id}") |> render_click()
    assert has_element?(view, "#playbook-#{playbook.id}[data-enabled='false']")
    refute has_element?(view, "#start-playbook-#{playbook.id}")
    refute Playbooks.get!(playbook.id).enabled
    view |> element("#toggle-playbook-#{playbook.id}") |> render_click()
    assert Playbooks.get!(playbook.id).enabled

    view |> element("#duplicate-playbook-#{playbook.id}") |> render_click()
    copy = Playbooks.get_by_name("weekly-copy")
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")

    {:ok, edit, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    new_body = String.replace(playbook.body, "title: A", "title: Again")
    edit |> form("#playbook-form", playbook: %{body: new_body}) |> render_submit()
    assert_redirect(edit, ~p"/playbooks")
    assert Playbooks.get!(playbook.id).body =~ "title: Again"

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    view |> element("#delete-playbook-#{copy.id}") |> render_click()
    refute has_element?(view, "#playbook-#{copy.id}")
  end

  test "delete is refused while a run is in progress", %{conn: conn} do
    ctx = Fixtures.scenario()
    # after the repository fixture's own on_exit, so channel servers stop first
    on_exit(&stop_channels/0)
    playbook = playbook_fixture("busy", [{"a", "A", "coordinator"}])

    {:ok, _run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-runs-#{playbook.id}", "1 running")
    html = view |> element("#delete-playbook-#{playbook.id}") |> render_click()
    assert html =~ "has a run in progress"
    assert Playbooks.get(playbook.id)
  end

  # 12
  test "enabling a draft the agent replaced after the page loaded is refused", %{conn: conn} do
    agent = Fixtures.agent_fixture(name: "swapper")
    {:ok, draft} = Playbooks.save_draft(agent, playbook_text("swap", [{"a", "A", "coordinator"}]))
    {:ok, view, _html} = live(conn, ~p"/playbooks")

    {:ok, _} =
      Playbooks.save_draft(agent, playbook_text("swap", [{"b", "Something else", "coordinator"}]))

    # a click still carrying the version the page showed before the change
    html =
      render_click(view, "toggle", %{"id" => draft.id, "version" => to_string(draft.lock_version)})

    assert html =~ "changed since the page loaded"
    refute Playbooks.get!(draft.id).enabled

    # from the fresh page it can be enabled
    view |> element("#toggle-playbook-#{draft.id}") |> render_click()
    assert Playbooks.get!(draft.id).enabled
  end

  test "an agent's draft is labelled and starts disabled", %{conn: conn} do
    agent = Fixtures.agent_fixture(name: "drafter")

    {:ok, draft} =
      Playbooks.save_draft(agent, playbook_text("agent-made", [{"a", "A", "coordinator"}]))

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-#{draft.id}[data-enabled='false']", "draft by @drafter")
  end

  test "start: pick a channel and a coordinator; the run starts and the channel opens", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    playbook = playbook_fixture("kickoff", [{"a", "A", "coordinator"}], "inputs: The goal.\n")

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    assert has_element?(view, "#start-brief[placeholder='The goal.']")

    view
    |> form("#start-playbook-form",
      start: %{
        playbook_id: playbook.id,
        channel_id: ctx.channel.id,
        coordinator_id: ctx.agent.id,
        brief: "Ship the onboarding"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/channels/#{ctx.channel.id}")
    run = Runs.active_for_channel(ctx.channel.id)
    assert run.brief == "Ship the onboarding"
    assert run.coordinator_agent_id == ctx.agent.id
    assert run.started_by_agent_id == nil
    # the coordinator is woken with the brief and the first step
    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "The user started it here."
    assert prompt_text(body) =~ "Ship the onboarding"
  end
end
