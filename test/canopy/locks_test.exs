defmodule Canopy.LocksTest do
  use Canopy.DataCase, async: false

  alias Canopy.{AgentSessions, Agents, Channels, Locks, QuestionRequests, Timeline}
  alias Canopy.Fixtures
  alias Canopy.Locks.Claim

  setup do
    b = Fixtures.agent_fixture()
    c = Fixtures.agent_fixture()
    scenario = Fixtures.scenario(members: [b, c])
    session_b = Fixtures.session_fixture(%{channel: scenario.channel, agent_id: b.id})
    session_c = Fixtures.session_fixture(%{channel: scenario.channel, agent_id: c.id})
    Locks.subscribe(scenario.repository.id)
    Timeline.subscribe(scenario.channel.id)

    Map.merge(scenario, %{
      b: b,
      c: c,
      a_session: scenario.session,
      b_session: session_b,
      c_session: session_c
    })
  end

  defp acquire(ctx, session, opts \\ []),
    do:
      Locks.acquire(
        session,
        ctx.repository.id,
        Keyword.get(opts, :name, "tests"),
        "a reason",
        opts
      )

  defp backdate(claim, ms) do
    at = DateTime.add(DateTime.utc_now(), -ms, :millisecond)
    Repo.update_all(from(c in Claim, where: c.id == ^claim.id), set: [granted_at: at])
  end

  describe "acquire" do
    test "grants a free lock and queues the next sessions in order", ctx do
      assert {:granted, held} = acquire(ctx, ctx.a_session)
      assert held.status == "held"
      assert held.name == "tests"
      assert held.granted_at
      assert_receive {:timeline, %{event_type: "lock_granted", payload: %{"promoted" => false}}}
      assert_receive {:locks_changed, _}

      assert {:queued, b_claim, 1, holder} = acquire(ctx, ctx.b_session)
      assert holder.id == held.id
      assert b_claim.status == "waiting"
      assert_receive {:timeline, %{event_type: "lock_queued", payload: %{"position" => 1}}}

      assert {:queued, _c_claim, 2, _} = acquire(ctx, ctx.c_session)
    end

    test "asking again is idempotent: the holder is told it holds it, a waiter its place", ctx do
      {:granted, held} = acquire(ctx, ctx.a_session)
      {:queued, waiting, 1, _} = acquire(ctx, ctx.b_session)
      assert_receive {:timeline, %{event_type: "lock_granted"}}
      assert_receive {:timeline, %{event_type: "lock_queued"}}

      assert {:already_held, again} = acquire(ctx, ctx.a_session)
      assert again.id == held.id
      assert {:queued, same, 1, _} = acquire(ctx, ctx.b_session)
      assert same.id == waiting.id
      refute_receive {:timeline, %{event_type: "lock_" <> _}}
      assert Repo.aggregate(Claim, :count) == 2
    end

    test "names are normalised, and bad ones are refused", ctx do
      assert {:granted, claim} =
               Locks.acquire(ctx.a_session, ctx.repository.id, "  Ports:4100 ", nil)

      assert claim.name == "ports:4100"
      assert {:error, reason} = Locks.acquire(ctx.a_session, ctx.repository.id, "two words", nil)
      assert reason =~ "lock name"
      assert {:error, _} = Locks.acquire(ctx.a_session, ctx.repository.id, nil, nil)
    end

    test "the partial unique index allows one holder", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)

      changeset =
        Claim.changeset(%Claim{}, %{
          repository_id: ctx.repository.id,
          name: "tests",
          session_id: ctx.b_session.id,
          channel_id: ctx.channel.id,
          status: "held"
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert {"has already been taken", _} = changeset.errors[:repository_id]
    end

    test "two sessions asking at once: exactly one is granted", ctx do
      results =
        [ctx.b_session, ctx.c_session]
        |> Enum.map(fn session -> Task.async(fn -> acquire(ctx, session) end) end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:granted, _}, &1)) == 1
      assert Enum.count(results, &match?({:queued, _, 1, _}, &1)) == 1
    end

    test "a lock taken by another repository's session does not block this one", ctx do
      other = Fixtures.scenario()
      {:granted, _} = Locks.acquire(other.session, other.repository.id, "tests", nil)
      assert {:granted, _} = acquire(ctx, ctx.a_session)
    end

    test "a re-acquire in a turn takes over a grant no turn owns yet", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      {:queued, _, 1, _} = acquire(ctx, ctx.b_session)
      {:ok, :released, promoted} = Locks.release(ctx.a_session, ctx.repository.id, "tests")
      assert promoted.turn_ref == nil

      assert {:already_held, claim} = acquire(ctx, ctx.b_session, turn_ref: "turn_now")
      assert claim.turn_ref == "turn_now"
    end
  end

  describe "release" do
    test "releasing the holder promotes the oldest waiter and announces it", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      {:queued, b_claim, 1, _} = acquire(ctx, ctx.b_session)
      {:queued, _, 2, _} = acquire(ctx, ctx.c_session)

      assert {:ok, :released, next} =
               Locks.release(ctx.a_session, ctx.repository.id, "tests", "shots are in out/")

      assert next.id == b_claim.id
      assert next.status == "held"
      assert next.turn_ref == nil
      assert next.granted_at

      assert_receive {:lock_granted, %Claim{id: id}} when id == b_claim.id

      assert_receive {:timeline,
                      %{
                        event_type: "lock_released",
                        payload: %{"released_by" => "agent", "note" => "shots are in out/"}
                      }}

      assert_receive {:timeline, %{event_type: "lock_granted", payload: %{"promoted" => true}}}

      [lock] = Locks.list(ctx.repository.id)
      assert lock.holder.id == b_claim.id
      assert [%{session_id: c_id}] = lock.queue
      assert c_id == ctx.c_session.id
    end

    test "a waiter leaves the line without touching the holder", ctx do
      {:granted, held} = acquire(ctx, ctx.a_session)
      {:queued, _, 1, _} = acquire(ctx, ctx.b_session)

      assert {:ok, :left_queue, nil} = Locks.release(ctx.b_session, ctx.repository.id, "tests")
      assert [%{holder: %{id: id}, queue: []}] = Locks.list(ctx.repository.id)
      assert id == held.id
      refute_receive {:lock_granted, _}
    end

    test "releasing what you do not have is not_found", ctx do
      assert {:error, :not_found} = Locks.release(ctx.a_session, ctx.repository.id, "tests")
    end

    test "the last claim gone, the lock is gone", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      {:ok, :released, nil} = Locks.release(ctx.a_session, ctx.repository.id, "tests")
      assert Locks.list(ctx.repository.id) == []
    end
  end

  describe "release_turn" do
    test "releases only what the ending turn owns", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session, turn_ref: "turn_a")

      {:granted, kept} =
        acquire(ctx, ctx.a_session, name: "e2e", turn_ref: "turn_a", hold_across_turns: true)

      {:granted, other} = acquire(ctx, ctx.a_session, name: "ports:4100", turn_ref: "turn_old")

      assert [] = Locks.release_turn(ctx.a_session.id, "turn_a")

      names = ctx.a_session.id |> Locks.for_session() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == Enum.sort([kept.name, other.name])
    end

    test "a claim granted from the line is not released by a turn that started before it", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session, turn_ref: "turn_a")
      {:queued, _, 1, _} = acquire(ctx, ctx.b_session, turn_ref: "turn_b1")

      assert [promoted] = Locks.release_turn(ctx.a_session.id, "turn_a")
      assert promoted.session_id == ctx.b_session.id

      # B's turn that queued ends: the grant is not its own
      assert [] = Locks.release_turn(ctx.b_session.id, "turn_b1")
      assert [%{status: "held"}] = Locks.for_session(ctx.b_session.id)

      # the turn the grant wake starts owns it, and releases it when it ends
      :ok = Locks.stamp_turn(ctx.b_session.id, [promoted.id], "turn_b2")
      assert [] = Locks.pending_grants(ctx.b_session.id, [promoted.id])
      Locks.release_turn(ctx.b_session.id, "turn_b2")
      assert Locks.list(ctx.repository.id) == []
    end

    test "a nil turn releases nothing", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      assert [] = Locks.release_turn(ctx.a_session.id, nil)
      assert [_] = Locks.for_session(ctx.a_session.id)
    end
  end

  describe "release_session and friends" do
    test "drops held and waiting claims, promoting the next", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session, hold_across_turns: true)
      {:granted, _} = acquire(ctx, ctx.b_session, name: "e2e")
      {:queued, _, 1, _} = acquire(ctx, ctx.a_session, name: "e2e")
      {:queued, _, 1, _} = acquire(ctx, ctx.c_session)

      [promoted] = Locks.release_session(ctx.a_session.id)
      assert promoted.session_id == ctx.c_session.id
      assert Locks.for_session(ctx.a_session.id) == []

      assert_receive {:timeline,
                      %{event_type: "lock_released", payload: %{"released_by" => "reset"}}}
    end

    test "deleting a session releases its claims first, so the lock passes on", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      {:queued, waiting, 1, _} = acquire(ctx, ctx.b_session)

      {:ok, _} = AgentSessions.delete(ctx.a_session)

      assert_receive {:lock_granted, %Claim{id: id}} when id == waiting.id
      assert [%{holder: %{id: ^id}}] = Locks.list(ctx.repository.id)
    end

    test "removing an agent from the channel releases its claims there", ctx do
      {:granted, _} = acquire(ctx, ctx.b_session)
      {:ok, 1} = Channels.remove_agent(ctx.channel, ctx.b)
      assert Locks.list(ctx.repository.id) == []
    end

    test "deactivating an agent releases its claims everywhere", ctx do
      {:granted, _} = acquire(ctx, ctx.c_session)
      {:ok, _} = Agents.deactivate(ctx.c)
      assert Locks.list(ctx.repository.id) == []
    end
  end

  describe "expire" do
    test "a grant an idle session never used passes on after the grace period", ctx do
      {:granted, held} = acquire(ctx, ctx.a_session)
      {:queued, waiting, 1, _} = acquire(ctx, ctx.b_session)
      backdate(held, Locks.grant_grace_ms() + 1_000)

      # still working: kept
      assert [] = Locks.expire(channel_id: ctx.channel.id, active_session_ids: [ctx.a_session.id])

      # idle: passed on
      assert [%{id: id}] = Locks.expire(channel_id: ctx.channel.id, active_session_ids: [])
      assert id == waiting.id

      assert_receive {:timeline,
                      %{
                        event_type: "lock_released",
                        payload: %{"released_by" => "lease", "note" => note}
                      }}

      assert note =~ "not used"
    end

    test "a fresh grant is kept", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      assert [] = Locks.expire(channel_id: ctx.channel.id, active_session_ids: [])
      assert [_] = Locks.list(ctx.repository.id)
    end

    test "a hold across turns is kept past the grace period, and released after the lease", ctx do
      {:granted, held} = acquire(ctx, ctx.a_session, hold_across_turns: true)
      backdate(held, Locks.grant_grace_ms() + 1_000)
      assert [] = Locks.expire(channel_id: ctx.channel.id, active_session_ids: [])
      assert [_] = Locks.list(ctx.repository.id)

      backdate(held, Canopy.Settings.lock_hold_ms() + 1_000)
      Locks.expire(channel_id: ctx.channel.id, active_session_ids: [ctx.a_session.id])
      assert Locks.list(ctx.repository.id) == []
    end

    test "only the given channel's claims are expired", ctx do
      other =
        Fixtures.channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: ctx.b.id})

      session = Fixtures.session_fixture(%{channel: other, agent_id: ctx.b.id})
      {:granted, held} = Locks.acquire(session, ctx.repository.id, "tests", nil)
      backdate(held, Locks.grant_grace_ms() + 1_000)

      assert [] = Locks.expire(channel_id: ctx.channel.id, active_session_ids: [])
      assert [_] = Locks.list(ctx.repository.id)
    end

    test "a line left without a holder promotes its first waiter", ctx do
      {:granted, held} = acquire(ctx, ctx.a_session)
      {:queued, waiting, 1, _} = acquire(ctx, ctx.b_session)
      # the holder's row vanished without a release (a deleted channel or agent)
      Repo.delete_all(from c in Claim, where: c.id == ^held.id)

      assert [%{id: id}] = Locks.expire(channel_id: ctx.channel.id, active_session_ids: [])
      assert id == waiting.id
    end
  end

  test "at boot, held claims go (except holds across turns) and waiters are promoted", ctx do
    {:granted, _} = acquire(ctx, ctx.a_session, turn_ref: "turn_gone")
    {:queued, waiting, 1, _} = acquire(ctx, ctx.b_session)
    {:granted, kept} = acquire(ctx, ctx.c_session, name: "e2e", hold_across_turns: true)

    assert Locks.release_on_boot() == [ctx.channel.id]

    locks = Map.new(Locks.list(ctx.repository.id), &{&1.name, &1})
    assert locks["tests"].holder.id == waiting.id
    assert locks["tests"].holder.turn_ref == nil
    assert locks["e2e"].holder.id == kept.id

    assert_receive {:timeline,
                    %{event_type: "lock_released", payload: %{"released_by" => "restart"}}}
  end

  describe "the user" do
    test "takes a free lock by hand and releases it", ctx do
      assert {:granted, claim} =
               Locks.acquire_for_user(ctx.user, ctx.channel, "tests", "testing by hand")

      assert claim.user_id == ctx.user.id
      assert Locks.holder_name(claim) == ctx.user.display_name

      assert {:already_held, _} = Locks.acquire_for_user(ctx.user, ctx.channel, "tests", nil)
      assert {:queued, _, 1, holder} = acquire(ctx, ctx.a_session)
      assert holder.id == claim.id

      assert {:ok, next} = Locks.force_release(ctx.repository.id, "tests", ctx.user)
      assert next.session_id == ctx.a_session.id
    end

    test "cannot take a lock someone holds", ctx do
      {:granted, held} = acquire(ctx, ctx.a_session)

      assert {:error, {:held, holder}} =
               Locks.acquire_for_user(ctx.user, ctx.channel, "tests", nil)

      assert holder.id == held.id
    end

    test "force-releases an agent's lock, with a note on the event", ctx do
      {:granted, _} = acquire(ctx, ctx.a_session)
      assert {:ok, nil} = Locks.force_release(ctx.repository.id, "tests", ctx.user)

      assert_receive {:timeline,
                      %{
                        event_type: "lock_released",
                        payload: %{"released_by" => "user", "note" => note}
                      }}

      assert note =~ "force-released"
      assert {:error, :not_found} = Locks.force_release(ctx.repository.id, "tests", ctx.user)
    end
  end

  test "list marks a holder whose turn waits on the user", ctx do
    {:granted, _} = acquire(ctx, ctx.a_session)
    refute hd(Locks.list(ctx.repository.id)).awaiting_user?

    {:ok, _} =
      QuestionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.a_session.id,
        opencode_question_id: "que_1",
        questions: [%{"question" => "Which key?", "options" => []}],
        status: "pending"
      })

    assert hd(Locks.list(ctx.repository.id)).awaiting_user?
  end

  test "age and holder names read well", ctx do
    {:granted, claim} = acquire(ctx, ctx.a_session)
    assert Locks.age(claim) == "<1m"
    assert Locks.age(claim, DateTime.add(claim.granted_at, 6 * 60 + 5, :second)) == "6m"
    assert Locks.age(claim, DateTime.add(claim.granted_at, 125 * 60, :second)) == "2h 5m"
    assert Locks.holder_name(claim) == "@" <> ctx.agent.name
  end
end
