defmodule Canopy.PermissionRequestsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{GlobalPermissions, PermissionRequests, Timeline}
  alias Canopy.PermissionRequests.PermissionRequest

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

  describe "Allow globally" do
    setup do
      %{channel: channel, session: session, agent: agent} = scenario()
      Timeline.subscribe(channel.id)
      GlobalPermissions.subscribe()
      {:ok, channel: channel, session: session, agent: agent}
    end

    defp request(channel, session, id, permission) do
      {:ok, request} =
        PermissionRequests.record(%{
          channel_id: channel.id,
          agent_session_id: session.id,
          opencode_permission_id: id,
          permission: permission,
          patterns: ["make"]
        })

      request
    end

    test "resolve(:global) grants the tool in the same step and names the grant", ctx do
      first = request(ctx.channel, ctx.session, "per_g1", "Bash")

      assert {:ok, %{status: "global"}} = PermissionRequests.resolve(first, :global)
      grant = GlobalPermissions.get(ctx.agent.id, "bash")
      assert grant.channel_id == ctx.channel.id
      assert grant.label == "Bash"

      assert_receive {:timeline, %Timeline.Event{event_type: "permission_resolved"} = event}

      assert event.payload == %{
               "permission" => "Bash",
               "status" => "global",
               "grant_id" => grant.id
             }

      assert_receive {:global_permissions, :changed, agent_id}
      assert agent_id == ctx.agent.id

      # another card for the tool reuses the grant
      second = request(ctx.channel, ctx.session, "per_g2", "bash")
      assert {:ok, %{status: "global"}} = PermissionRequests.resolve(second, "global")
      assert [%{id: id}] = GlobalPermissions.list_for_agent(ctx.agent.id)
      assert id == grant.id
    end

    test "grant_check refuses what can't be granted", ctx do
      loop = request(ctx.channel, ctx.session, "per_l", "doom_loop")
      assert {:error, :not_grantable} = PermissionRequests.grant_check(loop)
      assert {:error, :not_grantable} = PermissionRequests.resolve(loop, :global)
      assert PermissionRequests.get!(loop.id).status == "pending"

      no_agent = %PermissionRequest{permission: "bash", agent_session_id: nil}
      assert {:error, :no_agent} = PermissionRequests.grant_check(no_agent)
      assert {:error, :no_agent} = PermissionRequests.resolve(no_agent, :global)

      assert {:ok, agent_id} =
               PermissionRequests.grant_check(request(ctx.channel, ctx.session, "per_b", "bash"))

      assert agent_id == ctx.agent.id
      assert GlobalPermissions.list_for_agent(ctx.agent.id) == []
    end

    test "auto_resolve closes a card with a line naming it and counts the use", ctx do
      card = request(ctx.channel, ctx.session, "per_s", "bash")
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "Bash")
      assert_receive {:global_permissions, :changed, _}

      assert {:ok, %{status: "auto", resolved_at: %DateTime{}}} =
               PermissionRequests.auto_resolve(card, grant)

      assert_receive {:timeline, %Timeline.Event{event_type: "permission_auto_approved"} = event}
      assert event.ref_id == grant.id
      assert event.in_channel

      assert event.payload == %{
               "permission" => "bash",
               "patterns" => ["make"],
               "grant_id" => grant.id,
               "request_id" => card.id
             }

      refute_received {:timeline, %Timeline.Event{event_type: "permission_resolved"}}
      assert_receive {:global_permissions, :changed, _}
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 1
    end

    test "waiting_for_agent_tool finds the agent's attached cards for the tool", ctx do
      bash = request(ctx.channel, ctx.session, "per_w1", "Bash")
      _edit = request(ctx.channel, ctx.session, "per_w2", "edit")
      {:ok, _} = PermissionRequests.detach(request(ctx.channel, ctx.session, "per_w3", "bash"))
      other = scenario()
      request(other.channel, other.session, "per_w4", "bash")

      assert [%{id: id}] = PermissionRequests.waiting_for_agent_tool(ctx.agent.id, "BASH")
      assert id == bash.id

      assert [_] =
               PermissionRequests.waiting_for_agent_tool(ctx.agent.id, "bash",
                 channel_id: ctx.channel.id
               )

      assert [] =
               PermissionRequests.waiting_for_agent_tool(ctx.agent.id, "bash",
                 channel_id: other.channel.id
               )
    end
  end
end
