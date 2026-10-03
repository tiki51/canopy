defmodule Canopy.Runtime.ChannelServerLocksTest do
  @moduledoc """
  Locks in the runtime: a claim belongs to the turn that holds it and is
  released however that turn ends; a lock that passes to a waiting session
  wakes that exact session through the normal wake path, and the turn the
  wake starts owns the claim.
  """

  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Fixtures, Locks, Runtime, Settings, Timeline}
  alias Canopy.Locks.Claim
  alias Canopy.MCP.Tools.LockAcquire
  alias Canopy.MCPHelpers
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    b = Fixtures.agent_fixture(%{name: "fullstack" <> Fixtures.unique_suffix()})
    c = Fixtures.agent_fixture(%{name: "frontend" <> Fixtures.unique_suffix()})
    scenario = Fixtures.scenario(members: [b, c])
    b_session = Fixtures.session_fixture(%{channel: scenario.channel, agent_id: b.id})
    c_session = Fixtures.session_fixture(%{channel: scenario.channel, agent_id: c.id})
    Timeline.subscribe(scenario.channel.id)
    Locks.subscribe(scenario.repository.id)

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :pending_questions, fn _dir, _opts -> {:ok, []} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, prompt_text(body)})
      {:ok, ""}
    end)

    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)

    {:ok,
     Map.merge(scenario, %{
       pid: pid,
       b: b,
       c: c,
       a_session: scenario.session,
       b_session: b_session,
       c_session: c_session
     })}
  end

  defp prompt_text(%{parts: [%{text: text} | _]}), do: text

  defp emit(sid, type, data \\ %{}) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: type, session_id: sid, data: data}}
    )
  end

  # the way an agent takes a lock: the MCP tool, as the session
  defp acquire(session, opts \\ %{}),
    do: MCPHelpers.call(LockAcquire, Map.merge(%{name: "tests"}, Map.new(opts)), session)

  defp holder(ctx) do
    case Locks.get(ctx.repository.id, "tests") do
      nil -> nil
      lock -> lock.holder
    end
  end

  defp sync(pid), do: :sys.get_state(pid)

  defp backdate(claim_id, ms) do
    at = DateTime.add(DateTime.utc_now(), -ms, :millisecond)
    Repo.update_all(from(c in Claim, where: c.id == ^claim_id), set: [granted_at: at])
  end

  defp start_owner_turn(ctx) do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "run the suite")
    sid = ctx.a_session.engine_session_id
    assert_receive {:prompted, ^sid, _}, 2_000
    sid
  end

  defp ask(sid, id \\ "que_1") do
    emit(sid, :question_required, %{
      request: %{
        "id" => id,
        "sessionID" => sid,
        "questions" => [%{"question" => "Which port?", "options" => []}],
        "tool" => %{"messageID" => "msg_1", "callID" => "call_1"}
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
  end

  test "A holds, B queues, A's turn ends: B is woken with the grant, and its turn ending frees the lock",
       ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session, reason: "full suite")
    a_ref = Runtime.turn_ref(ctx.channel.id, ctx.a_session.id)
    assert holder(ctx).turn_ref == a_ref

    {:ok, queued} = acquire(ctx.b_session, reason: "precommit")
    assert queued =~ "You are 1st in line"

    emit(a_sid, :agent_completed)

    b_sid = ctx.b_session.engine_session_id
    assert_receive {:prompted, ^b_sid, text}, 2_000

    assert text =~
             "You now hold the `tests` lock in #{ctx.repository.name} (you asked for it: \"precommit\")."

    assert text =~ "It is released automatically when this turn ends"
    assert text =~ "The time now is"

    # the turn the grant started owns the claim
    b_ref = Runtime.turn_ref(ctx.channel.id, ctx.b_session.id)
    assert "turn_" <> _ = b_ref
    assert holder(ctx).session_id == ctx.b_session.id
    assert holder(ctx).turn_ref == b_ref

    emit(b_sid, :agent_completed)

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"trigger" => "lock"}}},
                   2_000

    sync(ctx.pid)
    assert Locks.list(ctx.repository.id) == []
    refute_receive {:prompted, _, _}, 200
  end

  test "B busy when the lock passes to it keeps the claim through its current turn", ctx do
    {:ok, _} = Settings.update(%{serialize_turns: false})
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.b.name} lint the site")
    b_sid = ctx.b_session.engine_session_id
    assert_receive {:prompted, ^b_sid, _}, 2_000
    {:ok, _} = acquire(ctx.b_session, reason: "e2e")
    b_ref1 = Runtime.turn_ref(ctx.channel.id, ctx.b_session.id)

    # the lock passes to B mid-turn: the grant wake queues behind it
    emit(a_sid, :agent_completed)
    assert_receive {:lock_granted, %Claim{session_id: session_id}}, 2_000
    assert session_id == ctx.b_session.id
    refute_receive {:prompted, _, _}, 200
    assert holder(ctx).turn_ref == nil

    # B's current turn ends: the claim is not its own, so it stays
    emit(b_sid, :agent_completed)
    assert_receive {:prompted, ^b_sid, text}, 2_000
    assert text =~ "You now hold the `tests` lock"
    b_ref2 = Runtime.turn_ref(ctx.channel.id, ctx.b_session.id)
    assert b_ref2 != b_ref1
    assert holder(ctx).turn_ref == b_ref2

    emit(b_sid, :agent_completed)
    sync(ctx.pid)
    assert Locks.list(ctx.repository.id) == []
  end

  test "a grant that joins another wake for the same session rides along on it", ctx do
    {:ok, _} = Settings.update(%{serialize_turns: false})
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.b.name} first job")
    b_sid = ctx.b_session.engine_session_id
    assert_receive {:prompted, ^b_sid, _}, 2_000
    {:ok, _} = acquire(ctx.b_session)

    emit(a_sid, :agent_completed)
    assert_receive {:lock_granted, _}, 2_000
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.b.name} and then the docs")
    sync(ctx.pid)

    emit(b_sid, :agent_completed)
    assert_receive {:prompted, ^b_sid, text}, 2_000
    assert text =~ "and then the docs"
    assert text =~ "You now hold the `tests` lock"
    refute_receive {:prompted, _, _}, 200

    emit(b_sid, :agent_completed)
    sync(ctx.pid)
    assert Locks.list(ctx.repository.id) == []
  end

  test "a lock re-acquired by the turn it passed to is used there, and the grant wake is dropped",
       ctx do
    {:ok, _} = Settings.update(%{serialize_turns: false})
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.b.name} lint the site")
    b_sid = ctx.b_session.engine_session_id
    assert_receive {:prompted, ^b_sid, _}, 2_000
    {:ok, _} = acquire(ctx.b_session)

    emit(a_sid, :agent_completed)
    assert_receive {:lock_granted, _}, 2_000
    sync(ctx.pid)

    # still in the same turn, B asks again and gets it at once
    {:ok, text} = acquire(ctx.b_session)
    assert text =~ "You already hold `tests`"

    emit(b_sid, :agent_completed)
    sync(ctx.pid)
    assert Locks.list(ctx.repository.id) == []
    refute_receive {:prompted, _, _}, 300
  end

  test "release on turn end is per session, across channels on the same repository", ctx do
    # a second channel on the repository, owned by C, with A in it too
    other =
      Fixtures.channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.c.id,
        agent_ids: [ctx.agent.id]
      })

    c_other = Fixtures.session_fixture(%{channel: other, agent_id: ctx.c.id})
    a_other = Fixtures.session_fixture(%{channel: other, agent_id: ctx.agent.id})
    {:ok, other_pid} = Runtime.ensure_channel(other.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(other.id) end)
    {:ok, _} = Settings.update(%{serialize_turns: false})

    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session, reason: "suite")

    # C, in the other channel, queues and ends its turn
    {:ok, _} = Runtime.post_user_message(other.id, "screenshots please")
    c_sid = c_other.engine_session_id
    assert_receive {:prompted, ^c_sid, _}, 2_000
    {:ok, text} = acquire(c_other, reason: "shots")
    assert text =~ "held by @#{ctx.agent.name} (in ##{ctx.channel.name})"
    emit(c_sid, :agent_completed)

    # A's session in the other channel ends a turn: A's claim here is not its own
    {:ok, _} = Runtime.post_user_message(other.id, "@#{ctx.agent.name} quick question")
    a_other_sid = a_other.engine_session_id
    assert_receive {:prompted, ^a_other_sid, _}, 2_000
    emit(a_other_sid, :agent_completed)
    sync(other_pid)
    assert holder(ctx).session_id == ctx.a_session.id

    # A's turn here ends: the other channel's server wakes C there
    emit(a_sid, :agent_completed)
    assert_receive {:prompted, ^c_sid, granted}, 2_000
    assert granted =~ "You now hold the `tests` lock"
    assert holder(ctx).session_id == c_other.id

    emit(c_sid, :agent_completed)
    sync(other_pid)
    assert Locks.list(ctx.repository.id) == []
  end

  test "a turn blocked on a card keeps its lock, shows it waits on the user, and frees it when it ends",
       ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)
    {:ok, _} = acquire(ctx.b_session)
    assert_receive {:locks_changed, _}

    ask(a_sid)
    assert_receive {:locks_changed, _}, 2_000
    lock = Locks.get(ctx.repository.id, "tests")
    assert lock.awaiting_user?
    assert lock.holder.session_id == ctx.a_session.id

    # nothing frees it while the turn waits, not even the lease
    backdate(lock.holder.id, Locks.grant_grace_ms() + 1_000)
    send(ctx.pid, :watchdog)
    sync(ctx.pid)
    assert holder(ctx).session_id == ctx.a_session.id

    # the turn ends (the card is detached): the lock passes on
    emit(a_sid, :agent_completed)
    b_sid = ctx.b_session.engine_session_id
    assert_receive {:prompted, ^b_sid, text}, 2_000
    assert text =~ "You now hold the `tests` lock"
  end

  test "a turn that errors releases its locks", ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)

    emit(a_sid, :agent_error, %{error: %{"name" => "APIError"}})
    assert_receive {:timeline, %{event_type: "agent_error"}}, 2_000
    sync(ctx.pid)
    assert Locks.list(ctx.repository.id) == []
  end

  test "a turn the user aborts releases its locks", ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)

    expect(OC, :abort, fn _dir, ^a_sid, _opts -> {:ok, true} end)
    {:ok, _} = Runtime.abort(ctx.channel.id, ctx.agent.id)
    emit(a_sid, :agent_error, %{error: %{"name" => "MessageAbortedError"}})

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "stopped"}}},
                   2_000

    sync(ctx.pid)
    assert Locks.list(ctx.repository.id) == []
  end

  test "Stop all releases what the channel's sessions hold and drops their places in line", ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)
    {:ok, _} = acquire(ctx.a_session, name: "e2e", hold_across_turns: true)
    {:ok, _} = acquire(ctx.b_session)

    expect(OC, :abort, fn _dir, ^a_sid, _opts -> {:ok, true} end)
    {:ok, _} = Runtime.stop_all(ctx.channel.id)

    assert Locks.list(ctx.repository.id) == []
    refute_receive {:prompted, _, _}, 200
  end

  test "a turn the watchdog finishes releases its locks", ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)

    :sys.replace_state(ctx.pid, fn st ->
      turns =
        Map.new(st.turns, fn {k, t} ->
          {k, %{t | started_at: t.started_at - 600_000, last_event_at: t.last_event_at - 600_000}}
        end)

      %{st | turns: turns}
    end)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)
    send(ctx.pid, :watchdog)
    sync(ctx.pid)

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    assert Locks.list(ctx.repository.id) == []
    refute Runtime.turn_ref(ctx.channel.id, ctx.a_session.id)
    _ = a_sid
  end

  test "resetting a session releases a lock held across turns and its places in line", ctx do
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session, hold_across_turns: true)
    emit(a_sid, :agent_completed)
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    assert holder(ctx).session_id == ctx.a_session.id

    {:ok, _} = acquire(ctx.b_session, name: "e2e")
    {:ok, _} = acquire(ctx.a_session, name: "e2e")

    assert :ok = Runtime.reset_session(ctx.channel.id, ctx.agent.id)

    assert [%{name: "e2e", holder: %{session_id: b_id}, queue: []}] =
             Locks.list(ctx.repository.id)

    assert b_id == ctx.b_session.id
  end

  test "the chatter pause holds the grant wake, and after the grace period the lease passes the lock on",
       ctx do
    {:ok, _} = Settings.update(%{chatter_pause: true, chatter_limit: 1})
    a_sid = start_owner_turn(ctx)
    {:ok, _} = acquire(ctx.a_session)
    {:ok, _} = acquire(ctx.b_session)
    {:ok, _} = acquire(ctx.c_session)

    emit(a_sid, :agent_completed)
    assert_receive {:chatter, :paused}, 2_000
    refute_receive {:prompted, _, _}, 200
    b_claim = holder(ctx)
    assert b_claim.session_id == ctx.b_session.id

    # a held wake is not on its way: the grant goes unused and passes on
    backdate(b_claim.id, Locks.grant_grace_ms() + 1_000)
    send(ctx.pid, :watchdog)
    sync(ctx.pid)

    assert_receive {:timeline,
                    %{event_type: "lock_released", payload: %{"released_by" => "lease"}}},
                   2_000

    assert holder(ctx).session_id == ctx.c_session.id

    # Continue: B's grant has nothing left to hand over; C's wake runs
    :ok = Runtime.continue(ctx.channel.id)
    c_sid = ctx.c_session.engine_session_id
    assert_receive {:prompted, ^c_sid, text}, 2_000
    assert text =~ "You now hold the `tests` lock"
    b_sid = ctx.b_session.engine_session_id
    refute_receive {:prompted, ^b_sid, _}, 200
  end

  test "a grant made while no server ran is woken when the channel's server starts", ctx do
    {:granted, _} =
      Locks.acquire(ctx.a_session, ctx.repository.id, "tests", nil, turn_ref: "turn_gone")

    {:queued, _, 1, _} = Locks.acquire(ctx.b_session, ctx.repository.id, "tests", "precommit")
    :ok = Runtime.stop_channel(ctx.channel.id)

    # at boot: the turn is gone, the waiter promoted, then the server starts
    [channel_id] = Locks.release_on_boot()
    assert channel_id == ctx.channel.id
    {:ok, _pid} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)

    b_sid = ctx.b_session.engine_session_id
    assert_receive {:prompted, ^b_sid, text}, 2_000
    assert text =~ "(you asked for it: \"precommit\")"
  end
end
