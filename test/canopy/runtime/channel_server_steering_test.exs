defmodule Canopy.Runtime.ChannelServerSteeringTest do
  @moduledoc """
  Agent Interrupt: a user's mention of a working agent goes into its turn
  (`Canopy.Engine.steer/4`) instead of queueing behind it, with OpenCode as
  the engine (Mox).
  """
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Fixtures, Messages, Runtime, Settings, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    {:ok, _} = Settings.update(%{interrupt_on_mention: true})
    reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
    scenario = Fixtures.scenario(members: [reviewer])
    Timeline.subscribe(scenario.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :pending_questions, fn _dir, _opts -> {:ok, []} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    # OpenCode lists the owner's session as busy while the test says so
    sid = scenario.session.engine_session_id

    stub(OC, :session_status, fn _dir, _opts ->
      {:ok, %{sid => %{"type" => "busy"}}}
    end)

    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{reviewer: reviewer, pid: pid, sid: sid})}
  end

  defp emit(sid, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: type, session_id: sid, data: data}}
    )
  end

  defp text_of(%{parts: [%{text: text} | _]}), do: text

  # The owner starts working on an unaddressed message (owner fallback).
  defp start_owner(ctx) do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    sid = ctx.sid
    assert_receive {:prompted, ^sid, _}, 2_000
    assert_receive {:timeline, %{event_type: "agent_started"}}, 2_000
    sid
  end

  defp mention_owner(ctx, text \\ "stop, use the other file", opts \\ []) do
    {:ok, message} =
      Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} #{text}", opts)

    message
  end

  defp steered!(ctx, message) do
    sid = ctx.sid
    assert_receive {:prompted, ^sid, body}, 2_000
    agent_id = ctx.agent.id
    message_id = message.id

    assert_receive {:timeline,
                    %{
                      event_type: "agent_interrupted",
                      agent_id: ^agent_id,
                      payload: %{"mode" => "next_step", "message_id" => ^message_id}
                    }},
                   2_000

    body
  end

  defp assert_queued(ctx) do
    refute_receive {:prompted, _, _}, 200
    refute_received {:timeline, %{event_type: "agent_interrupted"}}
    target = {:root, ctx.agent.id}
    assert [{^target, _}] = :sys.get_state(ctx.pid).waiting
  end

  test "a mention of the working agent goes into its turn at once", ctx do
    sid = start_owner(ctx)
    message = mention_owner(ctx)
    body = steered!(ctx, message)

    # the turn's prompt again, minus the sticky tools, behind the preface
    refute Map.has_key?(body, :tools)
    assert body.system =~ "Canopy"
    assert text_of(body) =~ "The user sent this while you were working"
    assert text_of(body) =~ "Message ID: #{message.id}"

    agent_id = ctx.agent.id
    message_id = message.id
    assert_receive {:steer, ^agent_id, %{pending: 1, held: 0, message_id: ^message_id}}, 2_000

    assert Runtime.steers(ctx.channel.id) == %{
             agent_id => %{
               pending: 1,
               held: 0,
               message_id: message_id,
               # the message the view marks Queued until the turn ends
               queued: %{message_id => false}
             }
           }

    state = :sys.get_state(ctx.pid)
    assert state.waiting == []
    assert Map.get(state.queues, sid, []) == []

    # the turn ends having read it (OpenCode cannot say otherwise): nothing is sent again
    emit(sid, :agent_completed, %{})

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "ok"} = payload}},
                   2_000

    assert payload["interrupted_by"] == [message.id]
    refute Map.has_key?(payload, "adopted")
    assert_receive {:steer, ^agent_id, nil}, 2_000
    refute_receive {:prompted, _, _}, 300
  end

  test "under one turn at a time, the working agent's mention steers while another agent waits",
       ctx do
    sid = start_owner(ctx)
    message = mention_owner(ctx)
    steered!(ctx, message)

    stub(OC, :create_session, fn _dir, _body, _opts -> {:ok, %{"id" => "ses_rev"}} end)
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.reviewer.name} you too")
    reviewer_id = ctx.reviewer.id
    assert_receive {:agent_status, ^reviewer_id, :queued}, 2_000
    refute_receive {:prompted, _, _}, 200

    emit(sid, :agent_completed, %{})
    assert_receive {:prompted, "ses_rev", _}, 2_000
  end

  test "a steer starts no turn, so it does not count against the chatter budget", ctx do
    {:ok, _} = Settings.update(%{chatter_limit: 1})
    start_owner(ctx)
    steered!(ctx, mention_owner(ctx))

    assert :sys.get_state(ctx.pid).chatter == 0
    refute_received {:chatter, :paused}
  end

  describe "queued as today" do
    test "an agent's mention of the working agent", ctx do
      start_owner(ctx)

      {:ok, _} =
        Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "@#{ctx.agent.name} look")

      assert_queued(ctx)
    end

    test "an unaddressed user message to the working owner", ctx do
      start_owner(ctx)
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "and another thing")
      assert_queued(ctx)
    end

    test "a message sent without interrupting (Alt+Enter)", ctx do
      start_owner(ctx)
      mention_owner(ctx, "later is fine", interrupt: false)
      assert_queued(ctx)
    end

    test "a message posted while the setting was off", ctx do
      start_owner(ctx)
      {:ok, _} = Settings.update(%{interrupt_on_mention: false})
      message = mention_owner(ctx)
      refute message.interrupt
      assert_queued(ctx)
    end

    test "a compaction turn", ctx do
      sid = start_owner(ctx)
      :sys.replace_state(ctx.pid, fn state -> put_in(state.turns[sid].trigger, "compact") end)
      mention_owner(ctx)
      assert_queued(ctx)
    end

    test "a mention from a thread while the agent works for the channel", ctx do
      start_owner(ctx)

      {:ok, root} =
        Messages.post_user_message(ctx.channel.id, ctx.user.id, "a side topic", interrupt: false)

      # the root itself wakes the owner (queued); the thread reply joins that wake
      {:ok, _} =
        Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} about this",
          thread_id: root.id
        )

      assert_queued(ctx)
    end
  end

  test "a mention in a thread steers a turn working in that thread", ctx do
    {:ok, root} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} look at this")
    sid = ctx.sid
    assert_receive {:prompted, ^sid, _}, 2_000

    # the turn started from a channel message: make it a thread turn by
    # starting a fresh one from a thread reply
    emit(sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000

    {:ok, _} =
      Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} in here please",
        thread_id: root.id
      )

    assert_receive {:prompted, ^sid, _}, 2_000

    {:ok, reply} =
      Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} and also this",
        thread_id: root.id
      )

    steered!(ctx, reply)
  end

  test "when OpenCode reports the session idle, the message queues and drains after the turn",
       ctx do
    stub(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)
    sid = start_owner(ctx)
    message = mention_owner(ctx)
    assert_queued(ctx)

    emit(sid, :agent_completed, %{})
    assert_receive {:prompted, ^sid, body}, 2_000
    assert text_of(body) =~ "Message ID: #{message.id}"
    refute text_of(body) =~ "while you were working"
  end

  test "a turn blocked on a card holds the message until the card is answered", ctx do
    sid = start_owner(ctx)

    emit(sid, :question_required, %{
      request: %{
        "id" => "que_1",
        "sessionID" => sid,
        "questions" => [%{"header" => "Key", "question" => "Which key?", "options" => []}],
        "tool" => %{"messageID" => "msg_1", "callID" => "call_1"}
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000

    message = mention_owner(ctx)
    agent_id = ctx.agent.id

    assert_receive {:timeline,
                    %{
                      event_type: "agent_interrupted",
                      payload: %{"held" => true, "mode" => "next_step"}
                    }},
                   2_000

    assert_receive {:steer, ^agent_id, %{pending: 1, held: 1}}, 2_000
    refute_receive {:prompted, _, _}, 200

    # answered (here, elsewhere): the turn works again and the message goes in
    emit(sid, :question_resolved, %{request_id: "que_1", answers: [["A"]]})
    assert_receive {:prompted, ^sid, body}, 2_000
    assert text_of(body) =~ "Message ID: #{message.id}"
    assert_receive {:steer, ^agent_id, %{pending: 1, held: 0}}, 2_000
  end

  test "a held message the turn never received goes out again when the turn ends", ctx do
    sid = start_owner(ctx)

    emit(sid, :question_required, %{
      request: %{
        "id" => "que_2",
        "sessionID" => sid,
        "questions" => [%{"header" => "Key", "question" => "Which key?", "options" => []}],
        "tool" => %{"messageID" => "msg_1", "callID" => "call_1"}
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
    message = mention_owner(ctx)
    assert_receive {:timeline, %{event_type: "agent_interrupted"}}, 2_000

    emit(sid, :agent_completed, %{})

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"interrupted_by" => []}}},
                   2_000

    assert_receive {:prompted, ^sid, body}, 2_000
    assert text_of(body) =~ "Your previous turn ended before you read this message"
    assert text_of(body) =~ "Message ID: #{message.id}"
  end

  describe "adoption" do
    test "a busy report soon after a steered turn ends becomes a turn of its own", ctx do
      sid = start_owner(ctx)
      steered!(ctx, mention_owner(ctx))
      emit(sid, :agent_completed, %{})
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000

      # the steer landed after the idle: OpenCode runs it on its own
      emit(sid, :agent_status, %{status: :busy, raw: %{}})
      assert_receive {:timeline, %{event_type: "agent_started"}}, 2_000

      emit(sid, :text_done, %{
        message_id: "m2",
        part_id: "p2",
        text: "Switched to the other file."
      })

      emit(sid, :agent_completed, %{})

      assert_receive {:timeline,
                      %{event_type: "agent_turn_completed", payload: %{"adopted" => true}}},
                     2_000

      assert_receive {:timeline,
                      %{
                        event_type: "message",
                        message: %{kind: "reply", body: "Switched to the other file."}
                      }},
                     2_000
    end

    test "nothing is adopted outside the window, or after a turn without steers", ctx do
      sid = start_owner(ctx)
      steered!(ctx, mention_owner(ctx))
      emit(sid, :agent_completed, %{})
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000

      :sys.replace_state(ctx.pid, fn state ->
        %{state | steered_ends: Map.new(state.steered_ends, fn {k, at} -> {k, at - 60_000} end)}
      end)

      emit(sid, :agent_status, %{status: :busy, raw: %{}})
      _ = :sys.get_state(ctx.pid)
      assert :sys.get_state(ctx.pid).turns == %{}

      # a turn that took no message mid-turn
      start_owner(ctx)
      emit(sid, :agent_completed, %{})
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
      emit(sid, :agent_status, %{status: :busy, raw: %{}})
      _ = :sys.get_state(ctx.pid)
      assert :sys.get_state(ctx.pid).turns == %{}
    end
  end

  test "Interrupt now aborts the turn, closes it as interrupted, and sends the message at once",
       ctx do
    sid = start_owner(ctx)
    agent_id = ctx.agent.id
    assert Runtime.interrupt_now(ctx.channel.id, agent_id) == {:error, :nothing_pending}

    message = mention_owner(ctx)
    steered!(ctx, message)

    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    assert :ok = Runtime.interrupt_now(ctx.channel.id, agent_id)

    assert_receive {:timeline, %{event_type: "agent_interrupted", payload: %{"mode" => "now"}}},
                   2_000

    # OpenCode reports the abort as an error
    emit(sid, :agent_error, %{error: %{"data" => %{"message" => "Aborted"}}})

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "interrupted"}}},
                   2_000

    refute_received {:timeline, %{event_type: "agent_error"}}
    assert_receive {:prompted, ^sid, body}, 2_000
    assert text_of(body) =~ "Your previous turn ended before you read this message"
    assert text_of(body) =~ "Message ID: #{message.id}"
    assert_receive {:timeline, %{event_type: "agent_started"}}, 2_000
  end

  test "Stop all drops a pending message and counts it", ctx do
    sid = start_owner(ctx)
    steered!(ctx, mention_owner(ctx))

    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    assert {:ok, %{aborted: 1, dropped: 1}} = Runtime.stop_all(ctx.channel.id)
    refute_receive {:prompted, _, _}, 300
  end

  test "Abort sends again a message the engine says the turn never read", ctx do
    sid = start_owner(ctx)
    message = mention_owner(ctx)
    steered!(ctx, message)
    [%{ref: ref}] = :sys.get_state(ctx.pid).turns[sid].steers

    emit(sid, :prompts_unconsumed, %{refs: [ref]})
    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    assert {:ok, true} = Runtime.abort(ctx.channel.id, ctx.agent.id)
    emit(sid, :agent_error, %{error: %{"data" => %{"message" => "Aborted"}}})

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "stopped"}}},
                   2_000

    assert_receive {:prompted, ^sid, body}, 2_000
    assert text_of(body) =~ "Your previous turn ended before you read this message"
    assert text_of(body) =~ "Message ID: #{message.id}"
  end

  test "a reaction while the agent works never steers or queues a turn", ctx do
    sid = start_owner(ctx)
    {:ok, post} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "Halfway there.")

    assert {:ok, :added} = Canopy.Reactions.add(post.id, {:user, ctx.user.id}, "eyes")
    assert_receive {:reactions, _}
    _ = :sys.get_state(ctx.pid)
    refute_received {:prompted, _, _}
    assert Runtime.steers(ctx.channel.id) == %{}

    # nothing was queued behind the turn either
    emit(sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    refute_receive {:prompted, _, _}, 300
  end
end
