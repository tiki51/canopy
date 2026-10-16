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

    # the row names it and offers Start; the rest sit in the ⋯ menu, Edit first, delete last
    assert has_element?(view, "#expand-playbook-#{playbook.id}", "Bug fix")
    assert has_element?(view, "#start-playbook-#{playbook.id}", "Start")

    assert has_element?(
             view,
             "#playbook-menu-#{playbook.id} li:first-child #edit-playbook-#{playbook.id}[href='/playbooks/#{playbook.id}/edit']",
             "Edit"
           )

    # the steps as a strip, once the row is open: send-back and sign-off marked
    refute has_element?(view, "#playbook-strip-#{playbook.id}")
    view |> element("#expand-playbook-#{playbook.id}") |> render_click()
    assert has_element?(view, "#playbook-strip-#{playbook.id} li", "Review")
    assert has_element?(view, "#playbook-strip-#{playbook.id} [title='waits for you']")

    assert has_element?(
             view,
             "#playbook-strip-#{playbook.id} li:last-child [title='can send work back to fix']"
           )

    menu = "#playbook-menu-#{playbook.id}"
    assert has_element?(view, "#{menu} #duplicate-playbook-#{playbook.id}", "Duplicate")
    assert has_element?(view, "#{menu} #export-playbook-#{playbook.id}", "Export")
    assert has_element?(view, "#{menu} li:last-child #delete-playbook-#{playbook.id}", "Delete")
  end

  test "the feature-build starter's card ends in User sign-off, marked send-back and waits for you",
       %{conn: conn} do
    {:ok, playbook} = Playbooks.create(%{body: Playbooks.feature_build_text()})
    {:ok, view, html} = live(conn, ~p"/playbooks")
    view |> element("#expand-playbook-#{playbook.id}") |> render_click()
    last = "#playbook-strip-#{playbook.id} li:last-child"

    assert has_element?(view, last, "User sign-off")
    assert has_element?(view, "#{last} [title='can send work back to build']")
    assert has_element?(view, "#{last} [title='waits for you']")
    assert html =~ "ending in user sign-off"
    refute html =~ "Tell the user it"
  end

  test "new: copy a playbook, start blank, or describe it to an agent", %{conn: conn} do
    {:ok, playbook} = Playbooks.create(%{body: Playbooks.bug_fix_text()})
    other = playbook_fixture("weekly", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/new")

    assert has_element?(view, "#start-blank[href='/playbooks/new/blank']")
    assert has_element?(view, "#new-describe #describe-text")
    # the first playbook is picked to copy; another can be
    assert has_element?(view, "#copy-playbook", "Copy Bug fix")
    view |> element("#new-playbook-form") |> render_change(%{"copy_id" => other.id})
    assert has_element?(view, "#copy-playbook", "Copy Weekly")

    view |> element("#copy-playbook") |> render_click()
    copy = Playbooks.get_by_name("weekly-copy")
    refute copy.enabled
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")
    assert playbook
  end

  test "new: the copy list puts starred playbooks first and preselects the first row", %{
    conn: conn
  } do
    names = ~w(alpha bravo charlie delta echo foxtrot)
    [alpha | _] = playbooks = Enum.map(names, &playbook_fixture(&1, [{"a", "A", "coordinator"}]))
    echo = Enum.at(playbooks, 4)
    delta = Enum.at(playbooks, 3)
    {:ok, _} = Playbooks.set_starred(echo, true)
    # a starred playbook that is now a draft gets no star and no place up front
    {:ok, _} = Playbooks.set_starred(delta, true)
    {:ok, _} = Playbooks.set_enabled(Playbooks.get!(delta.id), false, nil)

    {:ok, view, _html} = live(conn, ~p"/playbooks/new")
    assert has_element?(view, "#copy-list > li:first-child[id='copy-row-#{echo.id}']")
    assert has_element?(view, "#copy-row-#{echo.id} input[checked]")
    assert has_element?(view, "#copy-row-#{echo.id} .hero-star-solid")
    refute has_element?(view, "#copy-row-#{delta.id} .hero-star-solid")
    assert has_element?(view, "#copy-list > li:nth-child(2)[id='copy-row-#{alpha.id}']")
    assert has_element?(view, "#copy-playbook.btn-primary", "Copy Echo")
    # only the picked row shows its chain of steps
    assert has_element?(view, "#copy-row-#{echo.id} p", "A")
    refute has_element?(view, "#copy-row-#{alpha.id} p")

    # the filter narrows the list
    view |> element("#new-playbook-form") |> render_change(%{"copy_q" => "CHAR"})
    assert has_element?(view, "#copy-list li", "Charlie")
    refute has_element?(view, "#copy-row-#{alpha.id}")
    view |> element("#new-playbook-form") |> render_change(%{"copy_q" => "xyz"})
    assert has_element?(view, "#copy-no-match", ~s(No playbooks match "xyz"))
    # Enter in the filter is a no-op on the server, never a page load
    assert view |> element("#new-playbook-form") |> render_submit(%{"copy_q" => "xyz"})
  end

  test "new: a filter that hides the picked row keeps the pick", %{conn: conn} do
    names = ~w(alpha bravo charlie delta echo foxtrot)
    [_, bravo | _] = Enum.map(names, &playbook_fixture(&1, [{"a", "A", "coordinator"}]))

    {:ok, view, _html} = live(conn, ~p"/playbooks/new")
    view |> element("#new-playbook-form") |> render_change(%{"copy_id" => bravo.id})
    assert has_element?(view, "#copy-row-#{bravo.id} input[checked]")

    view |> element("#new-playbook-form") |> render_change(%{"copy_q" => "char"})
    refute has_element?(view, "#copy-row-#{bravo.id}")
    refute has_element?(view, "#copy-list input[checked]")
    assert has_element?(view, "#copy-playbook.btn-primary", "Copy Bravo")

    view |> element("#new-playbook-form") |> render_change(%{"copy_q" => "zzz"})
    assert has_element?(view, "#copy-no-match")
    assert has_element?(view, "#copy-playbook.btn-primary", "Copy Bravo")

    view |> element("#new-playbook-form") |> render_change(%{"copy_q" => ""})
    assert has_element?(view, "#copy-row-#{bravo.id} input[checked]")

    view |> element("#new-playbook-form") |> render_change(%{"copy_q" => "char"})
    view |> element("#copy-playbook") |> render_click()
    copy = Playbooks.get_by_name("bravo-copy")
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")
  end

  test "new: no copy filter for five playbooks or fewer", %{conn: conn} do
    for n <- ~w(one two three four five), do: playbook_fixture(n, [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/new")
    refute has_element?(view, "#copy-filter")
    assert has_element?(view, "#copy-list li", "Five")
    # the first row as shown is preselected (alphabetical with nothing starred)
    assert has_element?(view, "#copy-playbook", "Copy Five")
  end

  test "new: describing a playbook asks the agent in a DM to draft it", %{conn: conn} do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    {:ok, view, _html} = live(conn, ~p"/playbooks/new")

    view
    |> element("#new-playbook-form")
    |> render_change(%{
      "describe" => "Collect merged PRs into release notes",
      "drafter" => ctx.agent.name
    })

    view |> element("#describe-playbook") |> render_click()
    {path, flash} = assert_redirect(view)
    assert flash["info"] =~ "Asked @#{ctx.agent.name} to draft it"
    "/channels/" <> channel_id = path
    [message] = Canopy.Messages.list(channel_id) |> Enum.filter(&is_nil(&1.agent_id))
    assert message.body =~ "Collect merged PRs into release notes"
    assert message.body =~ "canopy_playbook_save"
    # the agent is woken in the DM
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "edit, disable and enable, duplicate, and delete", %{conn: conn} do
    playbook = playbook_fixture("weekly", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbooks-other #playbook-#{playbook.id}[data-enabled='true']")
    assert has_element?(view, "#playbook-#{playbook.id}[data-playbook='weekly']")
    assert has_element?(view, "#start-playbook-#{playbook.id}")
    refute has_element?(view, "#toggle-drafts")

    # disabled, it moves into Drafts, which is closed until opened
    view |> element("#toggle-playbook-#{playbook.id}", "Disable") |> render_click()
    refute Playbooks.get!(playbook.id).enabled
    refute has_element?(view, "#playbook-#{playbook.id}")
    assert has_element?(view, "#toggle-drafts[aria-expanded='false']", "1")
    view |> element("#toggle-drafts") |> render_click()
    assert has_element?(view, "#playbooks-drafts #playbook-#{playbook.id}[data-enabled='false']")
    refute has_element?(view, "#start-playbook-#{playbook.id}")
    assert has_element?(view, "#review-playbook-#{playbook.id}", "Edit")

    # an old ?show=drafts link opens Drafts
    {:ok, drafts, _html} = live(conn, ~p"/playbooks?show=drafts")
    assert has_element?(drafts, "#playbooks-drafts #playbook-#{playbook.id}")

    view |> element("#toggle-playbook-#{playbook.id}", "Enable") |> render_click()
    assert Playbooks.get!(playbook.id).enabled
    assert has_element?(view, "#playbooks-other #playbook-#{playbook.id}")

    view |> element("#duplicate-playbook-#{playbook.id}") |> render_click()
    copy = Playbooks.get_by_name("weekly-copy")
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")

    # the copy is a draft
    {:ok, view, _html} = live(conn, ~p"/playbooks?show=drafts")
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

  test "a row opens in place to show its steps; one open at a time", %{conn: conn} do
    {:ok, bug} = Playbooks.create(%{body: Playbooks.bug_fix_text()})
    other = playbook_fixture("weekly", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")

    refute has_element?(view, "#playbook-#{bug.id}[data-card]")
    assert has_element?(view, "#expand-playbook-#{bug.id}[aria-expanded='false']")

    view |> element("#expand-playbook-#{bug.id}") |> render_click()
    assert has_element?(view, "#expand-playbook-#{bug.id}[aria-expanded='true']")
    assert has_element?(view, "#playbook-detail-#{bug.id}", "Edit playbook")
    assert has_element?(view, "#start-playbook-#{bug.id}.btn-primary")

    # another row moves the open one; a second click closes it
    view |> element("#expand-playbook-#{other.id}") |> render_click()
    refute has_element?(view, "#playbook-strip-#{bug.id}")
    assert has_element?(view, "#playbook-strip-#{other.id}")
    view |> element("#expand-playbook-#{other.id}") |> render_click()
    refute has_element?(view, "#playbook-detail-#{other.id}")
  end

  test "an agent's draft is flagged for review, with Drafts open", %{conn: conn} do
    agent = Fixtures.agent_fixture(name: "drafter")

    {:ok, draft} =
      Playbooks.save_draft(agent, playbook_text("agent-made", [{"a", "A", "coordinator"}]))

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    row = "#playbooks-drafts #playbook-#{draft.id}[data-enabled='false']"
    assert has_element?(view, row, "by @drafter")
    assert has_element?(view, "#{row} #review-playbook-#{draft.id}", "Review")
    # drafts can't be starred
    refute has_element?(view, "#star-playbook-#{draft.id}")

    assert has_element?(view, "#playbook-draft-notice", "@drafter drafted")
    assert has_element?(view, "#playbook-draft-notice", "Agent made")

    assert has_element?(
             view,
             "#playbook-draft-notice a[href='/playbooks/#{draft.id}/edit']",
             "Review"
           )

    {:ok, _} =
      Playbooks.save_draft(agent, playbook_text("agent-two", [{"a", "A", "coordinator"}]))

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-draft-notice", "2 drafts from agents to review")
    view |> element("#toggle-drafts") |> render_click()
    refute has_element?(view, "#playbooks-drafts")
    view |> element("#playbook-draft-notice button", "Review") |> render_click()
    assert has_element?(view, "#playbooks-drafts")

    # a filter hiding every draft is cleared, so Review always shows them
    view |> element("#playbook-filter") |> render_change(%{"q" => "nothing like it"})
    refute has_element?(view, "#playbooks-drafts")
    view |> element("#playbook-draft-notice button", "Review") |> render_click()
    assert has_element?(view, "#playbooks-drafts li[data-playbook='agent-made']")
  end

  test "rows show who does the steps: five fit, past that four and the rest counted", %{
    conn: conn
  } do
    names = for n <- 1..6, do: Fixtures.agent_fixture(name: "owner#{n}").name

    roles = Enum.map_join(Enum.with_index(names, 1), "\n", fn {n, i} -> "  r#{i}: #{n}\n" end)

    playbook =
      playbook_fixture(
        "crowded",
        for(i <- 1..6, do: {"s#{i}", "S#{i}", "r#{i}"}) ++ [{"s7", "S7", "r1"}],
        "roles:\n" <> roles
      )

    {:ok, view, html} = live(conn, ~p"/playbooks")
    row = "#playbook-#{playbook.id}"
    assert has_element?(view, row, "+2")
    # four avatars and the "+2", so the count never runs into "7 steps"
    assert has_element?(view, "#{row} span[title] > :nth-child(5)", "+2")
    refute has_element?(view, "#{row} span[title] > :nth-child(6)")
    assert html =~ Enum.map_join(names, ", ", &("@" <> &1))
    assert has_element?(view, row, "7 steps")
  end

  test "star: a playbook moves to Starred and back", %{conn: conn} do
    bug = playbook_fixture("bug", [{"a", "A", "coordinator"}])
    playbook_fixture("weekly", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")

    # nothing starred: one list, "All playbooks", and the hint
    refute has_element?(view, "#playbooks-starred")
    assert has_element?(view, "#playbooks-other-heading", "All playbooks")
    assert has_element?(view, "#playbook-star-hint")

    view |> element("#star-playbook-#{bug.id}") |> render_click()
    assert Playbooks.get!(bug.id).starred_at

    assert has_element?(
             view,
             "#playbooks-starred #playbook-#{bug.id}[data-starred='true'].pb-moved"
           )

    assert has_element?(view, "#star-playbook-#{bug.id}[aria-pressed='true'][title='Unstar']")
    refute has_element?(view, "#playbooks-other #playbook-#{bug.id}")
    assert has_element?(view, "#playbooks-other-heading", "Other playbooks")
    refute has_element?(view, "#playbook-star-hint")

    # the tint goes with the next action
    view |> element("#expand-playbook-#{bug.id}") |> render_click()
    refute has_element?(view, "#playbook-#{bug.id}.pb-moved")

    view |> element("#star-playbook-#{bug.id}") |> render_click()
    refute Playbooks.get!(bug.id).starred_at
    assert has_element?(view, "#playbooks-other #playbook-#{bug.id}[data-starred='false']")
    refute has_element?(view, "#playbooks-starred")

    # disabled from ⋯ right after a star, it lands in Drafts untinted
    view |> element("#star-playbook-#{bug.id}") |> render_click()
    view |> element("#toggle-playbook-#{bug.id}", "Disable") |> render_click()
    view |> element("#toggle-drafts") |> render_click()
    assert has_element?(view, "#playbooks-drafts #playbook-#{bug.id}")
    refute has_element?(view, "#playbook-#{bug.id}.pb-moved")
  end

  test "the count reads one playbook, not one playbooks", %{conn: conn} do
    playbook_fixture("solo", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert render(element(view, "#playbook-count")) =~ ~r/>\s*1 playbook\s*</
  end

  test "star: another tab's star moves the row here too", %{conn: conn} do
    bug = playbook_fixture("bug", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    {:ok, _} = Playbooks.set_starred(bug, true)
    assert has_element?(view, "#playbooks-starred #playbook-#{bug.id}")
  end

  test "star: a starred playbook disabled shows in Drafts without a star", %{conn: conn} do
    bug = playbook_fixture("bug", [{"a", "A", "coordinator"}])
    {:ok, _} = Playbooks.set_starred(bug, true)
    {:ok, _} = Playbooks.set_enabled(Playbooks.get!(bug.id), false, nil)
    {:ok, view, _html} = live(conn, ~p"/playbooks?show=drafts")

    assert has_element?(view, "#playbooks-drafts #playbook-#{bug.id}[data-starred='false']")
    refute has_element?(view, "#star-playbook-#{bug.id}")
    refute has_element?(view, "#playbooks-starred")
  end

  test "star: a playbook disabled or deleted meanwhile is refused in plain words", %{conn: conn} do
    bug = playbook_fixture("bug", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")

    {:ok, _} = Playbooks.set_enabled(Playbooks.get!(bug.id), false, nil)
    html = render_click(view, "star", %{"id" => bug.id})
    assert html =~ "Drafts can&#39;t be starred; enable it first."
    refute Playbooks.get!(bug.id).starred_at
    refute has_element?(view, "#playbooks-other #playbook-#{bug.id}")

    {:ok, _} = Playbooks.delete(Playbooks.get!(bug.id))
    html = render_click(view, "star", %{"id" => bug.id})
    assert html =~ "That playbook no longer exists."
  end

  test "filter: narrows every section, with counts, marks and a way back", %{conn: conn} do
    flaky = playbook_fixture("flaky-test-hunt", [{"a", "A", "coordinator"}])
    bug = playbook_fixture("bug", [{"a", "A", "coordinator"}])
    weekly = playbook_fixture("weekly", [{"a", "A", "coordinator"}])
    {:ok, _} = Playbooks.set_starred(bug, true)
    {:ok, _} = Playbooks.set_enabled(weekly, false, nil)
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-count", "3 playbooks")

    view |> element("#playbook-filter") |> render_change(%{"q" => "TEST"})
    assert has_element?(view, "#playbook-count", "1 of 3 playbooks")
    assert has_element?(view, "#playbooks-other #playbook-#{flaky.id}")
    assert has_element?(view, "#playbooks-other-heading", "1 of 1")
    assert has_element?(view, "#expand-playbook-#{flaky.id} mark", "test")
    refute has_element?(view, "#playbooks-starred")
    refute has_element?(view, "#toggle-drafts")

    # a match among the drafts shows them, even though Drafts was closed
    view |> element("#playbook-filter") |> render_change(%{"q" => "week"})
    assert has_element?(view, "#playbooks-drafts #playbook-#{weekly.id}")
    assert has_element?(view, "#toggle-drafts", "1 of 1")

    view |> element("#playbook-filter") |> render_change(%{"q" => "xyz"})
    assert has_element?(view, "#playbooks-no-match", ~s(No playbooks match "xyz"))
    view |> element("#playbooks-no-match button", "Clear filter") |> render_click()
    refute has_element?(view, "#playbooks-no-match")
    assert has_element?(view, "#playbooks-starred #playbook-#{bug.id}")
    assert has_element?(view, "#playbook-count", "3 playbooks")
  end

  test "start: the brief, where it runs, the lead; the run starts and the channel opens", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    playbook = playbook_fixture("kickoff", [{"a", "A", "coordinator"}], "inputs: The goal.\n")

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    assert has_element?(view, "#start-inputs", "The goal.")
    assert has_element?(view, "#start-preview li", "A")

    view
    |> form("#start-run-form",
      start: %{
        runs_in: "existing",
        coordinator_id: ctx.agent.id,
        brief: "Ship the onboarding"
      }
    )
    |> render_change()

    view
    |> form("#start-run-form",
      start: %{
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

  describe "start: files on the brief" do
    @png File.read!(Path.expand("../../support/files/red.png", __DIR__))

    test "uploads and picks post with the brief as the run's first message", %{conn: conn} do
      ctx = Fixtures.scenario()
      on_exit(&stop_channels/0)
      stub_engine(self(), ctx.repository)
      playbook = playbook_fixture("filed", [{"a", "A", "coordinator"}])
      picked = shared_doc("spec.md")

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      refute has_element?(view, "#start-brief-files")

      upload_files(view, [{"shot.png", @png}])
      assert has_element?(view, "#start-brief-files [id^=start-upload-]", "shot.png")
      assert has_element?(view, "#start-brief-count", "1 of 10 files")

      # the library dialog says where a pick goes
      view |> element("#start-brief-library") |> render_click()
      assert has_element?(view, "#library-dialog", "Pick one to add it to the brief.")
      view |> element("#library-#{picked.id}") |> render_click()
      refute has_element?(view, "#library-picker")
      assert has_element?(view, "#start-picked-#{picked.id}", "spec.md")
      assert has_element?(view, "#start-brief-count", "2 of 10 files")

      view
      |> form("#start-run-form", start: %{runs_in: "existing", brief: "Fix the login"})
      |> render_change()

      assert has_element?(view, "#start-consequence strong", "2 files")

      assert view |> element("#start-consequence") |> render() =~
               "The lead is woken in the channel you pick with <strong>2 files</strong>. " <>
                 "The files post with the brief as the run&#39;s first message."

      view
      |> form("#start-run-form", start: %{runs_in: "new", brief: "Fix the login"})
      |> render_change()

      assert view |> element("#start-consequence") |> render() =~
               ~r"is woken with your brief and <strong>2 files</strong>, and opens #[\w-]+\. The files post"

      view
      |> form("#start-run-form", start: %{runs_in: "existing", brief: "Fix the login"})
      |> render_change()

      view
      |> form("#start-run-form",
        start: %{channel_id: ctx.channel.id, coordinator_id: ctx.agent.id, brief: "Fix the login"}
      )
      |> render_submit()

      assert_redirect(view, ~p"/channels/#{ctx.channel.id}")
      run = Runs.active_for_channel(ctx.channel.id)
      kickoff = Canopy.Messages.get!(run.kickoff_message_id)
      assert kickoff.body == "Fix the login"
      # uploads first, then picks
      assert [%{filename: "shot.png"}, %{id: picked_id}] = kickoff.documents
      assert picked_id == picked.id
    end

    test "with no files the footer is unchanged", %{conn: conn} do
      playbook = playbook_fixture("plain", [{"a", "A", "coordinator"}])
      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      view |> form("#start-run-form", start: %{runs_in: "new", brief: "Go"}) |> render_change()
      refute has_element?(view, "#start-consequence strong")
      assert has_element?(view, "#start-consequence", "is woken with your brief and opens #")
    end

    test "a refused start keeps the stored files as picks; one deleted meanwhile drops out", %{
      conn: conn
    } do
      Fixtures.scenario()
      playbook = playbook_fixture("kept", [{"a", "A", "coordinator"}])
      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      upload_files(view, [{"a.md", "first"}, {"b.md", "second"}])
      view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

      # no channel picked: the start is refused after the files were stored
      html = view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_submit()
      assert html =~ "pick a channel"
      # the reply itself shows each file once, before the stored uploads drop
      assert html =~ ~r/id="start-brief-count"[^>]*>\s*2 of 10 files/
      [a, b] = Canopy.Documents.list(search: "", limit: 10) |> Enum.sort_by(& &1.filename)
      assert has_element?(view, "#start-picked-#{a.id}", "a.md")
      assert has_element?(view, "#start-picked-#{b.id}", "b.md")
      refute has_element?(view, "#start-brief-files [id^=start-upload-]")

      {:ok, _} = Canopy.Documents.delete(b)
      count = doc_count()
      view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_submit()
      assert has_element?(view, "#start-picked-#{a.id}")
      refute has_element?(view, "#start-picked-#{b.id}")
      # a retry sends the same files rather than storing them again
      assert doc_count() == count
    end

    test "an unfinished upload is refused before anything is stored", %{conn: conn} do
      ctx = Fixtures.scenario()
      playbook = playbook_fixture("slow", [{"a", "A", "coordinator"}])
      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

      upload =
        file_input(view, "#start-upload-form", :brief_files, [
          %{name: "big.md", content: String.duplicate("x", 1000)}
        ])

      render_upload(upload, "big.md", 50)
      count = doc_count()
      view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

      html =
        view
        |> form("#start-run-form", start: %{runs_in: "existing", channel_id: ctx.channel.id})
        |> render_submit()

      assert html =~ "A file is still uploading, or failed"
      assert doc_count() == count
      assert Runs.active_for_channel(ctx.channel.id) == nil
    end

    test "uploads and picks over ten are refused before anything is stored", %{conn: conn} do
      ctx = Fixtures.scenario()
      playbook = playbook_fixture("full", [{"a", "A", "coordinator"}])
      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

      for n <- 1..4, do: render_click(view, "pick_document", %{"id" => shared_doc("p#{n}.md").id})
      upload_files(view, for(n <- 1..7, do: {"u#{n}.md", "upload #{n}"}))
      assert has_element?(view, "#start-brief-count", "11 of 10 files")
      count = doc_count()
      view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

      html =
        view
        |> form("#start-run-form",
          start: %{runs_in: "existing", channel_id: ctx.channel.id, coordinator_id: ctx.agent.id}
        )
        |> render_submit()

      assert html =~ "At most 10 files on a brief; remove some."
      assert doc_count() == count
      assert Runs.active_for_channel(ctx.channel.id) == nil
    end

    test "at ten files, attach and the library are off and a pick is refused", %{conn: conn} do
      playbook = playbook_fixture("ten", [{"a", "A", "coordinator"}])
      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      assert has_element?(view, "#start-brief-attach[for]")

      for n <- 1..10,
          do: render_click(view, "pick_document", %{"id" => shared_doc("p#{n}.md").id})

      assert has_element?(view, "#start-brief-attach[aria-disabled='true'].btn-disabled")
      refute has_element?(view, "#start-brief-attach[for]")
      assert has_element?(view, "#start-brief-library[disabled]")

      html = render_click(view, "pick_document", %{"id" => shared_doc("p11.md").id})
      assert html =~ "At most 10 files on a brief."
      assert has_element?(view, "#start-brief-count", "10 of 10 files")
    end

    test "a file that can't be stored stops the start; the stored ones stay", %{conn: conn} do
      ctx = Fixtures.scenario()
      playbook = playbook_fixture("unsaved", [{"a", "A", "coordinator"}])
      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      upload_files(view, [{"tiny.md", "tiny"}, {"large.md", "more than eight bytes"}])
      view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

      # the upload passed the page's limit, but the store's is lower now
      Application.put_env(:canopy, :max_upload_bytes, 8)
      on_exit(fn -> Application.delete_env(:canopy, :max_upload_bytes) end)

      html =
        view
        |> form("#start-run-form",
          start: %{runs_in: "existing", channel_id: ctx.channel.id, coordinator_id: ctx.agent.id}
        )
        |> render_submit()

      assert html =~ "A file couldn&#39;t be saved; try attaching it again."
      assert Runs.active_for_channel(ctx.channel.id) == nil
      [tiny] = Canopy.Documents.list(search: "", limit: 10)
      assert tiny.filename == "tiny.md"
      assert has_element?(view, "#start-picked-#{tiny.id}", "tiny.md")
      refute has_element?(view, "#start-brief-files [id^=start-upload-]")
    end
  end

  test "start: in a new channel with a name you choose, and a role you swap", %{conn: conn} do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    other = Fixtures.agent_fixture(name: "stand-in")

    playbook =
      playbook_fixture("ship", [{"build", "Build", "dev"}], "roles:\n  dev: #{ctx.agent.name}\n")

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    assert has_element?(view, "#start-role-dev", "playbook default")

    view |> form("#start-run-form", start: %{runs_in: "new"}) |> render_change()

    view
    |> form("#start-run-form",
      start: %{runs_in: "new", repository_id: ctx.repository.id, brief: "Ship v2"}
    )
    |> render_change()

    assert has_element?(view, "#start-channel-name[value='ship-ship-v2']")

    view
    |> form("#start-run-form",
      start: %{
        runs_in: "new",
        repository_id: ctx.repository.id,
        channel_name: "launch-day",
        coordinator_id: ctx.agent.id,
        brief: "Ship v2",
        roles: %{dev: other.name}
      }
    )
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    "/channels/" <> channel_id = path
    assert Canopy.Channels.get!(channel_id).name == "launch-day"
    run = Runs.active_for_channel(channel_id)
    assert run.roster == %{"dev" => other.id}
    # the lead is woken in the new channel
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "start: every playbook offers a new or an existing channel, new first; busy ones can't be picked",
       %{conn: conn} do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    other_repo = Fixtures.repository_fixture()
    free = Fixtures.channel_fixture(%{repository_id: other_repo.id, name: "free-one"})
    busy = playbook_fixture("busy", [{"a", "A", "coordinator"}])

    {:ok, _run, false} =
      Runs.start(%{
        playbook: busy,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    # an old `channel: new` line no longer decides anything
    playbook = playbook_fixture("fresh", [{"a", "A", "coordinator"}], "channel: new\n")
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    assert has_element?(view, "[role=radiogroup][aria-label='Runs in']")
    assert has_element?(view, "input[name='start[runs_in]'][value='new'][checked]")
    assert has_element?(view, "input[name='start[runs_in]'][value='existing']:not([checked])")
    assert has_element?(view, "#start-channel-name")
    refute has_element?(view, "#start-channel")

    view
    |> form("#start-run-form", start: %{runs_in: "existing", coordinator_id: ctx.agent.id})
    |> render_change()

    refute has_element?(view, "#start-channel-name")

    assert has_element?(
             view,
             "#start-channel option[value=''][disabled][selected]",
             "Pick a channel"
           )

    assert has_element?(view, "#start-consequence", "is woken in the channel you pick.")

    in_repo = "#start-channel optgroup[label='#{ctx.repository.name}']"

    assert has_element?(
             view,
             "#{in_repo} option[value='#{ctx.channel.id}'][disabled]",
             "· run active"
           )

    in_other = "#start-channel optgroup[label='#{other_repo.name}']"

    assert has_element?(
             view,
             "#{in_other} option[value='#{free.id}']:not([disabled])",
             "#free-one"
           )

    view |> form("#start-run-form", start: %{channel_id: free.id}) |> render_change()
    assert has_element?(view, "#start-consequence", "@#{ctx.agent.name} is woken in #free-one.")

    # a busy channel posted anyway (the page was stale); the old "current" still means existing
    html =
      view
      |> element("#start-run-form")
      |> render_submit(%{
        "start" => %{
          "runs_in" => "current",
          "channel_id" => ctx.channel.id,
          "coordinator_id" => ctx.agent.id,
          "brief" => ""
        }
      })

    assert html =~
             "##{ctx.channel.name} already has a run in progress (busy); pick another channel or start a new one"

    assert Runs.active_for_channel(ctx.channel.id).playbook_name == "busy"
  end

  test "start: with no brief, the new channel is named after the playbook and the run starts", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    playbook = playbook_fixture("quiet", [{"a", "A", "coordinator"}])

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    assert has_element?(view, "label[for=start-brief]", "Optional")

    assert has_element?(
             view,
             "#start-brief[placeholder='Leave empty to let the playbook speak for itself']"
           )

    params = %{runs_in: "new", repository_id: ctx.repository.id, coordinator_id: ctx.agent.id}
    view |> form("#start-run-form", start: Map.put(params, :brief, "Go")) |> render_change()

    assert has_element?(
             view,
             "#start-consequence",
             "is woken with your brief and opens #quiet-go."
           )

    view |> form("#start-run-form", start: Map.put(params, :brief, "  ")) |> render_change()
    assert has_element?(view, "#start-channel-name[value='quiet']")

    assert has_element?(
             view,
             "#start-consequence",
             "@#{ctx.agent.name} is woken and opens #quiet."
           )

    view |> form("#start-run-form", start: Map.put(params, :brief, "")) |> render_submit()

    {path, _flash} = assert_redirect(view)
    "/channels/" <> channel_id = path
    assert Canopy.Channels.get!(channel_id).name == "quiet"
    assert Runs.active_for_channel(channel_id).brief == ""
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "start: a channel name already taken is refused and stays in the field to edit", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    Fixtures.channel_fixture(%{repository_id: ctx.repository.id, name: "launch"})
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    html =
      view
      |> form("#start-run-form",
        start: %{
          runs_in: "new",
          repository_id: ctx.repository.id,
          channel_name: "#Launch",
          coordinator_id: ctx.agent.id
        }
      )
      |> render_submit()

    assert html =~
             "#launch already exists in #{ctx.repository.name}; pick another name, or choose Existing channel"

    assert has_element?(view, "#start-channel-name[value='#Launch']")
  end

  # a JS flag set on focus was lost when a change in flight patched the form;
  # the server now knows a typed name by its differing from the suggestion
  test "start: a name typed while another field's change is in flight is kept and used", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    params = %{"runs_in" => "new", "repository_id" => ctx.repository.id, "brief" => "Go"}
    view |> form("#start-run-form", start: params) |> render_change()
    assert has_element?(view, "#start-channel-name[value='ship-go']")

    # the lead's change carries the name typed meanwhile; then the brief changes
    view
    |> element("#start-run-form")
    |> render_change(%{
      "_target" => ["start", "coordinator_id"],
      "start" =>
        Map.merge(params, %{"channel_name" => "my-launch", "coordinator_id" => ctx.agent.id})
    })

    assert has_element?(view, "#start-channel-name[value='my-launch']")

    view
    |> element("#start-run-form")
    |> render_change(%{
      "_target" => ["start", "brief"],
      "start" =>
        Map.merge(params, %{
          "brief" => "Go live now",
          "channel_name" => "my-launch",
          "coordinator_id" => ctx.agent.id
        })
    })

    assert has_element?(view, "#start-channel-name[value='my-launch']")

    view
    |> form("#start-run-form",
      start: %{"brief" => "Go live now", "coordinator_id" => ctx.agent.id}
    )
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    "/channels/" <> channel_id = path
    assert Canopy.Channels.get!(channel_id).name == "my-launch"
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "start: a name typed to match the suggestion stays put when the brief changes", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    params = %{"runs_in" => "new", "repository_id" => ctx.repository.id, "brief" => "Go"}
    view |> form("#start-run-form", start: params) |> render_change()

    view
    |> element("#start-run-form")
    |> render_change(%{
      "_target" => ["start", "channel_name"],
      "start" => Map.put(params, "channel_name", "ship-go")
    })

    view
    |> element("#start-run-form")
    |> render_change(%{
      "_target" => ["start", "brief"],
      "start" => Map.merge(params, %{"brief" => "Go live", "channel_name" => "ship-go"})
    })

    assert has_element?(view, "#start-channel-name[value='ship-go']")
  end

  test "start: the footer names the channel a typed name will really make", %{conn: conn} do
    ctx = Fixtures.scenario()
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    params = %{
      "runs_in" => "new",
      "repository_id" => ctx.repository.id,
      "coordinator_id" => ctx.agent.id,
      "brief" => "Go"
    }

    change = fn name ->
      view
      |> element("#start-run-form")
      |> render_change(%{
        "_target" => ["start", "channel_name"],
        "start" => Map.put(params, "channel_name", name)
      })
    end

    change.("  ##Taken-X ")
    # the field keeps what was typed; the footer shows the cleaned name
    assert has_element?(view, "#start-channel-name[value='  ##Taken-X ']")

    assert has_element?(
             view,
             "#start-consequence",
             "is woken with your brief and opens #taken-x."
           )

    refute has_element?(view, "#start-consequence", "##")

    # a name that cleans to nothing: the run gets the suggested one
    change.("#")
    assert has_element?(view, "#start-consequence", "opens #ship-go.")
    change.("")
    assert has_element?(view, "#start-consequence", "opens #ship-go.")

    # trimmed of dashes and cut to 50, as `Runs` names it
    change.(" -Foo- ")
    assert has_element?(view, "#start-consequence", "opens #foo.")
    change.(String.duplicate("a", 49) <> "-" <> String.duplicate("b", 10))
    assert has_element?(view, "#start-consequence", "opens ##{String.duplicate("a", 49)}.")
  end

  test "start: a name that cleans to nothing starts in the generated channel", %{conn: conn} do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    view
    |> form("#start-run-form",
      start: %{
        runs_in: "new",
        repository_id: ctx.repository.id,
        channel_name: "#",
        coordinator_id: ctx.agent.id
      }
    )
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    "/channels/" <> channel_id = path
    assert Canopy.Channels.get!(channel_id).name == "ship"
  end

  test "start: a taken name typed while another field's change is in flight is refused", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    Fixtures.channel_fixture(%{repository_id: ctx.repository.id, name: "launch"})
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    params = %{"runs_in" => "new", "repository_id" => ctx.repository.id}
    view |> form("#start-run-form", start: params) |> render_change()

    # only the lead's change ever reaches the server, carrying the typed name
    view
    |> element("#start-run-form")
    |> render_change(%{
      "_target" => ["start", "coordinator_id"],
      "start" =>
        Map.merge(params, %{"channel_name" => "#Launch", "coordinator_id" => ctx.agent.id})
    })

    html =
      view
      |> form("#start-run-form", start: %{"coordinator_id" => ctx.agent.id})
      |> render_submit()

    assert html =~ "#launch already exists in #{ctx.repository.name}"
    assert has_element?(view, "#start-channel-name[value='#Launch']")
    assert Canopy.Repo.aggregate(Canopy.Playbooks.Run, :count) == 0
  end

  test "start: a role nobody fills is named before the run is tried", %{conn: conn} do
    ctx = Fixtures.scenario()

    playbook =
      playbook_fixture("unfilled", [{"build", "Build", "dev"}], "roles:\n  dev: nobody-here\n")

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    assert has_element?(view, "#start-role-dev-agent option[value='']", "Pick an agent")
    view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

    html =
      view
      |> form("#start-run-form",
        start: %{
          runs_in: "existing",
          channel_id: ctx.channel.id,
          coordinator_id: ctx.agent.id,
          brief: "Go"
        }
      )
      |> render_submit()

    assert html =~ "pick who does Dev"
    assert Runs.active_for_channel(ctx.channel.id) == nil
  end

  test "start: a playbook disabled or deleted meanwhile is refused in plain words", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()
    playbook = playbook_fixture("gone", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

    {:ok, _} = Playbooks.set_enabled(playbook, false, playbook.lock_version)

    params = %{
      runs_in: "existing",
      channel_id: ctx.channel.id,
      coordinator_id: ctx.agent.id,
      brief: "Go"
    }

    html = view |> form("#start-run-form", start: params) |> render_submit()
    assert html =~ "disabled"
    assert Runs.active_for_channel(ctx.channel.id) == nil

    {:ok, _} = Playbooks.delete(Playbooks.get!(playbook.id))
    view |> form("#start-run-form", start: params) |> render_submit()
    assert Runs.active_for_channel(ctx.channel.id) == nil
  end

  test "a playbook's title is its body's first heading, never a later one", %{conn: conn} do
    body =
      playbook_text("rules", [{"a", "A", "coordinator"}])
      |> String.replace("Ground rules for rules.", "Ground rules for rules.\n\n---\n\n# Appendix")

    {:ok, untitled} = Playbooks.create(%{body: body})

    {:ok, titled} =
      Playbooks.create(%{
        body:
          playbook_text("titled", [{"a", "A", "coordinator"}])
          |> String.replace("---\n\nGround rules", "---\n\n# Ship it\n\nGround rules")
      })

    {:ok, view, _html} = live(conn, ~p"/playbooks?show=drafts")
    assert has_element?(view, "#expand-playbook-#{untitled.id}", "Rules")
    refute has_element?(view, "#expand-playbook-#{untitled.id}", "Appendix")
    assert has_element?(view, "#expand-playbook-#{titled.id}", "Ship it")

    {:ok, _view, html} = live(conn, ~p"/playbooks/#{untitled.id}/start")
    refute html =~ "Appendix"
  end

  test "start: typing in the form doesn't re-read the roster, channels, or repositories", %{
    conn: conn
  } do
    ctx = Fixtures.scenario()

    playbook =
      playbook_fixture("typed", [{"build", "Build", "dev"}], "roles:\n  dev: #{ctx.agent.name}\n")

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    view |> form("#start-run-form", start: %{runs_in: "new"}) |> render_change()

    test_pid = self()
    handler = "start-queries-#{inspect(test_pid)}"

    :telemetry.attach(
      handler,
      [:canopy, :repo, :query],
      fn _event, _measure, meta, _ -> send(test_pid, {:query, self(), meta.source}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    params = %{
      runs_in: "new",
      repository_id: ctx.repository.id,
      coordinator_id: ctx.agent.id,
      brief: "Ship the onboarding flow today"
    }

    # the first new-channel brief looks for a free channel name once
    view |> form("#start-run-form", start: params) |> render_change()
    assert has_element?(view, "#start-channel-name[value='typed-ship-the-onboarding-flow']")
    assert Enum.uniq(view_queries(view.pid)) == ["channels"]

    # more typing past the name's words, and another field: nothing read
    view
    |> form("#start-run-form", start: %{params | brief: "Ship the onboarding flow today, please"})
    |> render_change()

    view |> form("#start-run-form", start: %{params | runs_in: "existing"}) |> render_change()
    assert view_queries(view.pid) == []
    assert has_element?(view, "#start-role-dev", "playbook default")
  end

  test "start: the suggested channel name is the one the run would get", %{conn: conn} do
    ctx = Fixtures.scenario()
    playbook = playbook_fixture("taken", [{"a", "A", "coordinator"}])
    Fixtures.channel_fixture(%{repository_id: ctx.repository.id, name: "taken-go-live"})
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
    view |> form("#start-run-form", start: %{runs_in: "new"}) |> render_change()

    view
    |> form("#start-run-form",
      start: %{runs_in: "new", repository_id: ctx.repository.id, brief: "Go live"}
    )
    |> render_change()

    expected = Runs.channel_name(ctx.repository.id, nil, playbook.name, "Go live")
    assert expected == "taken-go-live-2"
    assert has_element?(view, "#start-channel-name[value='#{expected}']")
  end

  test "a run starting updates its playbook's last run on the library", %{conn: conn} do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    playbook = playbook_fixture("counted", [{"a", "A", "coordinator"}])
    other = playbook_fixture("uncounted", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-#{playbook.id}", "never run")

    {:ok, _run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "go"
      })

    assert has_element?(view, "#playbook-runs-#{playbook.id}", "1 running")
    assert has_element?(view, "#playbook-#{other.id}", "never run")

    # open, the row says where it runs and which step it's on
    view |> element("#expand-playbook-#{playbook.id}") |> render_click()

    assert has_element?(
             view,
             "#playbook-detail-#{playbook.id} a[href='/channels/#{ctx.channel.id}']"
           )

    assert has_element?(view, "#playbook-detail-#{playbook.id}", "step 1 of 1")

    {:ok, _, _} = Runs.cancel(Runs.active_for_channel(ctx.channel.id), :user, nil)
    assert has_element?(view, "#playbook-#{playbook.id}", "now")
    refute has_element?(view, "#playbook-runs-#{playbook.id}")
  end

  defp shared_doc(name) do
    {:ok, doc} =
      Canopy.Documents.create(%{
        filename: name,
        source: {:binary, "shared #{name}"},
        user_id: Canopy.Users.local().id
      })

    doc
  end

  defp upload_files(view, files) do
    upload =
      file_input(
        view,
        "#start-upload-form",
        :brief_files,
        Enum.map(files, fn {name, content} -> %{name: name, content: content} end)
      )

    for {name, _} <- files, do: render_upload(upload, name)
    upload
  end

  defp doc_count, do: Canopy.Repo.aggregate(Canopy.Documents.Document, :count)

  defp view_queries(pid) do
    receive do
      {:query, ^pid, source} -> [source | view_queries(pid)]
      {:query, _other, _source} -> view_queries(pid)
    after
      0 -> []
    end
  end

  describe "start: the section picker" do
    alias Canopy.Channels
    alias Canopy.Channels.Sections

    defp start_new(view, ctx, extra) do
      # the name field is only there once "New section…" is picked
      if extra[:section] == " new" do
        view
        |> form("#start-run-form",
          start: %{runs_in: "new", repository_id: ctx.repository.id, section: " new"}
        )
        |> render_change()
      end

      view
      |> form("#start-run-form",
        start:
          Map.merge(
            %{
              runs_in: "new",
              repository_id: ctx.repository.id,
              channel_name: "launch-day",
              coordinator_id: ctx.agent.id,
              brief: "Ship v2"
            },
            extra
          )
      )
      |> render_submit()
    end

    test "lists the repository's sections and picks the playbook's section:", %{conn: conn} do
      ctx = Fixtures.scenario()
      {:ok, _} = Sections.create(ctx.repository.id, "Payments")
      {:ok, _} = Sections.create(ctx.repository.id, "Releases")

      playbook =
        playbook_fixture("ship", [{"build", "Build", "coordinator"}], "section: releases\n")

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      view |> form("#start-run-form", start: %{runs_in: "new"}) |> render_change()

      assert has_element?(view, "#start-section option[value='']", "No section")
      assert has_element?(view, "#start-section option[value='Payments']")
      assert has_element?(view, "#start-section option[selected][value='Releases']")
      assert has_element?(view, "#start-section option[value=' new']", "New section…")
      refute has_element?(view, "#start-section-new")
      assert has_element?(view, "#start-consequence", "in Releases.")

      view
      |> form("#start-run-form", start: %{runs_in: "new", section: " new"})
      |> render_change()

      assert has_element?(view, "#start-section-new")
    end

    test "a playbook section: that doesn't exist yet is offered as a new section", %{conn: conn} do
      Fixtures.scenario()

      playbook =
        playbook_fixture("ship", [{"build", "Build", "coordinator"}], "section: Bug fixes\n")

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      view |> form("#start-run-form", start: %{runs_in: "new"}) |> render_change()

      assert has_element?(view, "#start-section option[selected][value=' new']")
      assert has_element?(view, "#start-section-new[value='Bug fixes']")
    end

    test "New section… makes the section and files the run's channel there", %{conn: conn} do
      ctx = Fixtures.scenario()
      on_exit(&stop_channels/0)
      stub_engine(self(), ctx.repository)
      playbook = playbook_fixture("ship", [{"build", "Build", "coordinator"}])

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      start_new(view, ctx, %{section: " new", section_new: "Launch"})

      {path, flash} = assert_redirect(view)
      "/channels/" <> channel_id = path
      assert [%{name: "Launch", id: id}] = Sections.list(ctx.repository.id)
      assert Channels.get!(channel_id).section_id == id
      assert flash["info"] =~ "in the new section Launch"
    end

    test "No section overrides the playbook's section:", %{conn: conn} do
      ctx = Fixtures.scenario()
      on_exit(&stop_channels/0)
      stub_engine(self(), ctx.repository)
      {:ok, _} = Sections.create(ctx.repository.id, "Releases")

      playbook =
        playbook_fixture("ship", [{"build", "Build", "coordinator"}], "section: Releases\n")

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      start_new(view, ctx, %{section: ""})

      {"/channels/" <> channel_id, _flash} = assert_redirect(view)
      assert Channels.get!(channel_id).section_id == nil
    end

    test "New section… with no name is refused before the run is tried", %{conn: conn} do
      ctx = Fixtures.scenario()
      playbook = playbook_fixture("ship", [{"build", "Build", "coordinator"}])

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      html = start_new(view, ctx, %{section: " new", section_new: ""})

      assert html =~ "name the new section"
      assert Channels.get_by_name(ctx.repository.id, "launch-day") == nil
      assert has_element?(view, "#start-section option[selected][value=' new']")
    end

    test "an existing channel's run never takes a section", %{conn: conn} do
      ctx = Fixtures.scenario()
      on_exit(&stop_channels/0)
      stub_engine(self(), ctx.repository)

      playbook =
        playbook_fixture("ship", [{"build", "Build", "coordinator"}], "section: Releases\n")

      {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")
      view |> form("#start-run-form", start: %{runs_in: "existing"}) |> render_change()

      view
      |> form("#start-run-form",
        start: %{runs_in: "existing", channel_id: ctx.channel.id, coordinator_id: ctx.agent.id}
      )
      |> render_submit()

      assert_redirect(view)
      assert Channels.get!(ctx.channel.id).section_id == nil
      assert Sections.list(ctx.repository.id) == []
    end
  end
end
