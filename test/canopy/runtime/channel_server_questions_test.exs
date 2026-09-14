defmodule Canopy.Runtime.ChannelServerQuestionsTest do
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

  defp start_turn(ctx) do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive :prompted, 2_000
    ctx.session.opencode_session_id
  end

  defp emit(sid, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:opencode_event, %Canopy.OpenCode.Event{type: type, session_id: sid, data: data}}
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

    # the agent is still blocked on the answer
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
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
    assert_receive {:timeline, %{event_type: "question_resolved"}}, 2_000

    assert QuestionRequests.pending_for_channel(ctx.channel.id) == []
    assert %{status: "answered", answers: [["Keep as is"]]} = QuestionRequests.get!(request.id)
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
end
