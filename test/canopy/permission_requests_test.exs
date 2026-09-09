defmodule Canopy.PermissionRequestsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{PermissionRequests, Timeline}

  test "record/1 is idempotent per OpenCode id and resolve/2 records the reply" do
    %{channel: channel, session: session, agent: agent} = scenario()
    Timeline.subscribe(channel.id)

    attrs = %{
      channel_id: channel.id,
      agent_session_id: session.id,
      opencode_permission_id: "per_1",
      permission: "bash",
      patterns: ["mix test"],
      metadata: %{"diff" => "--- a\n+++ b"},
      tool_call_id: "call_1"
    }

    assert {:ok, request} = PermissionRequests.record(attrs)
    assert request.status == "pending"
    assert request.agent_session.agent.id == agent.id
    assert {:ok, same} = PermissionRequests.record(attrs)
    assert same.id == request.id

    assert_receive {:timeline, %Timeline.Event{event_type: "permission_requested"} = event}
    assert event.agent.id == agent.id
    assert event.payload["patterns"] == ["mix test"]
    refute_receive {:timeline, %Timeline.Event{event_type: "permission_requested"}}

    assert [%{id: id}] = PermissionRequests.pending_for_channel(channel.id)
    assert id == request.id

    assert {:ok, resolved} = PermissionRequests.resolve(request, :always)
    assert resolved.status == "always"
    assert %DateTime{} = resolved.resolved_at
    assert_receive {:timeline, %Timeline.Event{event_type: "permission_resolved"} = event}
    assert event.payload["status"] == "always"
    assert PermissionRequests.pending_for_channel(channel.id) == []

    assert {:ok, %{status: "rejected"}} = PermissionRequests.resolve(resolved, :reject)
    assert PermissionRequests.get_by_opencode_id("per_1").metadata == %{"diff" => "--- a\n+++ b"}
  end
end
