defmodule Canopy.Runtime.ChannelServerPlaybooksTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.PlaybookHelpers

  alias Canopy.{Fixtures, Repo, Runtime, Timeline}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream
  alias Canopy.Playbooks.{Run, Runs}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
    ctx = Fixtures.scenario(members: [reviewer])
    reviewer_session = Fixtures.session_fixture(%{channel: ctx.channel, agent_id: reviewer.id})
    Timeline.subscribe(ctx.channel.id)
    stub_engine(self(), ctx.repository)
    {:ok, pid} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)

    playbook =
      playbook_fixture(
        "review-flow",
        [{"plan", "Plan", "coordinator"}, {"review", "Review", "rev"}],
        "roles:\n  rev: #{reviewer.name}\n"
      )

    {:ok, run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    Map.merge(ctx, %{reviewer: reviewer, reviewer_session: reviewer_session, pid: pid, run: run})
  end

  defp emit(sid, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Event{type: type, session_id: sid, data: data, raw_type: "test"}}
    )
  end

  test "the run's note rides on the coordinator's prompts only", ctx do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "how is it going?")
    owner_sid = ctx.session.engine_session_id
    assert_receive {:prompted, ^owner_sid, body}, 2_000

    assert prompt_text(body) =~
             "Playbook in progress here: review-flow (run #{ctx.run.id}), step 1 of 2 \"Plan\", yours to do; you coordinate it."

    # the note is in the wake text, never the cached system text
    refute body.system =~ "Playbook in progress here"
    emit(owner_sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.reviewer.name} please look")
    reviewer_sid = ctx.reviewer_session.engine_session_id
    assert_receive {:prompted, ^reviewer_sid, body}, 2_000
    refute prompt_text(body) =~ "Playbook in progress"
  end

  test "the note still comes after the coordinator's session is compacted", ctx do
    test_pid = self()
    sid = ctx.session.engine_session_id

    {:ok, _} =
      Canopy.Agents.update(ctx.agent, %{model_provider: "opencode", model_id: "gpt-5-nano"})

    expect(OC, :summarize, fn _dir, ^sid, _model, _opts ->
      send(test_pid, :compacted)
      {:ok, true}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive {:prompted, ^sid, _}, 2_000

    emit(sid, :step_completed, %{
      part_id: "s1",
      reason: "stop",
      cost: 0.02,
      tokens: %{"input" => 5_000, "output" => 80, "cache" => %{"read" => 40_000}}
    })

    emit(sid, :agent_completed, %{})
    assert_receive :compacted, 2_000
    assert_receive {:timeline, %{event_type: "session_compacted"}}, 2_000

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "and now?")
    assert_receive {:prompted, ^sid, body}, 2_000
    assert prompt_text(body) =~ "Playbook in progress here: review-flow (run #{ctx.run.id})"
  end

  test "a coordinator's turn is run activity; the turn a nudge starts is not", ctx do
    old = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
      set: [last_activity_at: old, nudged_at: old]
    )

    # the nudge's own turn leaves the nudge in place
    Runtime.wake_playbook(ctx.channel.id, ctx.agent.id, "nudge",
      reset: false,
      trigger: "playbook_nudge"
    )

    sid = ctx.session.engine_session_id
    assert_receive {:prompted, ^sid, _}, 2_000
    _ = :sys.get_state(ctx.pid)
    assert Runs.get!(ctx.run.id).nudged_at
    emit(sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000

    # any other turn of the coordinator is activity
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "status?")
    assert_receive {:prompted, ^sid, _}, 2_000
    _ = :sys.get_state(ctx.pid)
    run = Runs.get!(ctx.run.id)
    assert run.nudged_at == nil
    assert DateTime.compare(run.last_activity_at, old) == :gt
  end

  # 19
  test "automation wakes merged behind a busy turn keep every text", ctx do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "work on it")
    sid = ctx.session.engine_session_id
    assert_receive {:prompted, ^sid, _}, 2_000

    # while the turn runs, a watch wake, then an approval wake, then a message
    Runtime.wake_playbook(ctx.channel.id, ctx.agent.id, "WATCH: pr:12 is new", trigger: "watch")
    Runtime.wake_playbook(ctx.channel.id, ctx.agent.id, "APPROVED: sign-off")
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "and one more thing")
    _ = :sys.get_state(ctx.pid)

    emit(sid, :agent_completed, %{})
    assert_receive {:prompted, ^sid, body}, 2_000
    text = prompt_text(body)
    assert text =~ "WATCH: pr:12 is new"
    assert text =~ "APPROVED: sign-off"
    assert text =~ "and one more thing"
  end

  # 24 (a nudge that waited behind a turn is dropped once the run moved on)
  test "a queued nudge for a step the run left is not sent", ctx do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "busy")
    sid = ctx.session.engine_session_id
    assert_receive {:prompted, ^sid, _}, 2_000

    step = Runs.current_step(ctx.run)

    Runtime.wake_playbook(ctx.channel.id, ctx.agent.id, "NUDGE",
      reset: false,
      trigger: "playbook_nudge",
      check: {ctx.run.id, step.step_id, step.round}
    )

    _ = :sys.get_state(ctx.pid)
    {:ok, _, _} = Runs.advance(Runs.get!(ctx.run.id), {:agent, ctx.agent.id}, result: "done")

    emit(sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    _ = :sys.get_state(ctx.pid)
    refute_receive {:prompted, _, _}, 300
  end
end
