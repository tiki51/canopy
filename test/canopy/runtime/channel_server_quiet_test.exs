defmodule Canopy.Runtime.ChannelServerQuietTest do
  @moduledoc """
  The "channel quiet" signal: once a run of turns is over (nothing in flight,
  queued, in line, or deferred, no lock wait, no playbook run in progress),
  the channel says so once on `"runtime:activity"`. Desktop notifications'
  "Work finished" rests on it. `config/test.exs` sets `:quiet_ms` to 0.
  """

  use Canopy.DataCase, async: false

  import Mox
  import Canopy.PlaybookHelpers, only: [playbook_fixture: 3]

  alias Canopy.{Fixtures, Locks, Messages, QuestionRequests, Runtime, Settings, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream
  alias Canopy.Playbooks.Runs

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    b = Fixtures.agent_fixture(%{name: "reviewer" <> Fixtures.unique_suffix()})
    scenario = Fixtures.scenario(members: [b])
    b_session = Fixtures.session_fixture(%{channel: scenario.channel, agent_id: b.id})
    Timeline.subscribe(scenario.channel.id)
    :ok = Runtime.subscribe_activity()

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :pending_questions, fn _dir, _opts -> {:ok, []} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, _body, _opts ->
      send(test_pid, {:prompted, sid})
      {:ok, ""}
    end)

    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)

    {:ok,
     Map.merge(scenario, %{
       pid: pid,
       b: b,
       a_sid: scenario.session.engine_session_id,
       b_session: b_session,
       b_sid: b_session.engine_session_id
     })}
  end

  defp emit(sid, type, data \\ %{}) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: type, session_id: sid, data: data}}
    )
  end

  defp start_owner_turn(ctx, text \\ "go") do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, text)
    sid = ctx.a_sid
    assert_receive {:prompted, ^sid}, 2_000
    sid
  end

  defp quiet(ctx) do
    channel_id = ctx.channel.id
    assert_receive {:channel_quiet, ^channel_id, info}, 2_000
    info
  end

  defp refute_quiet(ctx, timeout \\ 200) do
    channel_id = ctx.channel.id
    refute_receive {:channel_quiet, ^channel_id, _}, timeout
  end

  test "one turn ends: exactly one signal, for that turn", ctx do
    sid = start_owner_turn(ctx)
    refute_quiet(ctx, 50)
    emit(sid, :agent_completed)

    info = quiet(ctx)
    assert %{turns: 1, errors: 0, paused?: false, trigger: "user"} = info
    assert info.agent_ids == [ctx.agent.id]
    assert "run_" <> _ = info.run_id
    assert is_integer(info.duration_ms)
    refute_quiet(ctx)

    # the next run is a run of its own
    sid = start_owner_turn(ctx, "again")
    emit(sid, :agent_completed)
    assert quiet(ctx).run_id != info.run_id
  end

  test "two agents woken together with turns serialized: one signal after the second", ctx do
    {:ok, _} = Settings.update(%{serialize_turns: true})
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} @#{ctx.b.name} look")

    assert_receive {:prompted, first}, 2_000
    refute_receive {:prompted, _}, 100
    emit(first, :agent_completed)
    refute_quiet(ctx, 100)

    assert_receive {:prompted, second}, 2_000
    assert MapSet.new([first, second]) == MapSet.new([ctx.a_sid, ctx.b_sid])
    emit(second, :agent_completed)

    info = quiet(ctx)
    assert info.turns == 2
    assert Enum.sort(info.agent_ids) == Enum.sort([ctx.agent.id, ctx.b.id])
    refute_quiet(ctx)
  end

  test "a turn blocked on a question is not quiet; it is once answered and ended", ctx do
    sid = start_owner_turn(ctx)

    emit(sid, :question_required, %{
      request: %{
        "id" => "que_quiet",
        "sessionID" => sid,
        "questions" => [%{"question" => "Which port?", "options" => [%{"label" => "4100"}]}],
        "tool" => %{"messageID" => "msg_1", "callID" => "call_1"}
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
    assert Runtime.status(ctx.channel.id)[ctx.agent.id] == :awaiting_user
    refute_quiet(ctx)

    expect(OC, :reply_question, fn _dir, "que_quiet", _answers, _opts -> {:ok, true} end)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    {:ok, _} = Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["4100"]]})
    refute_quiet(ctx)

    emit(sid, :agent_completed)
    assert %{turns: 1} = quiet(ctx)
  end

  test "Stop all: no signal", ctx do
    sid = start_owner_turn(ctx)
    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    assert {:ok, %{aborted: 1}} = Runtime.stop_all(ctx.channel.id)
    assert_receive {:chatter, :stopped}, 1_000
    refute_quiet(ctx, 300)
  end

  test "the user aborting the only turn: no signal", ctx do
    sid = start_owner_turn(ctx)
    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    {:ok, _} = Runtime.abort(ctx.channel.id, ctx.agent.id)
    emit(sid, :agent_completed)

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "stopped"}}},
                   2_000

    refute_quiet(ctx, 300)
  end

  test "a chatter pause ends the run with paused?", ctx do
    # the user's turn and one agent wake fit the budget; a third turn does not
    {:ok, _} = Settings.update(%{chatter_pause: true, chatter_limit: 2})
    sid = start_owner_turn(ctx)

    # mid-turn, the owner asks the reviewer; the wake goes out when it ends
    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "@#{ctx.b.name} check")
    emit(sid, :agent_completed)
    b_sid = ctx.b_sid
    assert_receive {:prompted, ^b_sid}, 2_000
    refute_quiet(ctx, 50)

    # the reviewer answers back: a third turn would pass the budget
    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.b.id, "@#{ctx.agent.name} done")
    emit(b_sid, :agent_completed)
    assert_receive {:chatter, :paused}, 2_000

    assert %{paused?: true, turns: 2} = quiet(ctx)
  end

  test "a turn that errors is counted", ctx do
    sid = start_owner_turn(ctx)
    emit(sid, :agent_error, %{error: %{"name" => "Boom"}})
    assert %{turns: 1, errors: 1} = quiet(ctx)
  end

  test "a session waiting for a lock keeps the run open until it got the lock and finished",
       ctx do
    {:granted, _} = Locks.acquire_for_user(ctx.user, ctx.channel, "tests", "manual run")
    sid = start_owner_turn(ctx)

    {:ok, queued} =
      Canopy.MCPHelpers.call(Canopy.MCP.Tools.LockAcquire, %{name: "tests"}, ctx.session)

    assert queued =~ "in line"
    emit(sid, :agent_completed)
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    refute_quiet(ctx)

    # the user lets go: the lock passes to the owner, whose grant turn joins the run
    {:ok, _} = Locks.force_release(ctx.repository.id, "tests", ctx.user)
    assert_receive {:prompted, ^sid}, 2_000
    refute_quiet(ctx, 50)
    emit(sid, :agent_completed)

    assert %{turns: 2, trigger: "user"} = quiet(ctx)
  end

  test "a playbook run in progress keeps the run open until it ends", ctx do
    playbook = playbook_fixture("quiet-flow", [{"plan", "Plan", "coordinator"}], "")

    {:ok, run, _} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    sid = start_owner_turn(ctx)
    emit(sid, :agent_completed)
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    refute_quiet(ctx)

    {:ok, _, :cancelled} = Runs.cancel(run, :user, "enough")
    assert %{turns: 1} = quiet(ctx)
  end
end
