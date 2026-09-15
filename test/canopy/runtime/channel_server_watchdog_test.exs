defmodule Canopy.Runtime.ChannelServerWatchdogTest do
  @moduledoc """
  A turn normally ends when OpenCode reports the session idle. When that event
  never arrives the turn would stay in flight forever and every later wake for
  that agent would queue behind it, which is what a channel that has stopped
  responding looks like from the outside.
  """

  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{AgentSessions, Fixtures, QuestionRequests, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()
    Timeline.subscribe(scenario.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :pending_questions, fn _dir, _opts -> {:ok, []} end)
    Canopy.MCP.mark_registered(scenario.repository.id)
    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.put(scenario, :pid, pid)}
  end

  defp start_turn(ctx, prompts \\ 1) do
    test_pid = self()

    expect(OC, :prompt_async, prompts, fn _dir, _sid, body, _opts ->
      send(test_pid, {:prompted, body})
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive {:prompted, _}, 2_000
    ctx.session.engine_session_id
  end

  # Backdates the turn so it looks both past the grace period and long silent.
  defp silence_turn(pid) do
    :sys.replace_state(pid, fn st ->
      %{
        st
        | turns:
            Map.new(st.turns, fn {k, t} ->
              {k,
               %{t | started_at: t.started_at - 600_000, last_event_at: t.last_event_at - 600_000}}
            end)
      }
    end)
  end

  defp tick(pid) do
    send(pid, :watchdog)
    :sys.get_state(pid)
  end

  test "a turn that goes quiet while OpenCode reports the session idle is finished", ctx do
    start_turn(ctx)
    silence_turn(ctx.pid)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)
    tick(ctx.pid)

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :idle}
    assert %{status: "idle"} = AgentSessions.get!(ctx.session.id)
  end

  test "messages that queued behind the orphaned turn are delivered once it is reaped", ctx do
    # one prompt for the turn that wedges, one for the queued message after it
    start_turn(ctx, 2)

    # arrives while the turn is still in flight, so it queues
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "are you there?")
    refute_receive {:prompted, _}, 200

    silence_turn(ctx.pid)
    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)
    tick(ctx.pid)

    assert_receive {:prompted, body}, 2_000
    assert body |> inspect() =~ "are you there?"
  end

  test "a turn OpenCode still reports busy is left alone", ctx do
    sid = start_turn(ctx)
    silence_turn(ctx.pid)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{sid => %{"type" => "busy"}}} end)
    tick(ctx.pid)

    refute_received {:timeline, %{event_type: "agent_turn_completed"}}
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  test "a turn blocked on an unanswered question is left alone", ctx do
    sid = start_turn(ctx)
    silence_turn(ctx.pid)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)

    expect(OC, :pending_questions, fn _dir, _opts ->
      {:ok, [%{"id" => "que_1", "sessionID" => sid, "questions" => [question()]}]}
    end)

    tick(ctx.pid)

    refute_received {:timeline, %{event_type: "agent_turn_completed"}}
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  test "a turn still busy is not reconciled at all while its events keep arriving", ctx do
    sid = start_turn(ctx)

    # a fresh turn has not gone quiet, so the watchdog does not call OpenCode
    emit(sid, :tool_started, %{call_id: "c1", tool: "read", status: :running, input: %{}})
    tick(ctx.pid)

    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  test "reaping an orphaned turn clears the phantom question card left behind", ctx do
    sid = start_turn(ctx)

    emit(sid, :question_required, %{
      request: %{"id" => "que_gone", "sessionID" => sid, "questions" => [question()]}
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
    assert [_] = QuestionRequests.pending_for_channel(ctx.channel.id)

    silence_turn(ctx.pid)

    # OpenCode has forgotten both the session and the question it was holding
    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)
    tick(ctx.pid)

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
  end

  # -- Retry loops -----------------------------------------------------------

  @retry %{"type" => "retry", "attempt" => 10, "message" => "The usage limit has been reached"}

  test "a turn the engine has been retrying for too long is ended with a note", ctx do
    sid = start_turn(ctx)
    emit(sid, :agent_status, %{status: :retry, raw: @retry})
    # the retry notices have spaced out: the turn looks quiet
    silence_turn(ctx.pid)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{sid => @retry}} end)
    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    tick(ctx.pid)

    assert_receive {:timeline, %{event_type: "agent_error", payload: %{"reason" => reason}}},
                   2_000

    assert reason ==
             "opencode was still retrying after 10 attempts: The usage limit has been reached"

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "error"}}},
                   2_000

    assert_receive {:timeline, %{event_type: "message", message: %{kind: "system", body: body}}},
                   2_000

    assert body =~ "Ended #{ctx.agent.name}'s turn"
    assert body =~ "The usage limit has been reached"
    assert body =~ "Mention the agent again"

    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :idle}
    assert %{status: "error", last_error: ^reason} = AgentSessions.get!(ctx.session.id)
  end

  test "a long retry loop is ended even while its retry notices keep the turn fresh", ctx do
    sid = start_turn(ctx)
    emit(sid, :agent_status, %{status: :retry, raw: @retry})

    :sys.replace_state(ctx.pid, fn st ->
      %{
        st
        | turns:
            Map.new(st.turns, fn {k, t} ->
              {k, %{t | retrying: %{t.retrying | since: t.retrying.since - 600_000}}}
            end)
      }
    end)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{sid => @retry}} end)
    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    tick(ctx.pid)

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    assert_receive {:timeline, %{event_type: "message", message: %{kind: "system"}}}, 2_000
  end

  test "a retry that only just began is left to the engine", ctx do
    sid = start_turn(ctx)
    emit(sid, :agent_status, %{status: :retry, raw: Map.put(@retry, "attempt", 1)})
    stub(OC, :session_status, fn _dir, _opts -> {:ok, %{sid => @retry}} end)

    tick(ctx.pid)

    refute_received {:timeline, %{event_type: "agent_turn_completed"}}
    refute_received {:timeline, %{event_type: "message", message: %{kind: "system"}}}
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  test "a retry that went through clears the clock", ctx do
    sid = start_turn(ctx)
    emit(sid, :agent_status, %{status: :retry, raw: @retry})
    emit(sid, :agent_status, %{status: :busy, raw: %{"type" => "busy"}})

    assert %{turns: turns} = :sys.get_state(ctx.pid)
    assert %{retrying: nil} = turns[sid]
  end

  defp question do
    %{
      "header" => "Mobile screenshots",
      "question" => "How should dense screenshots behave at 390px?",
      "options" => [%{"label" => "Keep as is", "description" => "Accept it."}]
    }
  end

  defp emit(sid, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: type, session_id: sid, data: data}}
    )
  end
end
