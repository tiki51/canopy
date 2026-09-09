defmodule Canopy.MCP.Tools.CollaborationTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Channels, Delegations, Handoffs, Messages, Tasks, Timeline}
  alias Canopy.MCP.Tools.{DelegateTask, HandoffAccept, HandoffGet, HandoffReject, HandoffTask}

  setup do
    target = agent_fixture(name: "database-" <> unique_suffix())
    bystander = agent_fixture(name: "reviewer-" <> unique_suffix())
    outsider = agent_fixture(name: "outsider-" <> unique_suffix())
    ctx = scenario(members: [target, bystander])
    target_session = session_fixture(%{channel: ctx.channel, agent_id: target.id})
    bystander_session = session_fixture(%{channel: ctx.channel, agent_id: bystander.id})

    Map.merge(ctx, %{
      target: target,
      target_session: target_session,
      bystander: bystander,
      bystander_session: bystander_session,
      outsider: outsider
    })
  end

  describe "delegate_task" do
    test "creates a requested delegation and records delegation_created", ctx do
      Timeline.subscribe(ctx.channel.id)

      assert {:ok, text} =
               call(DelegateTask, %{to: "@" <> ctx.target.name, task: "Check the index"}, ctx)

      assert [_, id] =
               Regex.run(~r/delegation \[(dl_[^\]]+)\] requested: @#{ctx.target.name}/, text)

      assert text =~ "ownership stays with @#{ctx.agent.name}"

      delegation = Delegations.get!(id)
      assert delegation.status == "requested"
      assert delegation.from_agent_id == ctx.agent.id
      assert delegation.to_agent_id == ctx.target.id
      assert delegation.task_id == ctx.task.id
      assert delegation.parent_session_id == ctx.session.id
      assert is_nil(delegation.child_session_id)
      assert delegation.description == "Check the index"
      assert Channels.get!(ctx.channel.id).owner_agent_id == ctx.agent.id

      assert_receive {:timeline, %Timeline.Event{event_type: "delegation_created", ref_id: ^id}}
      assert [%{id: ^id}] = Delegations.list_pending_for(ctx.channel.id, ctx.target.id)
    end

    test "accepts a bare name or an agent id", ctx do
      assert {:ok, _} = call(DelegateTask, %{to: ctx.target.name, task: "one"}, ctx)
      assert {:ok, _} = call(DelegateTask, %{to: ctx.target.id, task: "two"}, ctx)
      assert length(Delegations.list_pending_for(ctx.channel.id, ctx.target.id)) == 2
    end

    test "refuses yourself, non-members, unknown agents, and empty tasks", ctx do
      assert {:error, "cannot delegate to yourself"} =
               call(DelegateTask, %{to: ctx.agent.name, task: "x"}, ctx)

      assert {:error, message} = call(DelegateTask, %{to: ctx.outsider.name, task: "x"}, ctx)
      assert message == "@#{ctx.outsider.name} is not a member of ##{ctx.channel.name}"

      assert {:error, "unknown agent @ghost"} =
               call(DelegateTask, %{to: "@ghost", task: "x"}, ctx)

      assert {:error, "task is empty"} =
               call(DelegateTask, %{to: ctx.target.name, task: " "}, ctx)
    end
  end

  describe "handoff_task" do
    test "builds a packet with branch, status, diff stat, recent messages, and task", ctx do
      {:ok, m1} =
        Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "found two retry paths")

      {:ok, m2} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "ok")
      File.write!(Path.join(ctx.repository.path, "notes.txt"), "dirty\n")
      Timeline.subscribe(ctx.channel.id)

      assert {:ok, text} =
               call(
                 HandoffTask,
                 %{
                   to: "@" <> ctx.target.name,
                   summary: "Two retry paths found",
                   reason: "Uniqueness belongs in the database",
                   suggested_next_step: "Add a unique index"
                 },
                 ctx
               )

      assert [_, id] = Regex.run(~r/handoff \[(ho_[^\]]+)\] requested: @#{ctx.target.name}/, text)
      assert text =~ "branch main, 1 changed file(s)"
      assert text =~ "You remain owner"

      handoff = Handoffs.get!(id)
      assert handoff.status == "requested"
      assert handoff.from_agent_id == ctx.agent.id
      assert handoff.to_agent_id == ctx.target.id
      assert handoff.task_id == ctx.task.id
      assert handoff.source_session_id == ctx.session.id
      assert handoff.target_session_id == ctx.target_session.id
      assert handoff.summary == "Two retry paths found"
      assert handoff.reason == "Uniqueness belongs in the database"
      assert handoff.suggested_next_step == "Add a unique index"

      assert handoff.packet["branch"] == "main"
      assert handoff.packet["status"] == ["?? notes.txt"]
      assert handoff.packet["changed_files"] == ["notes.txt"]
      assert is_binary(handoff.packet["diff_stat"])
      assert handoff.packet["recent_message_ids"] == [m1.id, m2.id]
      assert handoff.packet["task"]["id"] == ctx.task.id
      assert handoff.packet["task"]["status"] == "open"

      assert Channels.get!(ctx.channel.id).owner_agent_id == ctx.agent.id
      assert_receive {:timeline, %Timeline.Event{event_type: "handoff_requested", ref_id: ^id}}
    end

    test "only the current owner can hand off", ctx do
      assert {:error, message} =
               call(HandoffTask, %{to: ctx.agent.name, summary: "take it"}, ctx.bystander_session)

      assert message == "only the owner (@#{ctx.agent.name}) can hand off ##{ctx.channel.name}"
      assert Handoffs.pending_for_channel(ctx.channel.id) == []

      assert {:error, "cannot hand off to yourself"} =
               call(HandoffTask, %{to: ctx.agent.name, summary: "s"}, ctx)

      assert {:error, "summary is empty"} =
               call(HandoffTask, %{to: ctx.target.name, summary: " "}, ctx)
    end
  end

  describe "handoff_get / handoff_accept / handoff_reject" do
    setup ctx do
      {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "context message")

      {:ok, text} =
        call(
          HandoffTask,
          %{
            to: ctx.target.name,
            summary: "Retry logic isolated",
            suggested_next_step: "Add the index"
          },
          ctx
        )

      [_, id] = Regex.run(~r/handoff \[(ho_[^\]]+)\]/, text)
      %{handoff: Handoffs.get!(id)}
    end

    test "handoff_get shows the full packet to members only", ctx do
      assert {:ok, text} = call(HandoffGet, %{handoff_id: ctx.handoff.id}, ctx.target_session)

      assert text =~
               "Handoff [#{ctx.handoff.id}] requested: @#{ctx.agent.name} → @#{ctx.target.name}"

      assert text =~ "Summary: Retry logic isolated"
      assert text =~ "Suggested next step: Add the index"
      assert text =~ "Branch: main"
      assert text =~ "Recent message ids: msg_"
      assert text =~ "Task at handoff: open — #{ctx.task.title}"

      assert {:error, "unknown handoff ho_missing"} =
               call(HandoffGet, %{handoff_id: "ho_missing"}, ctx)

      outsider_session =
        session_fixture(%{
          channel: channel_fixture(%{owner_agent_id: ctx.outsider.id}),
          agent_id: ctx.outsider.id
        })

      assert {:error, message} = call(HandoffGet, %{handoff_id: ctx.handoff.id}, outsider_session)
      assert message == "not a member of ##{ctx.channel.name}"
    end

    test "handoff_accept is refused for anyone but the target", ctx do
      assert {:error, message} =
               call(HandoffAccept, %{handoff_id: ctx.handoff.id}, ctx.bystander_session)

      assert message == "handoff #{ctx.handoff.id} is not addressed to you"

      assert {:error, message} = call(HandoffAccept, %{handoff_id: ctx.handoff.id}, ctx)
      assert message == "handoff #{ctx.handoff.id} is not addressed to you"

      assert Handoffs.get!(ctx.handoff.id).status == "requested"
      assert Channels.get!(ctx.channel.id).owner_agent_id == ctx.agent.id
    end

    test "handoff_accept by the target changes the owner and records the events", ctx do
      Timeline.subscribe(ctx.channel.id)

      assert {:ok, text} = call(HandoffAccept, %{handoff_id: ctx.handoff.id}, ctx.target_session)

      assert text =~
               "accepted handoff [#{ctx.handoff.id}]; you now own ##{ctx.channel.name} and its task"

      assert text =~ "Suggested next step: Add the index"

      assert Handoffs.get!(ctx.handoff.id).status == "accepted"
      assert Channels.get!(ctx.channel.id).owner_agent_id == ctx.target.id
      assert Tasks.for_channel(ctx.channel.id).owner_agent_id == ctx.target.id

      id = ctx.handoff.id
      assert_receive {:timeline, %Timeline.Event{event_type: "handoff_accepted", ref_id: ^id}}
      assert_receive {:timeline, %Timeline.Event{event_type: "owner_changed"}}

      assert {:error, message} =
               call(HandoffAccept, %{handoff_id: ctx.handoff.id}, ctx.target_session)

      assert message == "handoff #{ctx.handoff.id} is already accepted"
    end

    test "handoff_reject by the target keeps the owner and stores the reason", ctx do
      Timeline.subscribe(ctx.channel.id)

      assert {:error, message} =
               call(
                 HandoffReject,
                 %{handoff_id: ctx.handoff.id, reason: "busy"},
                 ctx.bystander_session
               )

      assert message == "handoff #{ctx.handoff.id} is not addressed to you"

      assert {:error, "reason is empty"} =
               call(HandoffReject, %{handoff_id: ctx.handoff.id, reason: " "}, ctx.target_session)

      assert {:ok, text} =
               call(
                 HandoffReject,
                 %{handoff_id: ctx.handoff.id, reason: "Not my area"},
                 ctx.target_session
               )

      assert text =~
               "rejected handoff [#{ctx.handoff.id}]; @#{ctx.agent.name} keeps ##{ctx.channel.name}"

      handoff = Handoffs.get!(ctx.handoff.id)
      assert handoff.status == "rejected"
      assert handoff.rejection_reason == "Not my area"
      assert Channels.get!(ctx.channel.id).owner_agent_id == ctx.agent.id

      id = ctx.handoff.id
      assert_receive {:timeline, %Timeline.Event{event_type: "handoff_rejected", ref_id: ^id}}
    end
  end
end
