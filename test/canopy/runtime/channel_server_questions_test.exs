defmodule Canopy.Runtime.ChannelServerQuestionsTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{
    AgentSessions,
    Delegations,
    Fixtures,
    Messages,
    PermissionRequests,
    QuestionRequests,
    Runtime,
    Timeline
  }

  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    helper = Fixtures.agent_fixture(%{name: "helper" <> Fixtures.unique_suffix()})
    scenario = Fixtures.scenario(members: [helper])
    Timeline.subscribe(scenario.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :pending_questions, fn _dir, _opts -> {:ok, []} end)
    Canopy.MCP.mark_registered(scenario.repository.id)
    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{pid: pid, helper: helper})}
  end

  defp start_turn(ctx) do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive :prompted, 2_000
    ctx.session.engine_session_id
  end

  defp emit(sid, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: type, session_id: sid, data: data}}
    )
  end

  defp ask(sid, id \\ "que_1") do
    emit(sid, :question_required, %{
      request: %{
        "id" => id,
        "sessionID" => sid,
        "questions" => [
          %{
            "header" => "Mobile screenshots",
            "question" => "How should dense screenshots behave at 390px?",
            "options" => [
              %{"label" => "Keep as is", "description" => "Accept unreadable UI text."},
              %{"label" => "Add mobile crops", "description" => "Focused close-ups."}
            ]
          }
        ],
        "tool" => %{"messageID" => "msg_1", "callID" => "call_1"}
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
  end

  test "a question an agent asks becomes a pending card without ending the turn", ctx do
    sid = start_turn(ctx)
    ask(sid)

    assert [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    assert request.opencode_question_id == "que_1"
    assert request.tool_call_id == "call_1"
    assert [%{"header" => "Mobile screenshots", "options" => [_, _]}] = request.questions

    # the agent is still blocked on the answer, waiting on the user
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :awaiting_user}
    assert %{status: "busy"} = AgentSessions.get!(ctx.session.id)
  end

  test "answering sends the chosen labels to OpenCode and resolves the card", ctx do
    sid = start_turn(ctx)
    ask(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    test_pid = self()

    expect(OC, :reply_question, fn _dir, "que_1", answers, _opts ->
      send(test_pid, {:answered, answers})
      {:ok, true}
    end)

    assert {:ok, _} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    assert_receive {:answered, [["Keep as is"]]}
    assert_receive {:timeline, %{event_type: "question_resolved", payload: payload}}, 2_000
    refute Map.has_key?(payload, "delivered")

    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
    assert %{status: "answered", answers: [["Keep as is"]]} = QuestionRequests.get!(request.id)

    # the answer went into the waiting tool call: the turn works on, no new prompt
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
    assert %{queues: queues} = :sys.get_state(ctx.pid)
    assert Map.get(queues, sid, []) == []
  end

  test "dismissing rejects the question with OpenCode", ctx do
    sid = start_turn(ctx)
    ask(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    expect(OC, :reject_question, fn _dir, "que_1", _opts -> {:ok, true} end)

    assert {:ok, _} = Runtime.respond_question(ctx.channel.id, request.id, :rejected)
    assert %{status: "rejected"} = QuestionRequests.get!(request.id)
  end

  test "a question OpenCode no longer holds is cleared locally rather than stranded", ctx do
    sid = start_turn(ctx)
    ask(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    expect(OC, :reject_question, fn _dir, "que_1", _opts ->
      {:error, {:http, 404, %{"_tag" => "QuestionNotFoundError"}}}
    end)

    assert {:ok, _} = Runtime.respond_question(ctx.channel.id, request.id, :rejected)
    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
  end

  test "a question answered in another OpenCode client resolves the card here too", ctx do
    sid = start_turn(ctx)
    ask(sid)

    emit(sid, :question_resolved, %{request_id: "que_1", answers: [["Add mobile crops"]]})
    assert_receive {:timeline, %{event_type: "question_resolved"}}, 2_000

    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
  end

  # -- Recording guard --------------------------------------------------------

  test "a question that cannot be recorded is rejected at once and the server stays up", ctx do
    sid = start_turn(ctx)
    test_pid = self()

    expect(OC, :reject_question, fn _dir, "que_empty", _opts ->
      send(test_pid, :rejected)
      {:ok, true}
    end)

    emit(sid, :question_required, %{
      request: %{"id" => "que_empty", "sessionID" => sid, "questions" => []}
    })

    assert_receive :rejected, 2_000
    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
    assert Runtime.Supervisor.whereis(ctx.channel.id) == ctx.pid
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  # -- Detached cards and late answers -----------------------------------------

  defp text_of(%{parts: [%{text: text} | _]}), do: text

  defp expect_wake do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:woken, sid, body})
      {:ok, ""}
    end)
  end

  # Drops the timeline events so far (the message that started the turn, its
  # agent_started), so a test can refute what comes next.
  defp flush_timeline do
    receive do
      {:timeline, _} -> flush_timeline()
    after
      0 -> :ok
    end
  end

  defp end_turn(sid, type \\ :agent_completed, data \\ %{}) do
    emit(sid, type, data)
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
  end

  test "a turn that ends with an error detaches its question card instead of clearing it",
       ctx do
    sid = start_turn(ctx)
    ask(sid)

    end_turn(sid, :agent_error, %{error: %{"name" => "UnknownError"}})
    assert_received {:timeline, %{event_type: "question_detached"}}

    assert [%{status: "pending", detached_at: %DateTime{}}] =
             QuestionRequests.pending_for_channel(ctx.channel.id)
  end

  test "a late answer is posted as a message mentioning the agent, which wakes it", ctx do
    sid = start_turn(ctx)
    ask(sid)
    end_turn(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    flush_timeline()
    # OpenCode forgot the question with the turn
    expect(OC, :reply_question, fn _dir, "que_1", [["Keep as is"]], _opts ->
      {:error, {:http, 404, %{"_tag" => "QuestionNotFoundError"}}}
    end)

    expect_wake()

    assert {:ok, %{status: "answered"}} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    # a durable message in the channel, from the user, mentioning the agent
    assert_receive {:timeline, %{event_type: "message", message: message}}, 2_000
    assert message.kind == "post"
    assert message.agent_id == nil
    assert message.mentions == [ctx.agent.id]

    assert message.body ==
             ~s(@#{ctx.agent.name} Answer to your question "How should dense screenshots behave at 390px?": Keep as is)

    assert_receive {:timeline,
                    %{
                      event_type: "question_resolved",
                      payload: %{"by" => "user", "delivered" => "message", "message_id" => mid}
                    }},
                   2_000

    assert mid == message.id

    # the router wakes the agent for it, like any message
    assert_receive {:woken, ^sid, body}, 2_000
    assert text_of(body) =~ "Message ID: #{message.id}"
    assert text_of(body) =~ "Keep as is"
    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
  end

  test "late answers outlive a merged wake: each stays in the channel", ctx do
    sid = start_turn(ctx)
    ask(sid, "que_a")
    ask(sid, "que_b")
    end_turn(sid)
    [first, second] = QuestionRequests.pending_for_channel(ctx.channel.id)

    stub(OC, :reply_question, fn _dir, _id, _answers, _opts -> {:error, {:http, 404, %{}}} end)
    expect_wake()

    {:ok, _} = Runtime.respond_question(ctx.channel.id, first.id, {:answered, [["Keep as is"]]})
    assert_receive {:woken, ^sid, _}, 2_000

    # the agent is working on the first; the second queues on its session
    {:ok, _} =
      Runtime.respond_question(ctx.channel.id, second.id, {:answered, [["Add mobile crops"]]})

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} and one more thing")
    _ = :sys.get_state(ctx.pid)

    bodies = ctx.channel.id |> Messages.list() |> Enum.map(& &1.body)
    assert Enum.any?(bodies, &(&1 =~ "Answer to your question" and &1 =~ "Keep as is"))
    assert Enum.any?(bodies, &(&1 =~ "Answer to your question" and &1 =~ "Add mobile crops"))
  end

  test "a late answer while agent runs are held is kept as a message, not lost", ctx do
    sid = start_turn(ctx)
    ask(sid)
    end_turn(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    flush_timeline()
    :ok = Canopy.Hold.engage("Insufficient balance")
    on_exit(fn -> Canopy.Hold.release() end)

    expect(OC, :reply_question, fn _dir, "que_1", _answers, _opts ->
      {:error, {:http, 404, %{}}}
    end)

    assert {:ok, %{status: "answered"}} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    # nobody is woken now, but the answer is in the channel for the next read
    refute_receive {:timeline, %{event_type: "agent_started"}}, 200

    assert Enum.any?(
             Messages.list(ctx.channel.id),
             &(&1.body =~ "Answer to your question" and &1.body =~ "Keep as is")
           )
  end

  test "an engine that takes the answer on a detached card resolves it with no message", ctx do
    sid = start_turn(ctx)
    ask(sid)
    end_turn(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    assert request.detached_at

    flush_timeline()
    # the engine still held the tool call (its abort failed): it took the answer
    expect(OC, :reply_question, fn _dir, "que_1", [["Keep as is"]], _opts -> {:ok, true} end)

    assert {:ok, %{status: "answered"}} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    assert_receive {:timeline, %{event_type: "question_resolved", payload: payload}}, 2_000
    refute Map.has_key?(payload, "delivered")
    refute_receive {:timeline, %{event_type: "message"}}, 200
    refute_received {:timeline, %{event_type: "agent_started"}}
  end

  test "an engine that takes an approval on a detached card resolves it with no message", ctx do
    sid = start_turn(ctx)

    emit(sid, :approval_required, %{
      request: %{"id" => "per_held", "sessionID" => sid, "permission" => "bash"}
    })

    assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
    end_turn(sid)
    [request] = PermissionRequests.pending_for_channel(ctx.channel.id)

    flush_timeline()
    expect(OC, :reply_permission, fn _dir, "per_held", :once, _opts -> {:ok, true} end)

    assert {:ok, %{status: "once"}} =
             Runtime.respond_permission(ctx.channel.id, request.id, :once)

    refute_receive {:timeline, %{event_type: "message"}}, 200
  end

  test "a late dismissal only clears the card", ctx do
    sid = start_turn(ctx)
    ask(sid)
    end_turn(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    expect(OC, :reject_question, fn _dir, "que_1", _opts -> {:error, {:http, 404, %{}}} end)
    flush_timeline()

    assert {:ok, %{status: "rejected"}} =
             Runtime.respond_question(ctx.channel.id, request.id, :rejected)

    refute_receive {:timeline, %{event_type: "message"}}, 200
    refute_received {:timeline, %{event_type: "agent_started"}}
  end

  test "a late answer wakes the agent like a user message: it lifts a pause", ctx do
    sid = start_turn(ctx)
    ask(sid)
    end_turn(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    # the chatter budget ran out while the user was away
    :sys.replace_state(ctx.pid, &%{&1 | paused: [], chatter: 99})
    assert Runtime.paused?(ctx.channel.id)

    expect(OC, :reply_question, fn _dir, "que_1", _answers, _opts ->
      {:error, {:http, 404, %{}}}
    end)

    expect_wake()

    assert {:ok, _} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    assert_receive {:woken, ^sid, _body}, 2_000
    refute Runtime.paused?(ctx.channel.id)
  end

  test "a late approval is posted as a message saying what the agent may now do", ctx do
    sid = start_turn(ctx)

    emit(sid, :approval_required, %{
      request: %{
        "id" => "per_1",
        "sessionID" => sid,
        "permission" => "edit",
        "patterns" => ["lib/a.ex"]
      }
    })

    assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :awaiting_user}

    end_turn(sid)
    assert_received {:timeline, %{event_type: "permission_detached"}}
    [request] = PermissionRequests.pending_for_channel(ctx.channel.id)
    assert request.detached_at

    flush_timeline()

    expect(OC, :reply_permission, fn _dir, "per_1", :once, _opts ->
      {:error, {:http, 404, %{}}}
    end)

    expect_wake()

    assert {:ok, %{status: "once"}} =
             Runtime.respond_permission(ctx.channel.id, request.id, :once)

    assert_receive {:timeline, %{event_type: "message", message: message}}, 2_000
    assert message.body == "@#{ctx.agent.name} Approved: edit lib/a.ex (once). You can do it now."

    assert_receive {:woken, ^sid, body}, 2_000
    assert text_of(body) =~ "Approved: edit lib/a.ex (once)"

    assert_receive {:timeline,
                    %{event_type: "permission_resolved", payload: %{"delivered" => "message"}}},
                   2_000
  end

  test "a late rejection of a permission only clears the card", ctx do
    sid = start_turn(ctx)

    emit(sid, :approval_required, %{
      request: %{"id" => "per_2", "sessionID" => sid, "permission" => "bash"}
    })

    assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
    end_turn(sid)
    [request] = PermissionRequests.pending_for_channel(ctx.channel.id)

    expect(OC, :reply_permission, fn _dir, "per_2", :reject, _opts ->
      {:error, {:http, 404, %{}}}
    end)

    flush_timeline()

    assert {:ok, %{status: "rejected"}} =
             Runtime.respond_permission(ctx.channel.id, request.id, :reject)

    refute_receive {:timeline, %{event_type: "message"}}, 200
  end

  test "a late answer to a delegate's question mentions it and reaches the session doing the work",
       ctx do
    test_pid = self()
    helper_session = Fixtures.session_fixture(%{channel: ctx.channel, agent_id: ctx.helper.id})
    helper_sid = helper_session.engine_session_id

    expect(OC, :prompt_async, fn _dir, sid, _body, _opts ->
      send(test_pid, {:delegate_prompted, sid})
      {:ok, ""}
    end)

    {:ok, _} =
      Delegations.create(%{
        channel_id: ctx.channel.id,
        task_id: ctx.task.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: ctx.helper.id,
        description: "trace every enqueue path"
      })

    assert_receive {:delegate_prompted, ^helper_sid}, 2_000
    ask(helper_sid, "que_delegate")
    end_turn(helper_sid)

    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    flush_timeline()

    expect(OC, :reply_question, fn _dir, "que_delegate", _answers, _opts ->
      {:error, {:http, 404, %{}}}
    end)

    expect_wake()

    assert {:ok, _} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    assert_receive {:timeline, %{event_type: "message", message: message}}, 2_000
    assert message.body =~ "@#{ctx.helper.name} Answer to your question"
    refute message.body =~ "(delegation"

    # the delegate's one session, where the delegated work is
    assert_receive {:woken, ^helper_sid, body}, 2_000
    assert text_of(body) =~ "Keep as is"
  end

  # -- Archived channels ---------------------------------------------------------

  test "an archived channel takes no answers; the card stays pending, and Dismiss still works",
       ctx do
    sid = start_turn(ctx)
    ask(sid)
    end_turn(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    flush_timeline()
    {:ok, _} = Canopy.Channels.archive(ctx.channel)

    assert {:error, :archived} =
             Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

    assert [%{status: "pending"}] = QuestionRequests.pending_for_channel(ctx.channel.id)
    refute_receive {:timeline, %{event_type: "message"}}, 200

    expect(OC, :reject_question, fn _dir, "que_1", _opts -> {:error, {:http, 404, %{}}} end)

    assert {:ok, %{status: "rejected"}} =
             Runtime.respond_question(ctx.channel.id, request.id, :rejected)
  end

  test "an archived channel takes no approvals", ctx do
    sid = start_turn(ctx)

    emit(sid, :approval_required, %{
      request: %{"id" => "per_arch", "sessionID" => sid, "permission" => "bash"}
    })

    assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
    [request] = PermissionRequests.pending_for_channel(ctx.channel.id)
    {:ok, _} = Canopy.Channels.archive(ctx.channel)

    assert {:error, :archived} = Runtime.respond_permission(ctx.channel.id, request.id, :once)
    assert [%{status: "pending"}] = PermissionRequests.pending_for_channel(ctx.channel.id)
  end

  # -- Free-text answers ---------------------------------------------------------

  defp ask_strict(sid) do
    emit(sid, :question_required, %{
      request: %{
        "id" => "que_strict",
        "sessionID" => sid,
        "questions" => [
          %{
            "question" => "Which crop?",
            "options" => [%{"label" => "Tall"}, %{"label" => "Wide"}],
            "custom" => false
          }
        ]
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
  end

  test "a free-text answer to a question with custom: false is posted as a message", ctx do
    sid = start_turn(ctx)
    ask_strict(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
    test_pid = self()

    flush_timeline()
    # never sent as an answer OpenCode may refuse: the tool call is released
    expect(OC, :reject_question, fn _dir, "que_strict", _opts ->
      send(test_pid, :released)
      {:ok, true}
    end)

    assert {:ok, %{status: "answered", answers: [["only the tall ones"]]}} =
             Runtime.respond_question(
               ctx.channel.id,
               request.id,
               {:answered, [["only the tall ones"]]}
             )

    assert_receive :released
    assert_receive {:timeline, %{event_type: "message", message: message}}, 2_000
    assert message.body =~ ~s(Answer to your question "Which crop?": only the tall ones)
    assert message.body =~ "reported the question as declined"

    assert_receive {:timeline,
                    %{event_type: "question_resolved", payload: %{"delivered" => "message"}}},
                   2_000

    # the agent is still in its turn: the message wakes it as soon as it ends
    expect_wake()
    emit(sid, :agent_completed, %{})
    assert_receive {:woken, ^sid, body}, 2_000
    assert text_of(body) =~ "only the tall ones"
  end

  test "a free-text answer goes back into the tool call when custom is left at its default",
       ctx do
    sid = start_turn(ctx)
    # OpenCode's question tool allows a typed answer unless custom is false
    ask(sid)
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    flush_timeline()

    expect(OC, :reply_question, fn _dir, "que_1", [["only the tall ones"]], _opts ->
      {:ok, true}
    end)

    assert {:ok, %{status: "answered"}} =
             Runtime.respond_question(
               ctx.channel.id,
               request.id,
               {:answered, [["only the tall ones"]]}
             )

    refute_receive {:timeline, %{event_type: "message"}}, 200
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  test "a free-text answer to a question that allows one goes back into the tool call", ctx do
    sid = start_turn(ctx)

    emit(sid, :question_required, %{
      request: %{
        "id" => "que_custom",
        "sessionID" => sid,
        "questions" => [
          %{
            "question" => "Which crop?",
            "options" => [%{"label" => "Tall"}],
            "custom" => true
          }
        ]
      }
    })

    assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
    [request] = QuestionRequests.pending_for_channel(ctx.channel.id)

    expect(OC, :reply_question, fn _dir, "que_custom", [["Tall", "and the wide ones"]], _opts ->
      {:ok, true}
    end)

    assert {:ok, %{status: "answered"}} =
             Runtime.respond_question(
               ctx.channel.id,
               request.id,
               {:answered, [["Tall", "and the wide ones"]]}
             )

    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
  end

  # -- One turn at a time --------------------------------------------------------

  describe "with turns serialized" do
    setup ctx do
      stub(OC, :create_session, fn _dir, _body, _opts ->
        {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
      end)

      Canopy.Settings.update(%{serialize_turns: true})
      ctx
    end

    test "an agent waiting on the user does not hold the channel", ctx do
      sid = start_turn(ctx)
      ask(sid)

      # the user turns to the other agent: it starts at once
      expect_wake()
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.helper.name} take a look")
      assert_receive {:woken, helper_sid, _}, 2_000
      refute helper_sid == sid

      assert Runtime.status(ctx.channel.id) == %{
               ctx.agent.id => :awaiting_user,
               ctx.helper.id => :busy
             }

      # the answer resumes the waiting turn alongside the other one
      [request] = QuestionRequests.pending_for_channel(ctx.channel.id)
      expect(OC, :reply_question, fn _dir, "que_1", _answers, _opts -> {:ok, true} end)

      {:ok, _} =
        Runtime.respond_question(ctx.channel.id, request.id, {:answered, [["Keep as is"]]})

      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy, ctx.helper.id => :busy}

      end_turn(sid)
      end_turn(helper_sid)
      refute_receive {:woken, _, _}, 200
      assert :sys.get_state(ctx.pid).waiting == []
    end

    test "a wake for the agent waiting on the user still waits for that turn", ctx do
      sid = start_turn(ctx)
      ask(sid)

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} are you there?")
      refute_receive {:woken, _, _}, 200
      assert %{queues: %{^sid => [_]}} = :sys.get_state(ctx.pid)

      # the turn ends without an answer: the queued message goes out, the card stays
      expect_wake()
      end_turn(sid)
      assert_receive {:woken, ^sid, body}, 2_000
      assert text_of(body) =~ "are you there?"
      assert [%{detached_at: %DateTime{}}] = QuestionRequests.pending_for_channel(ctx.channel.id)
    end

    test "a wake queued on the waiting session joins the line when its turn ends beside another",
         ctx do
      sid = start_turn(ctx)
      ask(sid)

      # a message for the owner queues on its (waiting) session
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} any news?")
      _ = :sys.get_state(ctx.pid)
      assert %{queues: %{^sid => [_]}} = :sys.get_state(ctx.pid)

      # the helper starts while the owner waits on the user
      expect_wake()
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.helper.name} take a look")
      assert_receive {:woken, helper_sid, _}, 2_000
      chatter = :sys.get_state(ctx.pid).chatter

      # the owner's turn ends while the helper still runs: one turn at a time,
      # so the queued wake waits in line instead of starting beside it
      end_turn(sid)
      refute_receive {:woken, ^sid, _}, 200
      assert [{{:root, owner_id}, _}] = :sys.get_state(ctx.pid).waiting
      assert owner_id == ctx.agent.id

      # the helper finishes: the owner's wake starts, without counting twice
      expect_wake()
      end_turn(helper_sid)
      assert_receive {:woken, ^sid, body}, 2_000
      assert text_of(body) =~ "any news?"
      assert :sys.get_state(ctx.pid).chatter == chatter
    end
  end
end
