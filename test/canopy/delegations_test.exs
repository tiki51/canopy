defmodule Canopy.DelegationsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Delegations, Timeline}

  setup do
    delegate = agent_fixture()
    ctx = scenario(members: [delegate])
    Map.put(ctx, :delegate, delegate)
  end

  test "create, start, complete", ctx do
    %{channel: channel, task: task, agent: agent, delegate: delegate, session: session} = ctx
    Timeline.subscribe(channel.id)

    assert {:ok, delegation} =
             Delegations.create(%{
               channel_id: channel.id,
               task_id: task.id,
               from_agent_id: agent.id,
               to_agent_id: delegate.id,
               parent_session_id: session.id,
               description: "Check whether retries happen elsewhere"
             })

    assert delegation.status == "requested"
    assert_receive {:timeline, %Timeline.Event{event_type: "delegation_created", ref_id: id}}
    assert id == delegation.id
    assert [%{id: ^id}] = Delegations.list_pending_for(channel.id, delegate.id)
    assert [] = Delegations.list_pending_for(channel.id, agent.id)

    # the delegate works on it in its own session in the channel
    delegate_session = session_fixture(%{channel: channel, agent_id: delegate.id})
    assert {:ok, delegation} = Delegations.start(delegation, delegate_session.id)
    assert delegation.status == "working"
    assert delegation.child_session_id == delegate_session.id

    assert {:ok, delegation} = Delegations.complete(delegation, "Yes, in two places")
    assert delegation.status == "completed"
    assert delegation.result == "Yes, in two places"
    assert %DateTime{} = delegation.completed_at
    assert_receive {:timeline, %Timeline.Event{event_type: "delegation_completed"} = event}
    assert event.payload["result"] == "Yes, in two places"
    assert [] = Delegations.list_pending_for(channel.id, delegate.id)
  end

  test "matching finds a delegation in the channel by id or short id", ctx do
    %{channel: channel, agent: agent, delegate: delegate} = ctx

    {:ok, delegation} =
      Delegations.create(%{
        channel_id: channel.id,
        from_agent_id: agent.id,
        to_agent_id: delegate.id,
        description: "a"
      })

    id = delegation.id
    assert [%{id: ^id}] = Delegations.matching(channel.id, id)
    assert [%{id: ^id}] = Delegations.matching(channel.id, " " <> String.slice(id, 0, 11) <> " ")
    # shorter than the short form, or in another channel: no match
    assert [] = Delegations.matching(channel.id, String.slice(id, 0, 6))
    assert [] = Delegations.matching(channel_fixture().id, id)
  end

  test "fail records delegation_failed and self-delegation is rejected", ctx do
    %{channel: channel, agent: agent, delegate: delegate} = ctx
    Timeline.subscribe(channel.id)

    assert {:error, changeset} =
             Delegations.create(%{
               channel_id: channel.id,
               from_agent_id: agent.id,
               to_agent_id: agent.id,
               description: "me"
             })

    assert %{to_agent_id: ["cannot delegate to yourself"]} = errors_on(changeset)

    {:ok, delegation} =
      Delegations.create(%{
        channel_id: channel.id,
        from_agent_id: agent.id,
        to_agent_id: delegate.id,
        description: "x"
      })

    assert {:ok, delegation} = Delegations.fail(delegation, "could not reproduce")
    assert delegation.status == "failed"
    assert_receive {:timeline, %Timeline.Event{event_type: "delegation_created"}}
    assert_receive {:timeline, %Timeline.Event{event_type: "delegation_failed"} = event}
    assert event.payload["result"] == "could not reproduce"
  end
end
