defmodule Canopy.Playbooks.StallTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Repo, Runtime, Timeline}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.EventStream
  alias Canopy.Playbooks.{Run, Runs, StallWorker}

  setup :set_mox_global

  setup do
    ctx = scenario()
    # after the repository fixture's own on_exit, so channel servers stop first
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    Timeline.subscribe(ctx.channel.id)
    ctx
  end

  defp start!(ctx, steps, extra \\ "") do
    playbook = playbook_fixture("slow-" <> unique_suffix(), steps, extra)

    {:ok, run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    run
  end

  # the run's last activity, moved into the past
  defp quiet_for(run, minutes) do
    at = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
    {1, _} = Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [last_activity_at: at])
  end

  defp drain_through(minutes),
    do:
      Oban.drain_queue(
        queue: :schedules,
        with_scheduled: DateTime.add(DateTime.utc_now(), minutes * 60, :second)
      )

  test "a quiet step gets one nudge, then none until activity resumes", ctx do
    run = start!(ctx, [{"plan", "Plan", "coordinator"}, {"do", "Do", "coordinator"}])
    assert_enqueued(worker: StallWorker, args: %{run_id: run.id})

    # nothing is due yet: the check finds the step busy enough and looks again later
    assert %{success: 1} = drain_through(31)
    refute_receive {:prompted, _, _}, 100
    assert_enqueued(worker: StallWorker, args: %{run_id: run.id})

    quiet_for(run, 31)
    assert %{success: 1} = drain_through(31)

    assert_receive {:prompted, _sid, body}, 2_000
    text = prompt_text(body)

    assert text =~
             "Run #{run.playbook_name} (#{run.id}) has been on step plan (\"Plan\") for 31 min"

    assert text =~ "check on it or pause the run"
    assert_receive {:timeline, %{event_type: "playbook_stalled", payload: %{"step" => "plan"}}}
    assert Runs.get!(run.id).nudged_at

    # one nudge per stall: no check is left to run
    refute_enqueued(worker: StallWorker, args: %{run_id: run.id})
    assert %{success: 0} = drain_through(120)

    # a coordinator turn (not the nudge's own) is activity: the clock starts again
    :ok = Runs.note_coordinator_turn(ctx.channel.id, ctx.agent.id)
    assert Runs.get!(run.id).nudged_at == nil
    assert_enqueued(worker: StallWorker, args: %{run_id: run.id})
  end

  test "a step change clears the nudge and restarts the clock", ctx do
    run = start!(ctx, [{"plan", "Plan", "coordinator"}, {"do", "Do", "coordinator"}])
    quiet_for(run, 40)
    drain_through(31)
    assert_receive {:prompted, _, _}, 2_000

    {:ok, run, {:step, "do"}} =
      Runs.advance(Runs.get!(run.id), {:agent, ctx.agent.id}, result: "ok")

    assert run.nudged_at == nil
    assert DateTime.diff(DateTime.utc_now(), run.last_activity_at) < 5
    assert_enqueued(worker: StallWorker, args: %{run_id: run.id})
  end

  test "never while the step waits on the user's approval", ctx do
    run =
      start!(ctx, [
        {"sign-off", "Sign-off", "coordinator", "approval: user"},
        {"wrap", "Wrap", "coordinator"}
      ])

    {:ok, run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "done?")
    quiet_for(run, 600)
    drain_through(700)

    refute_receive {:prompted, _, _}, 200
    refute_receive {:timeline, %{event_type: "playbook_stalled"}}
    assert Runs.get!(run.id).nudged_at == nil
  end

  test "stall_after: off means no checks at all", ctx do
    run = start!(ctx, [{"plan", "Plan", "coordinator"}], "stall_after: off\n")
    assert run.stall_after_minutes == nil
    refute_enqueued(worker: StallWorker, args: %{run_id: run.id})
  end

  test "the nudge counts against the chatter budget: a paused channel holds it", ctx do
    {:ok, _} = Canopy.Settings.update(%{chatter_limit: 1})
    run = start!(ctx, [{"plan", "Plan", "coordinator"}])
    {:ok, pid} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)

    # the user's message is one turn: the budget of one is spent
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "hello")
    sid = ctx.session.engine_session_id
    assert_receive {:prompted, ^sid, _}, 2_000

    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event,
       %Event{type: :agent_completed, session_id: sid, data: %{}, raw_type: "test"}}
    )

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000

    quiet_for(run, 31)
    drain_through(31)
    assert_receive {:timeline, %{event_type: "playbook_stalled"}}, 2_000
    _ = :sys.get_state(pid)
    refute_receive {:prompted, _, _}, 200
    assert Runtime.paused?(ctx.channel.id)
  end

  # 25
  test "boot reconciles a run that lost its stall check", ctx do
    run = start!(ctx, [{"plan", "Plan", "coordinator"}])
    Repo.delete_all(from j in Oban.Job, where: j.worker == "Canopy.Playbooks.StallWorker")
    refute_enqueued(worker: StallWorker, args: %{run_id: run.id})

    StallWorker.reconcile()
    assert_enqueued(worker: StallWorker, args: %{run_id: run.id})
  end

  # 25
  test "a failed insert of the next check fails the job, so Oban retries it" do
    assert StallWorker.after_enqueue({:error, :db_busy}) == {:error, :db_busy}
    assert StallWorker.after_enqueue({:ok, %Oban.Job{}}) == :ok
    assert StallWorker.after_enqueue(:ok) == :ok
  end
end
