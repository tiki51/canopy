defmodule Canopy.MCP.Tools.TasksTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Ecto.Query, only: [from: 2]

  alias Canopy.{Delegations, Tasks, Timeline}
  alias Canopy.MCP.Tools.{TaskGet, TaskUpdate}

  setup do
    delegate = agent_fixture(name: "database-" <> unique_suffix())
    ctx = scenario(members: [delegate])
    delegate_session = session_fixture(%{channel: ctx.channel, agent_id: delegate.id})
    Map.merge(ctx, %{delegate: delegate, delegate_session: delegate_session})
  end

  defp delegate(ctx, description, attrs \\ %{}) do
    {:ok, delegation} =
      Delegations.create(
        Map.merge(
          %{
            channel_id: ctx.channel.id,
            task_id: ctx.task.id,
            from_agent_id: ctx.agent.id,
            to_agent_id: ctx.delegate.id,
            description: description
          },
          attrs
        )
      )

    delegation
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

    test "a delegate reports on its delegation and never changes the channel task", ctx do
      delegation = delegate(ctx, "Check the index", %{parent_session_id: ctx.session.id})
      # as the channel server starts it: in the delegate's own session
      {:ok, _} = Delegations.start(delegation, ctx.delegate_session.id)
      session = ctx.delegate_session
      Timeline.subscribe(ctx.channel.id)
      task_before = Tasks.for_channel(ctx.channel.id)

      assert {:ok, text} = call(TaskUpdate, %{status: "working"}, session)
      assert text =~ "still working on delegation [#{delegation.id}]"
      assert Delegations.get!(delegation.id).status == "working"

      assert {:error, reason} = call(TaskUpdate, %{title: "New title"}, session)
      assert reason =~ "Only the task owner"

      assert {:ok, text} =
               call(
                 TaskUpdate,
                 %{status: "completed", result: "Index missing on invoice_id"},
                 session
               )

      assert text =~
               "delegation [#{delegation.id}] completed; @#{ctx.agent.name} will be notified."

      delegation = Delegations.get!(delegation.id)
      assert delegation.status == "completed"
      assert delegation.result == "Index missing on invoice_id"

      task_after = Tasks.for_channel(ctx.channel.id)
      assert task_after.status == task_before.status
      assert task_after.title == task_before.title

      refute_received {:timeline, %Timeline.Event{event_type: "task_updated"}}

      assert_receive {:timeline,
                      %Timeline.Event{event_type: "delegation_completed", ref_id: ref_id}}

      assert ref_id == delegation.id
    end

    test "a delegate reporting blocked fails its delegation with the result as reason", ctx do
      # the user's delegation runs in the delegate's root session
      {:ok, delegation} =
        Delegations.create(%{
          channel_id: ctx.channel.id,
          to_agent_id: ctx.delegate.id,
          description: "Check the index"
        })

      assert {:ok, text} =
               call(
                 TaskUpdate,
                 %{status: "blocked", result: "No access to the staging db"},
                 ctx.delegate_session
               )

      assert text =~ "delegation [#{delegation.id}] marked blocked"
      delegation = Delegations.get!(delegation.id)
      assert delegation.status == "failed"
      assert delegation.result == "No access to the staging db"
    end

    test "a delegate reporting a bare result completes its delegation", ctx do
      delegation = delegate(ctx, "Look at the logs")

      assert {:ok, text} =
               call(TaskUpdate, %{result: "Logs show a double enqueue"}, ctx.delegate_session)

      assert text =~ "delegation [#{delegation.id}] completed"
      assert Delegations.get!(delegation.id).result == "Logs show a double enqueue"
    end

    test "with several pending, a delegate names the one it reports on", ctx do
      first = delegate(ctx, "Check the index")
      # one from the user too: every pending delegation counts
      second = delegate(ctx, "Then the logs", %{from_agent_id: nil})

      assert {:error, reason} =
               call(TaskUpdate, %{status: "completed", result: "done"}, ctx.delegate_session)

      assert reason =~ "you have 2 pending delegations in ##{ctx.channel.name}"
      assert reason =~ ~s(#{first.id} "Check the index")
      assert reason =~ ~s(#{second.id} "Then the logs")
      assert reason =~ "pass `delegation`"
      assert Delegations.get!(first.id).status == "requested"
      assert Delegations.get!(second.id).status == "requested"

      assert {:ok, text} =
               call(
                 TaskUpdate,
                 %{status: "completed", result: "logs clean", delegation: second.id},
                 ctx.delegate_session
               )

      assert text =~ "delegation [#{second.id}] completed; the channel will be notified."
      assert Delegations.get!(second.id).status == "completed"
      assert Delegations.get!(first.id).status == "requested"

      # one left: no need to name it
      assert {:ok, text} = call(TaskUpdate, %{result: "index fine"}, ctx.delegate_session)
      assert text =~ "delegation [#{first.id}] completed"
    end

    test "a named delegation must be pending and addressed to the caller", ctx do
      delegation = delegate(ctx, "Check the index")

      assert {:error, reason} =
               call(TaskUpdate, %{result: "mine now", delegation: delegation.id}, ctx)

      assert reason ==
               "delegation [#{delegation.id}] is addressed to @#{ctx.delegate.name}, not to you"

      assert {:error, reason} =
               call(TaskUpdate, %{result: "x", delegation: "dl_nothing"}, ctx.delegate_session)

      assert reason == "no delegation dl_nothing in ##{ctx.channel.name}"

      # the short form agents cite (dl_ plus eight characters) is shared by
      # delegations made within a second; the caller's own one is meant
      other =
        delegate(ctx, "Not yours", %{from_agent_id: ctx.delegate.id, to_agent_id: ctx.agent.id})

      short = String.slice(delegation.id, 0, 11)

      Canopy.Repo.update_all(
        from(d in Canopy.Delegations.Delegation, where: d.id == ^other.id),
        set: [id: short <> String.duplicate("Z", 18)]
      )

      assert {:error, reason} =
               call(
                 TaskUpdate,
                 %{status: "working", delegation: short <> "U"},
                 ctx.delegate_session
               )

      assert reason =~ "no delegation"

      assert {:ok, text} =
               call(TaskUpdate, %{status: "working", delegation: short}, ctx.delegate_session)

      assert text =~ "still working on delegation [#{delegation.id}]"

      {:ok, _} = Delegations.complete(delegation, "done")

      assert {:error, reason} =
               call(
                 TaskUpdate,
                 %{result: "again", delegation: delegation.id},
                 ctx.delegate_session
               )

      assert reason == "delegation [#{delegation.id}] is already completed"
      assert Delegations.get!(delegation.id).result == "done"
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
