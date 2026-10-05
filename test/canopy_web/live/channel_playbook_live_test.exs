defmodule CanopyWeb.ChannelPlaybookLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Fixtures, Runtime, Schedules, Timeline}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.EventStream
  alias Canopy.Playbooks.Runs

  setup :set_mox_global

  setup do
    dev = Fixtures.agent_fixture(%{name: "dev" <> Fixtures.unique_suffix()})
    ctx = Fixtures.scenario(members: [dev])
    # after the repository fixture's own on_exit, so channel servers stop first
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    Timeline.subscribe(ctx.channel.id)

    playbook =
      playbook_fixture(
        "fix-it",
        [
          {"plan", "Plan", "coordinator"},
          {"fix", "Fix", "dev"},
          {"sign-off", "Sign-off", "coordinator", "approval: user"}
        ],
        "roles:\n  dev: #{dev.name}\n"
      )

    Map.merge(ctx, %{dev: dev, playbook: playbook})
  end

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  defp start_run(ctx) do
    {:ok, run, false} =
      Runs.start(%{
        playbook: ctx.playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "The button is blue"
      })

    run
  end

  defp finish_turn(ctx) do
    sid = ctx.session.engine_session_id

    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event,
       %Event{type: :agent_completed, session_id: sid, data: %{}, raw_type: "test"}}
    )

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
  end

  test "start a run from the panel; the chip shows where it is", %{conn: conn} = ctx do
    {:ok, view, _html} = open(conn, ctx.channel)
    refute has_element?(view, "#playbook-chip")
    view |> element("#toggle-details") |> render_click()
    assert has_element?(view, "#edit-playbook", "none running")
    view |> element("#edit-playbook") |> render_click()
    assert has_element?(view, "#details-panel #playbook-panel #start-playbook-form")
    # the coordinator defaults to the channel owner
    assert has_element?(view, "#start-coordinator option[selected][value='#{ctx.agent.id}']")

    view
    |> form("#start-playbook-form",
      start: %{
        playbook_id: ctx.playbook.id,
        coordinator_id: ctx.agent.id,
        brief: "Fix the colour"
      }
    )
    |> render_submit()

    assert has_element?(view, "#playbook-chip", "fix-it · 1/3 Plan")
    assert has_element?(view, "#playbook-run-brief", "Fix the colour")
    assert has_element?(view, "#playbook-step-plan[data-status='active']")
    assert has_element?(view, "#sidebar-playbook-#{ctx.channel.id}")

    # the user started it, so the coordinator is woken with the first step
    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "The user started it here."
  end

  test "progress shows as the run moves; Approve completes the gate and wakes the coordinator, resetting the budget",
       %{conn: conn} = ctx do
    run = start_run(ctx)
    {:ok, view, _html} = open(conn, ctx.channel)
    assert has_element?(view, "#playbook-chip", "fix-it · 1/3 Plan")

    {:ok, run, _} = Runs.advance(run, {:agent, ctx.agent.id}, result: "planned")
    assert has_element?(view, "#playbook-chip", "fix-it · 2/3 Fix · @#{ctx.dev.name}")
    view |> element("#playbook-chip") |> render_click()
    assert has_element?(view, "#playbook-step-plan[data-status='done']")
    assert has_element?(view, "#playbook-step-plan-result", "planned")

    {:ok, run, _} = Runs.advance(run, {:agent, ctx.agent.id}, result: "fixed")
    {:ok, _run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "summary")
    assert has_element?(view, "#playbook-chip[data-status='awaiting_approval']")
    assert has_element?(view, "#attention-#{ctx.channel.id}")
    assert has_element?(view, "#playbook-approval #approve-playbook-step")

    # spend the chatter budget, then let a counted wake pause the channel
    {:ok, _} = Canopy.Settings.update(%{chatter_limit: 1})
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "hi")
    assert_receive {:prompted, _sid, _}, 2_000
    finish_turn(ctx)
    Runtime.wake_playbook(ctx.channel.id, ctx.agent.id, "counted", reset: false)
    _ = :sys.get_state(Runtime.Supervisor.whereis(ctx.channel.id))
    assert Runtime.paused?(ctx.channel.id)

    view |> element("#approve-playbook-step") |> render_click()
    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "The user approved \"Sign-off\""
    refute Runtime.paused?(ctx.channel.id)

    assert has_element?(view, "#playbook-panel", "No playbook is running here")
    assert has_element?(view, "#playbook-recent", "completed")
    refute has_element?(view, "#playbook-chip")
    refute has_element?(view, "#sidebar-playbook-#{ctx.channel.id}")
  end

  test "Request changes sends the note; Cancel ends the run", %{conn: conn} = ctx do
    run = start_run(ctx)
    {:ok, run, _} = Runs.advance(run, {:agent, ctx.agent.id}, result: "a", next: "sign-off")
    {:ok, _run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "b")

    {:ok, view, _html} = open(conn, ctx.channel)
    view |> element("#playbook-chip") |> render_click()

    view
    |> form("#request-changes-form", %{run_id: run.id, note: "still blue"})
    |> render_submit()

    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "Their note: still blue"
    assert has_element?(view, "#playbook-step-sign-off[data-status='active']")

    view |> element("#cancel-playbook-run") |> render_click()
    refute has_element?(view, "#playbook-chip")
    assert Runs.get!(run.id).status == "cancelled"
    assert_receive {:timeline, %{event_type: "playbook_cancelled"}}
  end

  test "the run panel opens once in Details, the first time this browser sees the run; then the chip opens it",
       %{conn: conn} = ctx do
    run = start_run(ctx)

    # nothing stored in this browser: Details opens on the run, and the run is remembered
    {:ok, view, _html} = open(conn, ctx.channel)
    refute has_element?(view, "#playbook-panel")
    render_hook(view, "pref", %{"key" => "channel-details", "value" => "", "media" => true})
    refute has_element?(view, "#details-panel")
    render_hook(view, "pref", %{"key" => "playbook-seen", "value" => ""})
    assert has_element?(view, "#details-panel #playbook-panel")
    assert has_element?(view, "#edit-playbook", "fix-it · 1/3 Plan")
    assert_push_event(view, "pref", %{key: "playbook-seen", value: value})
    assert value == run.id

    # the panel: role → @agent chips, the coordinator labelled, one sign-off marker
    assert has_element?(view, "#playbook-roster-dev", "dev")
    assert has_element?(view, "#playbook-roster-dev", "@#{ctx.dev.name}")
    assert render(view) =~ ~s(aria-label="filled by">→</span>)
    assert has_element?(view, "#reassign-coordinator-form label", "Lead")
    sign_off = view |> element("#playbook-step-sign-off") |> render()
    assert length(Regex.scan(~r/>\s*sign-off\s*</, sign_off)) == 1

    # its row in Details › Automation closes it
    view |> element("#edit-playbook") |> render_click()
    refute has_element?(view, "#playbook-panel")

    # a browser that has seen the run: collapsed, the chip opens it
    {:ok, view, _html} = open(conn, ctx.channel)
    render_hook(view, "pref", %{"key" => "channel-details", "value" => "", "media" => true})
    render_hook(view, "pref", %{"key" => "playbook-seen", "value" => "#{run.id},run_old"})
    refute has_element?(view, "#playbook-panel")
    view |> element("#playbook-chip") |> render_click()
    assert has_element?(view, "#details-panel #playbook-panel")
    assert_push_event(view, "details:focus", %{section: "playbook"})

    # below lg, where Details is an overlay, it never opens by itself, and
    # the run isn't marked seen: its one look is still to come
    {:ok, view, _html} = open(conn, ctx.channel)
    render_hook(view, "pref", %{"key" => "channel-details", "value" => "", "media" => false})
    render_hook(view, "pref", %{"key" => "playbook-seen", "value" => ""})
    refute has_element?(view, "#details-panel")
    refute_push_event(view, "pref", %{key: "playbook-seen"})
    # ...and the palette's "run a playbook" then opens it on the run, not collapsed
    render_hook(view, "toggle_playbook", %{})
    assert has_element?(view, "#details-panel #playbook-panel")
    assert_push_event(view, "details:focus", %{section: "playbook"})

    # a window narrowed below lg afterwards: a new run no longer opens it...
    {:ok, view, _html} = open(conn, ctx.channel)
    render_hook(view, "pref", %{"key" => "channel-details", "value" => "", "media" => true})
    render_hook(view, "pref", %{"key" => "channel-details", "value" => "", "media" => false})
    render_hook(view, "pref", %{"key" => "playbook-seen", "value" => ""})
    refute has_element?(view, "#details-panel")
    refute_push_event(view, "pref", %{key: "playbook-seen"})
    # ...until it is wide again, when the run gets its look
    render_hook(view, "pref", %{"key" => "channel-details", "value" => "", "media" => true})
    assert has_element?(view, "#details-panel #playbook-panel")
    assert_push_event(view, "pref", %{key: "playbook-seen", value: value})
    assert value == run.id
  end

  test "a thread open on arrival keeps the run unseen; Details opens on it once the slot is free",
       %{conn: conn} = ctx do
    run = start_run(ctx)
    {:ok, root} = Canopy.Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "A question")

    {:ok, view, _html} =
      live(conn, CanopyWeb.ChannelLive.thread_path(ctx.channel.id, root.id))

    render_hook(view, "pref", %{"key" => "channel-details", "value" => "open", "media" => true})
    render_hook(view, "pref", %{"key" => "playbook-seen", "value" => ""})
    assert has_element?(view, "#thread-panel")
    refute has_element?(view, "#details-panel")
    refute_push_event(view, "pref", %{key: "playbook-seen"})

    # the user opens Details: collapsed so far, as nothing marked it seen or open
    view |> element("#toggle-details") |> render_click()
    assert has_element?(view, "#details-panel")
    refute has_element?(view, "#playbook-panel")

    # the next time the run changes, with Details able to show it, it opens once
    send(view.pid, {:playbook_runs, :changed, ctx.channel.id})
    assert has_element?(view, "#details-panel #playbook-panel")
    assert_push_event(view, "pref", %{key: "playbook-seen", value: value})
    assert value == run.id
  end

  test "the coordinator can be reassigned from the panel", %{conn: conn} = ctx do
    run = start_run(ctx)
    {:ok, view, _html} = open(conn, ctx.channel)
    view |> element("#playbook-chip") |> render_click()

    view
    |> form("#reassign-coordinator-form", %{run_id: run.id, agent_id: ctx.dev.id})
    |> render_submit()

    assert Runs.get!(run.id).coordinator_agent_id == ctx.dev.id
    assert render(view) =~ "led by @#{ctx.dev.name}"
  end

  test "a watch shows in the Scheduled panel with what it watches and how it is doing",
       %{conn: conn} = ctx do
    {:ok, watch} =
      Schedules.create_watch(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        created_by_agent_id: ctx.agent.id,
        instruction: "Look at failed CI.",
        cron: "*/10 * * * *",
        next_run_at: DateTime.utc_now(),
        check: %{"source" => "ci_failures", "repo" => "acme/app", "branch" => "main"},
        check_state: %{
          "seen" => [],
          "fired" => 2,
          "last_checked_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -180)),
          "last_error" => "gh is not logged in: run `gh auth login` in a terminal"
        }
      })

    {:ok, view, _html} = open(conn, ctx.channel)
    view |> element("#toggle-details") |> render_click()
    assert has_element?(view, "#schedule-count", "1 active")
    view |> element("#edit-schedules") |> render_click()
    assert has_element?(view, "#watch-#{watch.id}", "watching failed CI on main in acme/app")
    assert has_element?(view, "#watch-#{watch.id}", "every 10 min")
    assert has_element?(view, "#watch-#{watch.id}", "checked 3m ago")
    assert has_element?(view, "#watch-#{watch.id}", "fired 2×")
    assert has_element?(view, "#watch-#{watch.id}-error", "gh is not logged in")

    # the agent page asks OpenCode for its agents and providers
    stub(Canopy.OpenCode.ClientMock, :agents, fn _dir, _opts -> {:ok, []} end)
    stub(Canopy.OpenCode.ClientMock, :providers, fn _opts -> {:ok, %{"providers" => []}} end)
    {:ok, agent_view, _html} = live(conn, ~p"/agents/#{ctx.agent.id}")
    assert has_element?(agent_view, "#watch-#{watch.id}", "watching failed CI on main")
  end
end
