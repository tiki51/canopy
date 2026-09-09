defmodule Canopy.MCP.Tools.TasksTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Delegations, Tasks, Timeline}
  alias Canopy.MCP.Tools.{TaskGet, TaskUpdate}

  setup do
    delegate = agent_fixture(name: "database-" <> unique_suffix())
    ctx = scenario(members: [delegate])
    delegate_session = session_fixture(%{channel: ctx.channel, agent_id: delegate.id})
    Map.merge(ctx, %{delegate: delegate, delegate_session: delegate_session})
  end

  describe "task_get" do
    test "shows the channel task", ctx do
      {:ok, _} =
        Tasks.update(ctx.task, %{description: "Retries duplicate charges", status: "working"})

      assert {:ok, text} = call(TaskGet, %{}, ctx)
      assert text =~ "##{ctx.channel.name}"

      assert text =~
               "Task: [#{ctx.task.id}] working — #{ctx.task.title} (owner @#{ctx.agent.name})"

      assert text =~ "Description: Retries duplicate charges"
    end
  end

  describe "task_update" do
    test "updates fields and records task_updated with the caller", ctx do
      Timeline.subscribe(ctx.channel.id)

      assert {:ok, text} =
               call(
                 TaskUpdate,
                 %{status: "working", title: "Fix payment retries", result: "  "},
                 ctx
               )

      assert text =~ "updated task in ##{ctx.channel.name}"
      assert text =~ "working — Fix payment retries"
      refute text =~ "Delegation"

      task = Tasks.for_channel(ctx.channel.id)
      assert task.status == "working"
      assert task.title == "Fix payment retries"
      assert is_nil(task.result)

      assert_receive {:timeline,
                      %Timeline.Event{
                        event_type: "task_updated",
                        agent_id: agent_id,
                        payload: payload
                      }}

      assert agent_id == ctx.agent.id
      assert payload["changes"] == %{"status" => "working", "title" => "Fix payment retries"}
    end

    test "rejects empty updates and unknown statuses", ctx do
      assert {:error, message} = call(TaskUpdate, %{}, ctx)
      assert message =~ "nothing to update"

      assert {:error, message} = call(TaskUpdate, %{status: "done"}, ctx)
      assert message == "status must be one of open, working, blocked, completed"
    end

    test "a delegate completing the task also completes its delegation", ctx do
      {:ok, delegation} =
        Delegations.create(%{
          channel_id: ctx.channel.id,
          task_id: ctx.task.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: ctx.delegate.id,
          parent_session_id: ctx.session.id,
          description: "Check the index"
        })

      Timeline.subscribe(ctx.channel.id)

      assert {:ok, text} = call(TaskUpdate, %{status: "working"}, ctx.delegate_session)
      refute text =~ "Delegation"
      assert Delegations.get!(delegation.id).status == "requested"

      assert {:ok, text} =
               call(
                 TaskUpdate,
                 %{status: "completed", result: "Index missing on invoice_id"},
                 ctx.delegate_session
               )

      assert text =~
               "Delegation [#{delegation.id}] completed; @#{ctx.agent.name} will be notified."

      delegation = Delegations.get!(delegation.id)
      assert delegation.status == "completed"
      assert delegation.result == "Index missing on invoice_id"
      assert Tasks.for_channel(ctx.channel.id).status == "completed"

      assert_receive {:timeline, %Timeline.Event{event_type: "task_updated"}}
      assert_receive {:timeline, %Timeline.Event{event_type: "task_updated"}}

      assert_receive {:timeline,
                      %Timeline.Event{event_type: "delegation_completed", ref_id: ref_id}}

      assert ref_id == delegation.id
    end

    test "a delegate reporting a bare result completes the delegation through its child session",
         ctx do
      {:ok, delegation} =
        Delegations.create(%{
          channel_id: ctx.channel.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: ctx.delegate.id,
          description: "Look at the logs"
        })

      child =
        session_fixture(%{
          channel: ctx.channel,
          agent_id: ctx.delegate.id,
          parent_session_id: ctx.session.id
        })

      {:ok, _} = Delegations.start(delegation, child.id)

      assert {:ok, text} = call(TaskUpdate, %{result: "Logs show a double enqueue"}, child)
      assert text =~ "Delegation [#{delegation.id}] completed"
      assert Delegations.get!(delegation.id).result == "Logs show a double enqueue"
    end

    test "the owner completing the task does not touch delegations addressed to others", ctx do
      {:ok, delegation} =
        Delegations.create(%{
          channel_id: ctx.channel.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: ctx.delegate.id,
          description: "Check the index"
        })

      assert {:ok, text} = call(TaskUpdate, %{status: "completed", result: "done"}, ctx)
      refute text =~ "Delegation"
      assert Delegations.get!(delegation.id).status == "requested"
    end
  end
end
