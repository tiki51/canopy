defmodule Canopy.Runtime.ChannelServerGlobalPermissionsEdgesTest do
  @moduledoc """
  Allow globally, the edges: another repository, another agent, removal and
  Undo, tools that are never granted, a re-grant, and what a sweep leaves.
  """
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Fixtures, GlobalPermissions, PermissionRequests, Runtime, Timeline}
  alias Canopy.ClaudeCode.Prompts
  alias Canopy.Engine
  alias Canopy.GlobalPermissions.Grant
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream
  alias Canopy.PermissionRequests.PermissionRequest
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

  defp start_turn(channel, session) do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(channel.id, "go")
    assert_receive :prompted, 2_000
    session.engine_session_id
  end

  defp emit(sid, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: type, session_id: sid, data: data}}
    )
  end

  defp ask(sid, id, permission) do
    emit(sid, :approval_required, %{
      request: %{
        "id" => id,
        "sessionID" => sid,
        "permission" => permission,
        "patterns" => ["make"]
      }
    })
  end

  defp card(channel, session, id, permission) do
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

  defp use_once(grant, channel) do
    {:ok, _} =
      GlobalPermissions.record_use(grant, %{
        channel_id: channel.id,
        agent_id: grant.agent_id,
        permission: grant.label,
        patterns: []
      })
  end

  describe "auto-approval" do
    test "a grant made in one repository's channel covers a channel of another repository",
         ctx do
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "Bash", channel_id: ctx.channel.id)

      repo = Fixtures.repository_fixture()
      Canopy.MCP.mark_registered(repo.id)
      other = Fixtures.channel_fixture(%{repository_id: repo.id, owner_agent_id: ctx.agent.id})
      session = Fixtures.session_fixture(%{channel: other, agent_id: ctx.agent.id})
      Timeline.subscribe(other.id)
      {:ok, _} = Runtime.ensure_channel(other.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(other.id) end)

      sid = start_turn(other, session)

      expect(OC, :reply_permission, fn dir, "per_x", :once, _opts ->
        assert dir == repo.path
        {:ok, true}
      end)

      ask(sid, "per_x", "bash")

      other_id = other.id

      assert_receive {:timeline,
                      %{event_type: "permission_auto_approved", channel_id: ^other_id}},
                     2_000

      assert PermissionRequests.pending_for_channel(other.id) == []
      assert %{use_count: 1, channel_id: granted_in} = GlobalPermissions.get(ctx.agent.id, "bash")
      assert granted_in == ctx.channel.id
      assert GlobalPermissions.get(ctx.agent.id, "bash").id == grant.id
    end

    test "another agent's grant doesn't cover this agent", ctx do
      {:ok, _} = GlobalPermissions.grant(Fixtures.agent_fixture().id, "bash")
      sid = start_turn(ctx.channel, ctx.session)

      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)
      ask(sid, "per_other", "bash")

      assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000

      assert [%{opencode_permission_id: "per_other"}] =
               PermissionRequests.pending_for_channel(ctx.channel.id)
    end

    test "after a removal the agent asks again; after Undo it doesn't, and the count goes on",
         ctx do
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "bash")
      use_once(grant, ctx.channel)
      {:ok, removed} = GlobalPermissions.revoke(grant)
      sid = start_turn(ctx.channel, ctx.session)

      ask(sid, "per_after_remove", "bash")
      assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000

      {:ok, _} = GlobalPermissions.restore(removed)
      test_pid = self()

      expect(OC, :reply_permission, fn _dir, id, reply, _opts ->
        send(test_pid, {:replied, id, reply})
        {:ok, true}
      end)

      ask(sid, "per_after_undo", "bash")

      # (use_once's own line has no patterns)
      assert_receive {:timeline,
                      %{
                        event_type: "permission_auto_approved",
                        payload: %{"patterns" => ["make"]}
                      }},
                     2_000

      assert_received {:replied, "per_after_undo", :once}
      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 2
      # the card from before the Undo is not swept by the restore
      assert [%{opencode_permission_id: "per_after_remove", status: "pending"}] =
               PermissionRequests.pending_for_channel(ctx.channel.id)
    end

    test "a doom_loop row in the table never approves the repeated-call guard", ctx do
      Repo.insert!(%Grant{
        agent_id: ctx.agent.id,
        tool: "doom_loop",
        label: "doom_loop",
        granted_at: DateTime.utc_now()
      })

      sid = start_turn(ctx.channel, ctx.session)
      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)
      ask(sid, "per_loop", "doom_loop")

      assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
    end

    test "a question is never answered by a grant", ctx do
      for tool <- ~w(question askuserquestion) do
        Repo.insert!(%Grant{
          agent_id: ctx.agent.id,
          tool: tool,
          label: tool,
          granted_at: DateTime.utc_now()
        })
      end

      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")
      sid = start_turn(ctx.channel, ctx.session)
      expect(OC, :reply_question, 0, fn _dir, _id, _answers, _opts -> {:ok, true} end)

      emit(sid, :question_required, %{
        request: %{
          "id" => "que_g",
          "sessionID" => sid,
          "questions" => [
            %{
              "header" => "Width",
              "question" => "Which width?",
              "options" => [%{"label" => "390", "description" => "phone"}]
            }
          ],
          "tool" => %{"messageID" => "msg_1", "callID" => "call_1"}
        }
      })

      assert_receive {:timeline, %{event_type: "question_requested"}}, 2_000
      assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :awaiting_user}
      refute_received {:timeline, %{event_type: "permission_auto_approved"}}
    end
  end

  describe "Allow globally on a card" do
    test "when the agent already has the grant it keeps its id, date and count", ctx do
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "Bash", channel_id: ctx.channel.id)
      use_once(grant, ctx.channel)
      request = card(ctx.channel, ctx.session, "per_again", "bash")

      expect(OC, :reply_permission, fn _dir, "per_again", :once, _opts -> {:ok, true} end)

      assert {:ok, %{status: "global"}} =
               Runtime.respond_permission(ctx.channel.id, request.id, :global)

      assert %{id: id, granted_at: at, use_count: 1, label: "Bash"} =
               GlobalPermissions.get(ctx.agent.id, "bash")

      assert {id, at} == {grant.id, grant.granted_at}
      assert [_] = GlobalPermissions.list_for_agent(ctx.agent.id)
    end

    test "a card whose engine reply fails grants nothing and stays", ctx do
      request = card(ctx.channel, ctx.session, "per_fail", "bash")
      expect(OC, :reply_permission, fn _dir, "per_fail", :once, _opts -> {:error, :timeout} end)

      assert {:error, _} = Runtime.respond_permission(ctx.channel.id, request.id, :global)
      assert PermissionRequests.get!(request.id).status == "pending"
      assert GlobalPermissions.list_for_agent(ctx.agent.id) == []
    end

    test "the sweep leaves another agent's card for the same tool", ctx do
      other_agent = Fixtures.agent_fixture()
      other_session = Fixtures.session_fixture(%{channel: ctx.channel, agent_id: other_agent.id})
      answered = card(ctx.channel, ctx.session, "per_mine", "bash")
      theirs = card(ctx.channel, other_session, "per_theirs", "bash")

      expect(OC, :reply_permission, fn _dir, "per_mine", :once, _opts -> {:ok, true} end)
      assert {:ok, _} = Runtime.respond_permission(ctx.channel.id, answered.id, :global)
      # the self-sent sweep has run once a later call returns
      _ = ChannelServer.status(ctx.pid)

      assert PermissionRequests.get!(theirs.id).status == "pending"
    end

    test "Allow globally on two channels' cards at once makes one grant and closes both", ctx do
      other =
        Fixtures.channel_fixture(%{
          repository_id: ctx.repository.id,
          owner_agent_id: ctx.agent.id
        })

      other_session = Fixtures.session_fixture(%{channel: other, agent_id: ctx.agent.id})
      {:ok, other_pid} = Runtime.ensure_channel(other.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(other.id) end)

      a = card(ctx.channel, ctx.session, "per_ra", "bash")
      b = card(other, other_session, "per_rb", "Bash")
      test_pid = self()

      stub(OC, :reply_permission, fn _dir, id, :once, _opts ->
        send(test_pid, {:replied, id})
        {:ok, true}
      end)

      results =
        [{ctx.channel.id, a.id}, {other.id, b.id}]
        |> Enum.map(fn {cid, id} ->
          Task.async(fn -> Runtime.respond_permission(cid, id, :global) end)
        end)
        |> Task.await_many(5_000)

      _ = ChannelServer.status(ctx.pid)
      _ = ChannelServer.status(other_pid)

      assert [_] = GlobalPermissions.list_for_agent(ctx.agent.id)
      statuses = Enum.map([a, b], &PermissionRequests.get!(&1.id).status)
      assert Enum.all?(statuses, &(&1 in ["global", "auto"])), inspect({results, statuses})
      assert_received {:replied, "per_ra"}
      assert_received {:replied, "per_rb"}
      refute_received {:replied, _}
    end
  end

  describe "the context" do
    test "concurrent uses don't lose counts", ctx do
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "bash")

      1..10
      |> Task.async_stream(fn _ -> use_once(grant, ctx.channel) end, max_concurrency: 10)
      |> Stream.run()

      assert GlobalPermissions.get(ctx.agent.id, "bash").use_count == 10
    end

    test "names: Bash and bash are one grant, Write never covers OpenCode's edit", ctx do
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "Write")
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "WebFetch")
      {:ok, _} = GlobalPermissions.grant(ctx.agent.id, "bash")

      assert GlobalPermissions.match(ctx.agent.id, "edit") == nil
      assert GlobalPermissions.match(ctx.agent.id, "webfetch")
      assert GlobalPermissions.match(ctx.agent.id, "Bash")
    end

    test "a removal that finds nothing tells nobody", ctx do
      {:ok, grant} = GlobalPermissions.grant(ctx.agent.id, "bash")
      {:ok, _} = GlobalPermissions.revoke(grant)
      assert_receive {:global_permissions, :changed, _}
      assert_receive {:global_permissions, :changed, _}

      assert {:error, :not_found} = GlobalPermissions.revoke(grant.id)
      refute_receive {:global_permissions, :changed, _}, 100
    end

    test "an agent's grants go with it", ctx do
      agent = Fixtures.agent_fixture()
      {:ok, _} = GlobalPermissions.grant(agent.id, "bash", channel_id: ctx.channel.id)
      Repo.delete!(agent)
      assert Repo.all(Grant) |> Enum.filter(&(&1.agent_id == agent.id)) == []
    end
  end

  describe "Claude Code" do
    test "a late Allow globally is not remembered as a session Always" do
      sid = Ecto.UUID.generate()

      request = %PermissionRequest{
        opencode_permission_id: "toolu_gone_" <> Fixtures.unique_suffix(),
        permission: "Bash",
        agent_session: %{engine_session_id: sid}
      }

      assert {:error, :gone} = Engine.ClaudeCode.reply_permission(nil, nil, request, :global)
      assert Prompts.always_list(sid) == []

      # a late Always is, as before
      assert {:error, :gone} = Engine.ClaudeCode.reply_permission(nil, nil, request, :always)
      assert Prompts.always_list(sid) == ["Bash"]
    end
  end
end
