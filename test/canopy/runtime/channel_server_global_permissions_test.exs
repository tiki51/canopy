defmodule Canopy.Runtime.ChannelServerGlobalPermissionsTest do
  @moduledoc "Allow globally: the grant, auto-approval without a card, and the sweep."
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Fixtures, GlobalPermissions, Messages, PermissionRequests, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream
  alias Canopy.Runtime.ChannelServer

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()
    Timeline.subscribe(scenario.channel.id)
    GlobalPermissions.subscribe()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :pending_questions, fn _dir, _opts -> {:ok, []} end)
    Canopy.MCP.mark_registered(scenario.repository.id)
    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.put(scenario, :pid, pid)}
  end

  defp start_turn(ctx, opts \\ []) do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go", opts)
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

  defp ask(sid, id, permission, extra \\ %{}) do
    request =
      Map.merge(
        %{"id" => id, "sessionID" => sid, "permission" => permission, "patterns" => ["make"]},
        extra
      )

    emit(sid, :approval_required, %{request: request})
  end

  # a card recorded straight into the database, attached unless detached: true
  defp card(channel, session, id, permission, opts \\ []) do
    {:ok, request} =
      PermissionRequests.record(%{
        channel_id: channel.id,
        agent_session_id: session.id,
        opencode_permission_id: id,
        permission: permission,
        patterns: ["make"]
      })

    if opts[:detached] do
      {:ok, request} = PermissionRequests.detach(request)
      request
    else
      request
    end
  end

  defp flush do
    receive do
      {:timeline, _} -> flush()
      {:global_permissions, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp end_turn(sid) do
    emit(sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
  end

  describe "a prompt the agent's grant covers" do
    test "is answered Once with a line and no card", ctx do
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "Bash")
      sid = start_turn(ctx)
      flush()

      expect(OC, :reply_permission, fn _dir, "per_auto", :once, _opts -> {:ok, true} end)
      ask(sid, "per_auto", "bash", %{"patterns" => ["npm run build"]})

      assert_receive {:timeline,
                      %{event_type: "permission_auto_approved", payload: payload} = event},
                     2_000

      assert payload == %{
               "permission" => "bash",
               "patterns" => ["npm run build"],
               "grant_id" => grant.id
             }

      refute Map.has_key?(payload, "request_id")
      assert event.agent_id == ctx.agent.id
      assert event.ref_id == grant.id
      assert event.thread_id == nil
      assert event.in_channel

      assert_receive {:global_permissions, :changed, _}
      assert PermissionRequests.get_by_opencode_id("per_auto") == nil
      assert PermissionRequests.pending_for_channel(ctx.channel.id) == []
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 1
      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
      refute_received {:timeline, %{event_type: "permission_requested"}}
    end

    test "from a thread turn, records its line in that thread", ctx do
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")
      {:ok, root} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "Which width?")
      root_id = root.id
      sid = start_turn(ctx, thread_id: root_id)

      expect(OC, :reply_permission, fn _dir, "per_t", :once, _opts -> {:ok, true} end)
      ask(sid, "per_t", "bash")

      assert_receive {:timeline,
                      %{
                        event_type: "permission_auto_approved",
                        thread_id: ^root_id,
                        in_channel: false
                      }},
                     2_000
    end

    test "for another tool still shows a card", ctx do
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "edit")
      sid = start_turn(ctx)

      ask(sid, "per_card", "bash")
      assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000

      assert [%{opencode_permission_id: "per_card"}] =
               PermissionRequests.pending_for_channel(ctx.channel.id)
    end

    test "already showing as a card (a replay) keeps its card", ctx do
      sid = start_turn(ctx)
      ask(sid, "per_known", "bash")
      assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")

      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)

      emit(sid, :approval_required, %{
        request: %{"id" => "per_known", "sessionID" => sid, "permission" => "bash"},
        replay: true
      })

      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :awaiting_user}
      assert [%{status: "pending"}] = PermissionRequests.pending_for_channel(ctx.channel.id)
      refute_received {:timeline, %{event_type: "permission_auto_approved"}}
    end

    test "falls back to a card when the engine reply fails", ctx do
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")
      sid = start_turn(ctx)

      expect(OC, :reply_permission, fn _dir, "per_err", :once, _opts -> {:error, :timeout} end)
      ask(sid, "per_err", "bash")

      assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000

      assert [%{opencode_permission_id: "per_err"}] =
               PermissionRequests.pending_for_channel(ctx.channel.id)

      refute_received {:timeline, %{event_type: "permission_auto_approved"}}
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 0
    end

    test "delivered twice, is answered and counted once", ctx do
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")
      sid = start_turn(ctx)
      flush()

      expect(OC, :reply_permission, 1, fn _dir, "per_twice", :once, _opts -> {:ok, true} end)
      ask(sid, "per_twice", "bash")
      assert_receive {:timeline, %{event_type: "permission_auto_approved"}}, 2_000

      ask(sid, "per_twice", "bash")

      emit(sid, :approval_required, %{
        request: %{"id" => "per_twice", "sessionID" => sid, "permission" => "bash"},
        replay: true
      })

      # both deliveries handled: a call after them sees the state they left
      _ = ChannelServer.status(ctx.pid)

      refute_received {:timeline, %{event_type: "permission_auto_approved"}}
      refute_received {:timeline, %{event_type: "permission_requested"}}
      assert PermissionRequests.pending_for_channel(ctx.channel.id) == []
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 1
      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
    end

    test "records nothing when the engine no longer holds it", ctx do
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")
      sid = start_turn(ctx)
      flush()

      expect(OC, :reply_permission, fn _dir, "per_gone", :once, _opts ->
        {:error, {:http, 404, %{}}}
      end)

      ask(sid, "per_gone", "bash")
      # the reply ran: a call after it sees the state it left
      _ = ChannelServer.status(ctx.pid)

      assert PermissionRequests.pending_for_channel(ctx.channel.id) == []
      refute_received {:timeline, %{event_type: "permission_requested"}}
      refute_received {:timeline, %{event_type: "permission_auto_approved"}}
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 0
    end
  end

  describe "Allow globally on a card" do
    test "answers the engine Once, resolves the card as global and grants the tool", ctx do
      sid = start_turn(ctx)
      ask(sid, "per_g", "bash")
      assert_receive {:timeline, %{event_type: "permission_requested", ref_id: pr_id}}, 2_000

      expect(OC, :reply_permission, fn _dir, "per_g", :once, _opts -> {:ok, true} end)

      assert {:ok, %{status: "global"}} =
               Runtime.respond_permission(ctx.channel.id, pr_id, :global)

      grant = GlobalPermissions.get(ctx.agent.id, "bash")
      assert %{label: "bash", use_count: 0} = grant
      assert grant.channel_id == ctx.channel.id

      assert_receive {:timeline, %{event_type: "permission_resolved", payload: payload}}, 2_000
      assert payload == %{"permission" => "bash", "status" => "global", "grant_id" => grant.id}
      assert_receive {:global_permissions, :changed, _}
      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}

      # the next prompt for the tool needs no card
      expect(OC, :reply_permission, fn _dir, "per_next", :once, _opts -> {:ok, true} end)
      ask(sid, "per_next", "bash")
      assert_receive {:timeline, %{event_type: "permission_auto_approved"}}, 2_000
    end

    test "on a detached card posts the approval and still grants the tool", ctx do
      sid = start_turn(ctx)
      ask(sid, "per_late", "bash", %{"patterns" => ["make"]})
      assert_receive {:timeline, %{event_type: "permission_requested", ref_id: pr_id}}, 2_000
      end_turn(sid)
      flush()

      expect(OC, :reply_permission, fn _dir, "per_late", :once, _opts ->
        {:error, {:http, 404, %{}}}
      end)

      test_pid = self()

      expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
        send(test_pid, :woken)
        {:ok, ""}
      end)

      assert {:ok, %{status: "global"}} =
               Runtime.respond_permission(ctx.channel.id, pr_id, :global)

      assert_receive {:timeline, %{event_type: "message", message: message}}, 2_000

      assert message.body ==
               "@#{ctx.agent.name} Approved: bash make (globally: bash in every channel and project, until removed). You can do it now."

      assert_receive {:timeline,
                      %{
                        event_type: "permission_resolved",
                        payload: %{"delivered" => "message", "grant_id" => grant_id}
                      }},
                     2_000

      assert GlobalPermissions.get(ctx.agent.id, "bash").id == grant_id
      # the approval message wakes the agent
      assert_receive :woken, 2_000
    end

    test "is refused before the engine hears of it when the tool can't be granted", ctx do
      sid = start_turn(ctx)
      ask(sid, "per_loop", "doom_loop")
      assert_receive {:timeline, %{event_type: "permission_requested", ref_id: pr_id}}, 2_000

      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)

      assert {:error, :not_grantable} =
               Runtime.respond_permission(ctx.channel.id, pr_id, :global)

      assert %{status: "pending", detached_at: nil} = PermissionRequests.get!(pr_id)
      assert GlobalPermissions.list_for_agent(ctx.agent.id) == []
      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :awaiting_user}
    end

    test "is refused in an archived channel", ctx do
      request = card(ctx.channel, ctx.session, "per_arch", "bash")
      {:ok, _} = Canopy.Channels.archive(ctx.channel)
      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)

      assert {:error, :archived} =
               Runtime.respond_permission(ctx.channel.id, request.id, :global)

      assert GlobalPermissions.list_for_agent(ctx.agent.id) == []
    end
  end

  describe "the sweep" do
    setup ctx do
      other =
        Fixtures.channel_fixture(%{
          repository_id: ctx.repository.id,
          owner_agent_id: ctx.agent.id
        })

      other_session = Fixtures.session_fixture(%{channel: other, agent_id: ctx.agent.id})
      Timeline.subscribe(other.id)
      {:ok, other_pid} = Runtime.ensure_channel(other.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(other.id) end)
      {:ok, other: other, other_session: other_session, other_pid: other_pid}
    end

    test "approves the agent's attached cards for the tool in every channel", ctx do
      %{channel: here, session: session, other: other, other_session: other_session} = ctx
      answered = card(here, session, "per_a1", "Bash")
      sibling = card(here, session, "per_a2", "bash")
      elsewhere = card(other, other_session, "per_b1", "bash")
      detached = card(other, other_session, "per_b2", "bash", detached: true)
      edit = card(other, other_session, "per_b3", "edit")
      flush()

      test_pid = self()

      expect(OC, :reply_permission, 3, fn _dir, id, :once, _opts ->
        # a swept card is answered only after the answered one resolved
        if id != "per_a1",
          do: assert(PermissionRequests.get!(answered.id).status == "global")

        send(test_pid, {:replied, id})
        {:ok, true}
      end)

      assert {:ok, %{status: "global"}} =
               Runtime.respond_permission(here.id, answered.id, :global)

      assert_received {:replied, "per_a1"}
      assert_receive {:replied, "per_a2"}, 2_000
      assert_receive {:replied, "per_b1"}, 2_000

      grant = GlobalPermissions.get(ctx.agent.id, "bash")

      for {request, channel} <- [{sibling, here}, {elsewhere, other}] do
        request_id = request.id
        channel_id = channel.id

        assert_receive {:timeline,
                        %{
                          event_type: "permission_auto_approved",
                          channel_id: ^channel_id,
                          thread_id: nil,
                          in_channel: true,
                          payload: %{"request_id" => ^request_id} = payload
                        }},
                       2_000

        assert payload["grant_id"] == grant.id
        assert payload["permission"] == "bash"
        assert %{status: "auto", resolved_at: %DateTime{}} = PermissionRequests.get!(request_id)
      end

      for %{id: id} <- [sibling, elsewhere],
          do: refute_received({:timeline, %{event_type: "permission_resolved", ref_id: ^id}})

      assert_receive {:global_permissions, :changed, _}
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 2

      # detached cards and other tools stay for the user
      assert PermissionRequests.get!(detached.id).status == "pending"
      assert PermissionRequests.get!(edit.id).status == "pending"
    end

    test "a grant removed before the sweep lands approves nothing", ctx do
      card(ctx.other, ctx.other_session, "per_c1", "bash")
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "bash")
      {:ok, _} = GlobalPermissions.revoke(grant)

      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)
      ChannelServer.sweep_grant(ctx.other_pid, grant.id)
      _ = ChannelServer.status(ctx.other_pid)

      assert [%{status: "pending"}] = PermissionRequests.pending_for_channel(ctx.other.id)
    end

    test "a card whose engine reply fails stays pending", ctx do
      request = card(ctx.other, ctx.other_session, "per_d1", "bash")
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "bash")

      expect(OC, :reply_permission, fn _dir, "per_d1", :once, _opts -> {:error, :timeout} end)
      ChannelServer.sweep_grant(ctx.other_pid, grant.id)
      _ = ChannelServer.status(ctx.other_pid)

      assert PermissionRequests.get!(request.id).status == "pending"
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 0
    end
  end
end
