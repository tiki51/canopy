defmodule Canopy.HandoffsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Channels, Handoffs, Tasks, Timeline}

  setup do
    target = agent_fixture()
    ctx = scenario(members: [target])
    Map.put(ctx, :target, target)
  end

  defp request(ctx) do
    {:ok, handoff} =
      Handoffs.request(%{
        channel_id: ctx.channel.id,
        task_id: ctx.task.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: ctx.target.id,
        source_session_id: ctx.session.id,
        summary: "Two retry paths found; regression test added",
        reason: "Uniqueness belongs in the database layer",
        suggested_next_step: "Add a unique index on invoice_id",
        packet: %{"branch" => "fix/payment-retries", "changed_files" => ["lib/payment_worker.ex"]}
      })

    handoff
  end

  test "accept/1 changes handoff status, channel owner, and task owner atomically", ctx do
    %{channel: channel, task: task, agent: agent, target: target} = ctx
    Timeline.subscribe(channel.id)
    handoff = request(ctx)

    assert handoff.status == "requested"
    assert_receive {:timeline, %Timeline.Event{event_type: "handoff_requested", ref_id: id}}
    assert id == handoff.id
    assert [%{id: ^id}] = Handoffs.pending_for_channel(channel.id)

    assert {:ok, accepted} = Handoffs.accept(handoff)
    assert accepted.status == "accepted"
    assert %DateTime{} = accepted.accepted_at
    assert Channels.get!(channel.id).owner_agent_id == target.id
    assert Tasks.for_channel(channel.id).owner_agent_id == target.id
    assert Tasks.get!(task.id).owner_agent_id == target.id

    assert_receive {:timeline, %Timeline.Event{event_type: "handoff_accepted"} = accepted_event}
    assert accepted_event.agent.id == target.id
    assert_receive {:timeline, %Timeline.Event{event_type: "owner_changed"} = owner_event}
    assert owner_event.payload == %{"from_agent_id" => agent.id, "to_agent_id" => target.id}
    assert accepted_event.id < owner_event.id

    assert Handoffs.pending_for_channel(channel.id) == []
    assert {:error, :not_pending} = Handoffs.accept(Handoffs.get!(handoff.id))

    types = channel.id |> Timeline.list() |> Enum.map(& &1.event_type)
    assert types == ["handoff_requested", "handoff_accepted", "owner_changed"]
  end

  test "accept/1 still transfers channel ownership when the channel has no task", ctx do
    %{channel: channel, target: target} = ctx
    handoff = request(ctx)
    Repo.delete!(ctx.task)

    assert {:ok, %{status: "accepted"}} = Handoffs.accept(Handoffs.get!(handoff.id))
    assert Channels.get!(channel.id).owner_agent_id == target.id
    assert Tasks.for_channel(channel.id) == nil
  end

  test "reject/2 stores the reason and leaves ownership alone", ctx do
    %{channel: channel, agent: agent} = ctx
    Timeline.subscribe(channel.id)
    handoff = request(ctx)

    assert {:ok, rejected} = Handoffs.reject(handoff, "Not my area")
    assert rejected.status == "rejected"
    assert rejected.rejection_reason == "Not my area"
    assert Channels.get!(channel.id).owner_agent_id == agent.id
    assert_receive {:timeline, %Timeline.Event{event_type: "handoff_rejected"} = event}
    assert event.payload["reason"] == "Not my area"
    assert {:error, :not_pending} = Handoffs.reject(rejected, "again")
  end

  test "request/1 refuses a handoff to yourself", ctx do
    assert {:error, changeset} =
             Handoffs.request(%{
               channel_id: ctx.channel.id,
               from_agent_id: ctx.agent.id,
               to_agent_id: ctx.agent.id,
               summary: "loop"
             })

    assert %{to_agent_id: ["cannot hand off to yourself"]} = errors_on(changeset)
  end
end
