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

    # the name opens the builder, Start is labelled; the rest sit in the ⋯ menu, delete last
    assert has_element?(
             view,
             "#edit-playbook-#{playbook.id}[href='/playbooks/#{playbook.id}/edit']",
             "Bug fix"
           )

    assert has_element?(view, "#start-playbook-#{playbook.id}", "Start")
    # the steps as a strip: send-back and sign-off marked
    assert has_element?(view, "#playbook-strip-#{playbook.id} li", "Review")
    assert has_element?(view, "#playbook-strip-#{playbook.id} [title='waits for you']")
    menu = "#playbook-menu-#{playbook.id}"
    assert has_element?(view, "#{menu} #duplicate-playbook-#{playbook.id}", "Duplicate")
    assert has_element?(view, "#{menu} #export-playbook-#{playbook.id}", "Export")
    assert has_element?(view, "#{menu} li:last-child #delete-playbook-#{playbook.id}", "Delete")
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
    assert has_element?(view, "#playbook-#{playbook.id}[data-enabled='true']", "weekly")
    assert has_element?(view, "#start-playbook-#{playbook.id}")
    assert has_element?(view, "#show-enabled", "1")
    assert has_element?(view, "#show-drafts", "0")

    view |> element("#toggle-playbook-#{playbook.id}") |> render_click()
    assert has_element?(view, "#playbook-#{playbook.id}[data-enabled='false']")
    refute has_element?(view, "#start-playbook-#{playbook.id}")
    refute Playbooks.get!(playbook.id).enabled
    {:ok, drafts, _html} = live(conn, ~p"/playbooks?show=drafts")
    assert has_element?(drafts, "#playbook-#{playbook.id}")
    {:ok, enabled, _html} = live(conn, ~p"/playbooks?show=enabled")
    refute has_element?(enabled, "#playbook-#{playbook.id}")
    view |> element("#toggle-playbook-#{playbook.id}") |> render_click()
    assert Playbooks.get!(playbook.id).enabled

    view |> element("#duplicate-playbook-#{playbook.id}") |> render_click()
    copy = Playbooks.get_by_name("weekly-copy")
    assert_redirect(view, ~p"/playbooks/#{copy.id}/edit")

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

  test "a playbook card opens its editor: Edit is the card's link", %{conn: conn} do
    {:ok, playbook} = Playbooks.create(%{body: Playbooks.bug_fix_text()})
    {:ok, view, _html} = live(conn, ~p"/playbooks")

    card = "#playbook-#{playbook.id}[data-card]"
    assert has_element?(view, "#{card} #edit-playbook-#{playbook.id}[data-card-link]")
    # only Edit: Start, the toggle and the menu stay controls of their own
    refute has_element?(view, "#{card} [data-card-link]:not(#edit-playbook-#{playbook.id})")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#{card} [data-card-link]") |> render_click()

    assert to == ~p"/playbooks/#{playbook.id}/edit"
  end

  test "an agent's draft is labelled and starts disabled", %{conn: conn} do
    agent = Fixtures.agent_fixture(name: "drafter")

    {:ok, draft} =
      Playbooks.save_draft(agent, playbook_text("agent-made", [{"a", "A", "coordinator"}]))

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#playbook-#{draft.id}[data-enabled='false']", "draft by @drafter")
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
        runs_in: "current",
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
    # the name field was typed in (the page marks that on focus)
    |> render_submit(%{"start" => %{"channel_name_touched" => "true"}})

    {path, _flash} = assert_redirect(view)
    "/channels/" <> channel_id = path
    assert Canopy.Channels.get!(channel_id).name == "launch-day"
    run = Runs.active_for_channel(channel_id)
    assert run.roster == %{"dev" => other.id}
    # the lead is woken in the new channel
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "start: a channel: new playbook offers no existing channel", %{conn: conn} do
    playbook = playbook_fixture("fresh", [{"a", "A", "coordinator"}], "channel: new\n")
    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    assert has_element?(view, "#start-runs-in-new input[name='start[runs_in]'][value='new']")
    refute has_element?(view, "[role=radiogroup][aria-label='Runs in']")
    refute has_element?(view, "input[name='start[runs_in]'][value='current']")
    refute has_element?(view, "#start-channel")
    assert has_element?(view, "#start-channel-name")
  end

  test "start: a role nobody fills is named before the run is tried", %{conn: conn} do
    ctx = Fixtures.scenario()

    playbook =
      playbook_fixture("unfilled", [{"build", "Build", "dev"}], "roles:\n  dev: nobody-here\n")

    {:ok, view, _html} = live(conn, ~p"/playbooks/#{playbook.id}/start")

    assert has_element?(view, "#start-role-dev-agent option[value='']", "Pick an agent")

    html =
      view
      |> form("#start-run-form",
        start: %{
          runs_in: "current",
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

    {:ok, _} = Playbooks.set_enabled(playbook, false, playbook.lock_version)

    params = %{
      runs_in: "current",
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

    {:ok, view, _html} = live(conn, ~p"/playbooks")
    assert has_element?(view, "#edit-playbook-#{untitled.id}", "Rules")
    refute has_element?(view, "#edit-playbook-#{untitled.id}", "Appendix")
    assert has_element?(view, "#edit-playbook-#{titled.id}", "Ship it")

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

    view |> form("#start-run-form", start: %{params | runs_in: "current"}) |> render_change()
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

    assert has_element?(view, "#playbook-#{playbook.id}", "last run now")
    assert has_element?(view, "#playbook-#{playbook.id}", "1 running")
    assert has_element?(view, "#playbook-#{other.id}", "never run")
  end

  defp view_queries(pid) do
    receive do
      {:query, ^pid, source} -> [source | view_queries(pid)]
      {:query, _other, _source} -> view_queries(pid)
    after
      0 -> []
    end
  end
end
