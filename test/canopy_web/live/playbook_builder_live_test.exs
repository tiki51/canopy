defmodule CanopyWeb.PlaybookBuilderLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Fixtures, Playbooks}
  alias Canopy.Playbooks.Definition
  alias CanopyWeb.PlaybookBuilder

  defp seed! do
    {:ok, playbook} = Playbooks.create(%{body: Playbooks.bug_fix_text(), source: "seed"})
    playbook
  end

  defp edit(view, params), do: view |> element("#builder-form") |> render_change(params)

  # the step row's uid, by its title
  defp uid(view, title) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li[data-title='#{title}']")
    |> LazyHTML.attribute("data-uid")
    |> List.first()
  end

  defp definition!(playbook) do
    {:ok, d} = playbook.id |> Playbooks.get!() |> Playbooks.definition()
    d
  end

  test "a playbook reads as the run goes: settings, steps, send-back rail, ground rules", %{
    conn: conn
  } do
    playbook = seed!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    assert has_element?(view, "#about-title[value='Bug fix']")
    assert has_element?(view, "#edit-name", "bug-fix")
    assert has_element?(view, "#setting-lead", "@project-manager")
    assert has_element?(view, "#setting-team", "@bugfix-team")
    assert has_element?(view, "#role-chip-reviewer", "Reviewer")

    assert has_element?(view, "li[data-title='Fix']", "in parallel")
    assert has_element?(view, "li[data-title='Review']", "can send back to Fix")
    assert has_element?(view, "li[data-title='User sign-off']", "waits for you")

    assert has_element?(
             view,
             "li[data-title='User sign-off']",
             "Waits for your approval, then the run is done."
           )

    assert has_element?(view, "li[data-title='Fix'] .rail-start")
    assert has_element?(view, "li[data-title='Verify'] .rail-mid")
    assert has_element?(view, "li[data-title='Review'] .rail-end")
    assert has_element?(view, "#guidance-rendered li", "Nobody commits or pushes")
    assert has_element?(view, "#save-state", "Saved")
    assert has_element?(view, "#save-playbook[disabled]")
  end

  test "editing a step and saving writes the file; Discard goes back", %{conn: conn} do
    playbook = seed!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    fix = uid(view, "Fix")

    view |> element("#open-step-#{fix}") |> render_click()
    assert has_element?(view, "#step-#{fix}-title")

    edit(view, %{"steps" => %{fix => %{"title" => "Fix it", "done_when" => "the test passes"}}})
    assert has_element?(view, "#save-state", "Unsaved changes")
    assert has_element?(view, "#builder-enabled[disabled]")

    view |> element("#builder-form") |> render_submit()
    assert has_element?(view, "#save-state", "Saved")

    d = definition!(playbook)
    assert %{title: "Fix it", id: "fix"} = Definition.step(d, "fix")
    assert Definition.step_section(d, "fix") =~ ~r/\n\nDone when: the test passes\z/

    edit(view, %{"title" => "Bugs"})
    assert has_element?(view, "#discard-changes")
    view |> element("#discard-changes") |> render_click()
    assert has_element?(view, "#about-title[value='Bug fix']")
  end

  test "moving a review below what it sends back to is a problem with one-click fixes", %{
    conn: conn
  } do
    playbook = seed!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    ids =
      for t <- [
            "Triage and scope",
            "Reproduce with a failing test",
            "Verify",
            "Review",
            "Fix",
            "User sign-off"
          ],
          do: uid(view, t)

    render_hook(view, "reorder", %{"uids" => ids})
    assert has_element?(view, "#problem-banner", "1 thing to fix")

    assert has_element?(
             view,
             "#problem-banner",
             "Step 4 · Review — Sends work back to Fix, which now comes after it"
           )

    assert has_element?(view, "#save-playbook[disabled]")
    assert has_element?(view, "li[data-title='Review'] button", "Send back to Verify instead")

    view
    |> element("li[data-title='Review'] button", "Send back to Verify instead")
    |> render_click()

    refute has_element?(view, "#problem-banner")
    view |> element("#builder-form") |> render_submit()
    assert %{on_reject: "verify"} = Definition.step(definition!(playbook), "review")

    assert Enum.map(definition!(playbook).steps, & &1.id) ==
             ~w(triage reproduce verify review fix sign-off)
  end

  test "deleting a step clears send-backs to it, and Undo puts both back", %{conn: conn} do
    playbook = seed!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    fix = uid(view, "Fix")
    view |> element("#open-step-#{fix}") |> render_click()
    view |> element("#delete-step-#{fix}") |> render_click()

    assert has_element?(
             view,
             "#undo-toast",
             "Deleted Fix. Review and User sign-off no longer send work back."
           )

    refute has_element?(view, "li[data-title='Fix']")
    refute has_element?(view, "li[data-title='Review']", "can send back")
    refute has_element?(view, "li[data-title='User sign-off']", "can send back")

    view |> element("#undo-delete") |> render_click()
    assert has_element?(view, "li[data-title='Review']", "can send back to Fix")
    assert has_element?(view, "li[data-title='User sign-off']", "can send back to Fix")
    assert has_element?(view, "#save-state", "Saved")
  end

  test "a step with two send-backs gets one label naming both", %{conn: conn} do
    playbook = seed!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    fix = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("li[data-title='Fix']")
    labels = LazyHTML.query(fix, ".send-back-label")

    # both loops keep their own rail
    assert fix |> LazyHTML.query(".rail-start") |> Enum.count() == 2
    assert Enum.count(labels) == 1

    assert LazyHTML.text(labels) =~
             "Review and User sign-off send it back here when changes are requested"

    # clear of the second rail
    assert LazyHTML.attribute(labels, "style") == ["--label-lane: 1"]
  end

  defp seed_feature_build! do
    {:ok, playbook} = Playbooks.create(%{body: Playbooks.feature_build_text(), source: "seed"})
    playbook
  end

  defp labels(view, title) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li[data-title='#{title}'] .send-back-label")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp delete_step(view, title) do
    id = uid(view, title)
    view |> element("#open-step-#{id}") |> render_click()
    view |> element("#delete-step-#{id}") |> render_click()
  end

  # b, c, d and e all send work back to a
  defp four_senders! do
    playbook_fixture("four-back", [
      {"a", "A", "coordinator"},
      {"b", "B", "coordinator", "on_reject: a"},
      {"c", "C", "coordinator", "on_reject: a"},
      {"d", "D", "coordinator", "on_reject: a"},
      {"e", "E", "coordinator", "on_reject: a"}
    ])
  end

  test "a target with one sender: its label says sends", %{conn: conn} do
    playbook = seed_feature_build!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    assert labels(view, "Clarify and propose 3 designs") == [
             "User approves a design sends it back here when changes are requested"
           ]

    assert labels(view, "Technical design docs") == [
             "Review technical designs sends it back here when changes are requested"
           ]
  end

  test "a target with three senders: one label, serial comma", %{conn: conn} do
    playbook = seed_feature_build!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    assert labels(view, "Implement, and write the test plan") == [
             "Test and code review, Designer approves the result, and User sign-off send it back here when changes are requested"
           ]

    build =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("li[data-title='Implement, and write the test plan'] .rail-start")

    assert Enum.count(build) == 3

    # clear of the third rail
    assert has_element?(
             view,
             "li[data-title='Implement, and write the test plan'] .send-back-label[style='--label-lane: 2']"
           )
  end

  test "four senders to one target: the label names all four", %{conn: conn} do
    playbook = four_senders!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    assert labels(view, "A") == [
             "B, C, D, and E send it back here when changes are requested"
           ]
  end

  test "deleting a step one step sends back to: the toast says sends", %{conn: conn} do
    playbook = seed_feature_build!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    delete_step(view, "Clarify and propose 3 designs")

    assert has_element?(
             view,
             "#undo-toast",
             "Deleted Clarify and propose 3 designs. User approves a design no longer sends work back."
           )
  end

  test "deleting Build clears three send-backs, and Undo restores all three", %{conn: conn} do
    playbook = seed_feature_build!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    delete_step(view, "Implement, and write the test plan")

    assert has_element?(
             view,
             "#undo-toast",
             "Deleted Implement, and write the test plan. Test and code review, Designer approves the result, and User sign-off no longer send work back."
           )

    senders = ["Test and code review", "Designer approves the result", "User sign-off"]
    for t <- senders, do: refute(has_element?(view, "li[data-title='#{t}']", "can send back"))

    view |> element("#undo-delete") |> render_click()

    for t <- senders,
        do:
          assert(
            has_element?(
              view,
              "li[data-title='#{t}']",
              "can send back to Implement, and write the test plan"
            )
          )
  end

  test "deleting a step four steps send back to: the toast names all four", %{conn: conn} do
    playbook = four_senders!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    delete_step(view, "A")

    assert has_element?(
             view,
             "#undo-toast",
             "Deleted A. B, C, D, and E no longer send work back."
           )
  end

  test "a blank playbook: name, description, a step with the lead; Create", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/playbooks/new/blank")
    assert has_element?(view, "#builder-title", "Untitled playbook")
    assert has_element?(view, "#save-playbook[disabled]", "Create playbook")
    refute has_element?(view, "#problem-banner")
    [s1] = [uid(view, "Untitled step")]

    edit(view, %{
      "title" => "Release notes",
      "description" => "Turn merged PRs into checked release notes.",
      "steps" => %{s1 => %{"title" => "Collect what changed"}}
    })

    assert has_element?(view, "#edit-name", "release-notes")
    assert has_element?(view, "#step-#{s1}", "collect-what-changed")
    view |> element("#step-#{s1} button", "The lead does it") |> render_click()

    # a sign-off step from the add menu
    view |> element("#add-step") |> render_click()
    view |> element("#preset-sign_off") |> render_click()
    assert has_element?(view, "li[data-title='Your sign-off']", "waits for you")

    refute has_element?(view, "#save-playbook[disabled]")
    view |> element("#builder-form") |> render_submit()
    playbook = Playbooks.get_by_name("release-notes")
    assert_patch(view, ~p"/playbooks/#{playbook.id}/edit")

    assert playbook.source == "user"
    assert playbook.body =~ "\n# Release notes\n"
    d = definition!(playbook)

    assert [
             %{id: "collect-what-changed", owner: ["coordinator"]},
             %{id: "your-sign-off", approval: true}
           ] = d.steps
  end

  test "choosing who does a step: an agent becomes a role, and a role renames everywhere", %{
    conn: conn
  } do
    agent = Fixtures.agent_fixture(name: "scribe")
    playbook = playbook_fixture("notes", [{"write", "Write", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    write = uid(view, "Write")

    view |> element("#open-step-#{write}") |> render_click()
    view |> element("#add-owner-#{write}") |> render_click()
    view |> element("#owner-agent-#{agent.name}") |> render_click()
    assert has_element?(view, "#role-chip-scribe", "@scribe")
    assert has_element?(view, "li[data-title='Write']", "in parallel")

    view |> element("#role-chip-scribe") |> render_click()
    edit(view, %{"role" => %{"key" => "scribe", "name" => "Writer", "agent" => "scribe"}})
    assert has_element?(view, "#role-chip-writer")

    view |> element("#builder-form") |> render_submit()
    d = definition!(playbook)
    assert d.roles == %{"writer" => "scribe"}
    assert %{owner: ["coordinator", "writer"]} = Definition.step(d, "write")
  end

  test "settings popovers: lead, nudge", %{conn: conn} do
    lead = Fixtures.agent_fixture(name: "boss")
    playbook = playbook_fixture("tiny", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    # two or more settings at their defaults: the compact variant
    assert has_element?(view, "#more-settings")
    view |> element("#more-settings") |> render_click()

    view |> element("#setting-lead") |> render_click()
    assert has_element?(view, "#lead-popover", "Who leads a run")
    view |> element("#lead-option-#{lead.name}") |> render_click()
    view |> element("#setting-nudge") |> render_click()
    view |> element("#nudge-120") |> render_click()
    view |> element("#builder-form") |> render_submit()

    d = definition!(playbook)
    assert {d.coordinator, d.stall_after} == {"boss", 120}
    assert Playbooks.get!(playbook.id).body =~ "stall_after: 2h\n"
  end

  test "where a run happens is not a playbook setting: an old channel line is dropped on save", %{
    conn: conn
  } do
    playbook = playbook_fixture("old", [{"a", "A", "coordinator"}], "channel: new\n")
    assert playbook.body =~ "channel: new\n"
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    view |> element("#more-settings") |> render_click()

    refute has_element?(view, "#runs-in-new")
    refute has_element?(view, "#runs-in-current")

    edit(view, %{"title" => "Old one"})
    view |> element("#builder-form") |> render_submit()
    refute Playbooks.get!(playbook.id).body =~ "channel:"
  end

  test "a change made elsewhere while editing: load theirs, or save mine as a copy", %{conn: conn} do
    playbook = playbook_fixture("shared", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    edit(view, %{"title" => "Mine"})

    {:ok, _} =
      Playbooks.update(playbook, %{
        body: String.replace(playbook.body, "title: A", "title: Theirs")
      })

    assert has_element?(view, "#builder-conflict", "changed somewhere else")

    view |> element("#save-copy") |> render_click()
    copy = Playbooks.get_by_name("shared-copy")
    assert copy.body =~ "# Mine"
    refute copy.enabled
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")
    assert Playbooks.get!(playbook.id).body =~ "title: Theirs"
  end

  test "deleted elsewhere while editing: the edits stay, and can be saved as a new playbook", %{
    conn: conn
  } do
    playbook = playbook_fixture("doomed", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    edit(view, %{"title" => "Rescued"})

    {:ok, _} = Playbooks.delete(playbook)

    assert has_element?(view, "#builder-conflict", "deleted somewhere else")
    refute has_element?(view, "#load-theirs")
    assert has_element?(view, "#about-title[value='Rescued']")

    view |> element("#save-copy") |> render_click()
    copy = Playbooks.get_by_name("doomed-copy")
    assert copy.body =~ "# Rescued"
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")
  end

  test "file text being typed survives a change made elsewhere", %{conn: conn} do
    playbook = playbook_fixture("typed", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    view |> element("#builder-edit-text") |> render_click()

    mine = String.replace(playbook.body, "title: A", "title: Mine")
    view |> form("#playbook-text-form", playbook: %{body: mine}) |> render_change()
    assert has_element?(view, "#playbook-builder[data-dirty='true']")

    {:ok, _} =
      Playbooks.update(playbook, %{body: String.replace(playbook.body, "title: A", "title: B")})

    assert has_element?(view, "#playbook-text-form")
    assert has_element?(view, "#playbook-text-form textarea", "title: Mine")
    assert has_element?(view, "#builder-conflict", "changed somewhere else")
  end

  test "renaming a role to one that exists says why it didn't", %{conn: conn} do
    playbook =
      playbook_fixture(
        "two-roles",
        [{"a", "A", "dev"}, {"b", "B", "qa"}],
        "roles:\n  dev: x\n  qa: y\n"
      )

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    view |> element("#role-chip-dev") |> render_click()
    edit(view, %{"role" => %{"key" => "dev", "name" => "QA"}})

    assert has_element?(view, "#role-name-error", "There is already a role called Qa.")
    assert has_element?(view, "#role-chip-dev")
  end

  test "a new, untouched playbook has nothing unsaved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/playbooks/new/blank")
    assert has_element?(view, "#playbook-builder[data-dirty='false']")
    edit(view, %{"title" => "Something"})
    assert has_element?(view, "#playbook-builder[data-dirty='true']")
  end

  test "an agent's draft opens with a banner; enabling approves what the page shows", %{
    conn: conn
  } do
    agent = Fixtures.agent_fixture(name: "drafter")

    {:ok, draft} =
      Playbooks.save_draft(agent, playbook_text("agent-made", [{"a", "A", "coordinator"}]))

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{draft.id}/edit")

    assert has_element?(view, "#draft-banner", "@drafter drafted this playbook")
    view |> element("#enable-draft") |> render_click()
    assert Playbooks.get!(draft.id).enabled
    refute has_element?(view, "#draft-banner")
  end

  test "Edit file text is the last resort: the old text editor", %{conn: conn} do
    playbook = playbook_fixture("plain", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    view |> element("#builder-edit-text") |> render_click()
    assert has_element?(view, "#playbook-text-form")

    view
    |> form("#playbook-text-form", playbook: %{body: "---\nname: Bad_Name\n---\n"})
    |> render_change()

    assert has_element?(view, "#playbook-errors", "kebab-case")

    body = String.replace(playbook.body, "title: A", "title: By hand")
    view |> form("#playbook-text-form", playbook: %{body: body}) |> render_submit()
    refute has_element?(view, "#playbook-text-form")
    assert has_element?(view, "li[data-title='By hand']")
  end

  test "Save applies what the form submits: ⌘S right after typing saves the typed text", %{
    conn: conn
  } do
    playbook = seed!()
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    fix = uid(view, "Fix")
    view |> element("#open-step-#{fix}") |> render_click()
    edit(view, %{"title" => "Bug fix, faster"})

    # the submit cancels the debounced change for what was typed last, so
    # only the submit carries it
    view
    |> element("#builder-form")
    |> render_submit(%{
      "title" => "Bug fix, fastest",
      "steps" => %{fix => %{"title" => "Fix it now"}}
    })

    assert has_element?(view, "#save-state", "Saved")
    assert has_element?(view, "#playbook-builder[data-dirty='false']")
    assert Playbooks.get!(playbook.id).body =~ "\n# Bug fix, fastest\n"
    assert %{title: "Fix it now"} = Definition.step(definition!(playbook), "fix")
  end

  test "a title with no plain letters: the made-up name is shown, editable, and checked", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/playbooks/new/blank")
    assert has_element?(view, "#edit-name", "choose one")
    [s1] = [uid(view, "Untitled step")]

    edit(view, %{
      "title" => "日本語のレビュー",
      "description" => "Review the Japanese copy.",
      "steps" => %{s1 => %{"title" => "Read it"}}
    })

    view |> element("#step-#{s1} button", "The lead does it") |> render_click()
    assert has_element?(view, "#edit-name", "playbook")
    refute has_element?(view, "#save-playbook[disabled]")

    # a name Create would refuse is said, not hidden
    view |> element("#edit-name") |> render_click()
    edit(view, %{"name" => "x"})
    assert has_element?(view, "#problem-banner", "needs at least 2 characters")
    assert has_element?(view, "#save-playbook[disabled]")

    edit(view, %{"name" => "ja-review"})
    refute has_element?(view, "#problem-banner")
    view |> element("#builder-form") |> render_submit()

    playbook = Playbooks.get_by_name("ja-review")
    assert_patch(view, ~p"/playbooks/#{playbook.id}/edit")
    assert playbook.body =~ "\n# 日本語のレビュー\n"
  end

  test "a one-letter title can still be created", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/playbooks/new/blank")
    [s1] = [uid(view, "Untitled step")]

    edit(view, %{
      "title" => "Q",
      "description" => "Quick checks.",
      "steps" => %{s1 => %{"title" => "Check"}}
    })

    view |> element("#step-#{s1} button", "The lead does it") |> render_click()
    assert has_element?(view, "#edit-name", "playbook")
    view |> element("#builder-form") |> render_submit()
    assert %{body: body} = Playbooks.get_by_name("playbook")
    assert body =~ "\n# Q\n"
  end

  test "file text being typed keeps Enabled locked: toggling never discards it", %{conn: conn} do
    playbook = playbook_fixture("locked", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")
    view |> element("#builder-edit-text") |> render_click()

    mine = String.replace(playbook.body, "title: A", "title: Mine")
    view |> form("#playbook-text-form", playbook: %{body: mine}) |> render_change()
    assert has_element?(view, "#builder-enabled[disabled]")

    render_hook(view, "toggle_enabled", %{})
    assert Playbooks.get!(playbook.id).enabled
    assert has_element?(view, "#playbook-text-form textarea", "title: Mine")
  end

  test "toggling Enabled on a playbook deleted elsewhere leaves for the library", %{conn: conn} do
    playbook = playbook_fixture("vanished", [{"a", "A", "coordinator"}])
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    # gone without the page hearing of it yet
    Canopy.Repo.delete!(playbook)

    view |> element("#builder-enabled") |> render_click()
    {path, flash} = assert_redirect(view)
    assert path == ~p"/playbooks"
    assert flash["error"] =~ "vanished was deleted"
  end

  test "Undo at the most steps says why it can't put the step back", %{conn: conn} do
    steps = for n <- 1..PlaybookBuilder.max_steps(), do: {"s#{n}", "Step #{n}", "coordinator"}
    playbook = playbook_fixture("full", steps)
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/edit")

    first = uid(view, "Step 1")
    view |> element("#open-step-#{first}") |> render_click()
    view |> element("#delete-step-#{first}") |> render_click()
    render_hook(view, "add_step", %{"index" => "19"})

    html = view |> element("#undo-delete") |> render_click()
    assert html =~ "A playbook has at most 20 steps"
    refute has_element?(view, "li[data-title='Step 1']")
    assert has_element?(view, "#steps-heading", "20")
    assert has_element?(view, "#undo-toast")
  end
end
