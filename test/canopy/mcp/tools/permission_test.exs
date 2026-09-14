defmodule Canopy.MCP.Tools.PermissionTest do
  @moduledoc "Claude Code's permission prompt tool, answered from the channel."
  use Canopy.DataCase, async: false

  alias Canopy.{AgentSessions, Fixtures, PermissionRequests, QuestionRequests, Runtime, Timeline}
  alias Canopy.ClaudeCode.Prompts
  alias Canopy.Engine.Event
  alias Canopy.MCP.Tools.Permission
  alias Canopy.MCPHelpers

  setup do
    coder = Fixtures.agent_fixture(%{engine: "claude_code"})
    scenario = Fixtures.scenario(members: [coder])

    session =
      Fixtures.session_fixture(%{
        channel: scenario.channel,
        agent_id: coder.id,
        engine: "claude_code",
        engine_session_id: Ecto.UUID.generate(),
        mcp_token: AgentSessions.generate_mcp_token()
      })

    Timeline.subscribe(scenario.channel.id)
    {:ok, _} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{coder: coder, claude_session: session})}
  end

  defp ask(ctx, params) do
    Task.async(fn -> MCPHelpers.call_as_session(Permission, params, ctx.claude_session) end)
  end

  defp decode({:ok, text}), do: JSON.decode!(text)

  test "a tool call becomes a permission card; Once allows it with the same input", ctx do
    input = %{
      "file_path" => ctx.repository.path <> "/lib/a.ex",
      "old_string" => "a",
      "new_string" => "b"
    }

    task = ask(ctx, %{tool_name: "Edit", input: input, tool_use_id: "toolu_1"})

    assert_receive {:telemetry, agent_id,
                    %Event{type: :approval_required, data: %{request: request}}},
                   5_000

    assert agent_id == ctx.coder.id
    assert request["permission"] == "Edit"
    assert request["patterns"] == ["lib/a.ex"]
    assert request["metadata"]["diff"] == "-a\n+b"

    [pending] = PermissionRequests.pending_for_channel(ctx.channel.id)
    assert pending.opencode_permission_id == "toolu_1"
    assert pending.agent_session_id == ctx.claude_session.id

    assert {:ok, %{status: "once"}} =
             Runtime.respond_permission(ctx.channel.id, pending.id, :once)

    assert %{"behavior" => "allow", "updatedInput" => ^input} = decode(Task.await(task, 5_000))
    assert PermissionRequests.pending_for_channel(ctx.channel.id) == []
  end

  test "Reject denies with a message; Always allows and is remembered for the session", ctx do
    task =
      ask(ctx, %{tool_name: "Bash", input: %{"command" => "rm -rf build"}, tool_use_id: "toolu_2"})

    assert_receive {:telemetry, _,
                    %Event{
                      type: :approval_required,
                      data: %{request: %{"patterns" => ["rm -rf build"]}}
                    }},
                   5_000

    [pending] = PermissionRequests.pending_for_channel(ctx.channel.id)
    assert {:ok, _} = Runtime.respond_permission(ctx.channel.id, pending.id, :reject)
    assert %{"behavior" => "deny", "message" => message} = decode(Task.await(task, 5_000))
    assert message =~ "rejected Bash"

    task = ask(ctx, %{tool_name: "Bash", input: %{"command" => "make"}, tool_use_id: "toolu_3"})
    assert_receive {:telemetry, _, %Event{type: :approval_required}}, 5_000
    [pending] = PermissionRequests.pending_for_channel(ctx.channel.id)
    assert {:ok, _} = Runtime.respond_permission(ctx.channel.id, pending.id, :always)
    assert %{"behavior" => "allow"} = decode(Task.await(task, 5_000))
    assert Prompts.always_list(ctx.claude_session.engine_session_id) == ["Bash"]

    # the next Bash call is answered without a card
    assert %{"behavior" => "allow"} =
             decode(
               MCPHelpers.call_as_session(
                 Permission,
                 %{tool_name: "Bash", input: %{"command" => "ls"}, tool_use_id: "toolu_4"},
                 ctx.claude_session
               )
             )

    refute_received {:telemetry, _,
                     %Event{type: :approval_required, data: %{request: %{"id" => "toolu_4"}}}}
  end

  test "AskUserQuestion becomes a question card; the answers go back as updatedInput", ctx do
    input = %{
      "questions" => [
        %{
          "question" => "Which color?",
          "header" => "Color",
          "multiSelect" => false,
          "options" => [
            %{"label" => "Red", "description" => "warm"},
            %{"label" => "Blue", "description" => "cool"}
          ]
        }
      ]
    }

    task = ask(ctx, %{tool_name: "AskUserQuestion", input: input, tool_use_id: "toolu_q"})

    assert_receive {:telemetry, _, %Event{type: :question_required, data: %{request: request}}},
                   5_000

    assert [
             %{
               "question" => "Which color?",
               "header" => "Color",
               "multiple" => false,
               "options" => [_, _]
             }
           ] = request["questions"]

    [pending] = QuestionRequests.pending_for_channel(ctx.channel.id)
    assert pending.opencode_question_id == "toolu_q"

    assert {:ok, _} =
             Runtime.respond_question(ctx.channel.id, pending.id, {:answered, [["Blue"]]})

    assert %{"behavior" => "allow", "updatedInput" => updated} = decode(Task.await(task, 5_000))
    assert updated["answers"] == %{"Which color?" => "Blue"}
    assert updated["questions"] == input["questions"]
  end

  test "a rejected question is a deny", ctx do
    input = %{
      "questions" => [
        %{"question" => "Go on?", "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
      ]
    }

    task = ask(ctx, %{tool_name: "AskUserQuestion", input: input, tool_use_id: "toolu_q2"})
    assert_receive {:telemetry, _, %Event{type: :question_required}}, 5_000
    [pending] = QuestionRequests.pending_for_channel(ctx.channel.id)
    assert {:ok, _} = Runtime.respond_question(ctx.channel.id, pending.id, :rejected)
    assert %{"behavior" => "deny", "message" => message} = decode(Task.await(task, 5_000))
    assert message =~ "declined"
  end

  test "an unanswered prompt is denied after the timeout", ctx do
    previous = Application.get_env(:canopy, :claude_code)

    Application.put_env(
      :canopy,
      :claude_code,
      Keyword.put(previous || [], :prompt_timeout_ms, 300)
    )

    on_exit(fn -> Application.put_env(:canopy, :claude_code, previous) end)

    task =
      ask(ctx, %{
        tool_name: "Write",
        input: %{"file_path" => "/x", "content" => "hi"},
        tool_use_id: "toolu_t"
      })

    assert_receive {:telemetry, _,
                    %Event{
                      type: :approval_required,
                      data: %{request: %{"metadata" => %{"diff" => "+hi"}}}
                    }},
                   5_000

    assert %{"behavior" => "deny", "message" => message} = decode(Task.await(task, 5_000))
    assert message =~ "in time"

    # answering afterwards clears the card without an error
    [pending] = PermissionRequests.pending_for_channel(ctx.channel.id)

    assert {:ok, %{status: "rejected"}} =
             Runtime.respond_permission(ctx.channel.id, pending.id, :reject)
  end

  test "the tool refuses OpenCode-style calls", ctx do
    assert {:error, message} =
             MCPHelpers.call(
               Permission,
               %{tool_name: "Bash", input: %{}, tool_use_id: "x"},
               ctx.session
             )

    assert message =~ "Claude Code sessions only"
  end

  test "open prompts show up in the engine's reconciliation", ctx do
    task = ask(ctx, %{tool_name: "Bash", input: %{"command" => "ls"}, tool_use_id: "toolu_r"})
    assert_receive {:telemetry, _, %Event{type: :approval_required}}, 5_000

    view = Canopy.Engine.ClaudeCode.reconcile(%{}, %{})

    assert [
             %Event{
               type: :approval_required,
               session_id: sid,
               data: %{request: %{"id" => "toolu_r"}}
             }
           ] = view.permissions

    assert sid == ctx.claude_session.engine_session_id

    [pending] = PermissionRequests.pending_for_channel(ctx.channel.id)
    Runtime.respond_permission(ctx.channel.id, pending.id, :once)
    Task.await(task, 5_000)
    assert Canopy.Engine.ClaudeCode.reconcile(%{}, %{}).permissions == []
  end
end
