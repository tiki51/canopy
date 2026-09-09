defmodule Canopy.Runtime.ChannelServerTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{AgentSessions, Delegations, Handoffs, Messages, PermissionRequests, Timeline}
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.{Event, EventStream}
  alias Canopy.Runtime
  alias Canopy.Runtime.ChannelServer

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
    scenario = Fixtures.scenario(members: [reviewer])
    Timeline.subscribe(scenario.channel.id)

    # MCP registration is checked once per server; treat it as already registered.
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{reviewer: reviewer, pid: pid})}
  end

  defp expect_prompt(test_pid, n \\ 1) do
    expect(OC, :prompt_async, n, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)
  end

  defp oc_event(session_id, type, data),
    do: %Event{type: type, session_id: session_id, data: data, raw_type: "test"}

  defp emit(session_id, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(session_id),
      {:opencode_event, oc_event(session_id, type, data)}
    )
  end

  test "a user message wakes the owner on its existing session with the wake prompt and tools map",
       ctx do
    expect_prompt(self())

    {:ok, message} = Runtime.post_user_message(ctx.channel.id, "please look at the retries")

    sid = ctx.session.opencode_session_id
    assert_receive {:prompted, ^sid, body}, 2_000
    assert [%{type: "text", text: text}] = body.parts
    assert text =~ "Message ID: #{message.id}"
    refute text =~ "please look at the retries"
    assert body.tools == %{"canopy_*" => true}
    assert body.system =~ "@#{ctx.agent.name}"
    assert body.agent == "build"

    assert_receive {:timeline, %{event_type: "agent_started"}}, 1_000
    assert_receive {:agent_status, agent_id, :busy}, 1_000
    assert agent_id == ctx.agent.id
    assert %{status: "busy"} = AgentSessions.get!(ctx.session.id)
    assert ChannelServer.status(ctx.pid) == %{ctx.agent.id => :busy}
  end

  test "a mention wakes the mentioned member, creating its session and registering MCP once",
       ctx do
    reviewer = ctx.reviewer
    test_pid = self()

    expect(OC, :create_session, fn dir, %{title: title, agent: "build"}, _opts ->
      assert dir == ctx.repository.path
      assert title =~ "@#{reviewer.name}"
      {:ok, %{"id" => "ses_reviewer_new"}}
    end)

    expect_prompt(test_pid)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{reviewer.name} can you check this?")

    assert_receive {:prompted, "ses_reviewer_new", body}, 2_000
    assert body.system =~ "@#{reviewer.name}"

    assert %{opencode_session_id: "ses_reviewer_new"} =
             AgentSessions.get_root(ctx.channel.id, reviewer.id)
  end

  test "prompts queue while the agent is busy and drain when the turn completes", ctx do
    expect_prompt(self(), 2)
    sid = ctx.session.opencode_session_id

    {:ok, m1} = Runtime.post_user_message(ctx.channel.id, "first")
    assert_receive {:prompted, ^sid, %{parts: [%{text: t1}]}}, 2_000
    assert t1 =~ m1.id

    {:ok, m2} = Runtime.post_user_message(ctx.channel.id, "second")
    refute_receive {:prompted, ^sid, _}, 300

    emit(sid, :agent_completed, %{})
    assert_receive {:prompted, ^sid, %{parts: [%{text: t2}]}}, 2_000
    assert t2 =~ m2.id
  end

  test "execution events become telemetry, a stored reply, and a turn summary", ctx do
    expect_prompt(self())
    sid = ctx.session.opencode_session_id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive {:prompted, ^sid, _}, 2_000

    emit(sid, :tool_started, %{
      call_id: "c1",
      tool: "read",
      status: :running,
      input: %{},
      title: nil,
      message_id: "m",
      part_id: "p1"
    })

    emit(sid, :tool_completed, %{
      call_id: "c1",
      tool: "read",
      status: :ok,
      input: %{},
      title: "README.md",
      output: "...",
      error: nil,
      metadata: %{},
      time: %{},
      message_id: "m",
      part_id: "p1"
    })

    emit(sid, :file_changed, %{path: "/repo/lib/a.ex"})
    emit(sid, :text_done, %{message_id: "m", part_id: "p2", text: "Step 1: looking."})
    emit(sid, :text_done, %{message_id: "m", part_id: "p3", text: "I found the bug in a.ex."})
    emit(sid, :turn_usage, %{message_id: "m", cost: 0.0025, tokens: %{}, finish: "stop"})

    assert_receive {:telemetry, agent_id, %Event{type: :tool_completed}}, 1_000
    assert agent_id == ctx.agent.id

    assert [
             %Event{type: :tool_started},
             %Event{type: :tool_completed},
             %Event{type: :file_changed}
           ] = ChannelServer.telemetry(ctx.pid, ctx.agent.id)

    emit(sid, :agent_completed, %{})

    assert_receive {:timeline,
                    %{
                      event_type: "message",
                      message: %{kind: "reply", body: "I found the bug in a.ex."}
                    }},
                   2_000

    assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 2_000
    assert payload["tools"] == 1
    assert payload["files"] == ["/repo/lib/a.ex"]
    assert_in_delta payload["cost"], 0.0025, 0.00001
    assert payload["outcome"] == "ok"
    assert_receive {:agent_status, _, :idle}, 1_000
    assert %{status: "idle"} = AgentSessions.get!(ctx.session.id)
    assert ChannelServer.telemetry(ctx.pid, ctx.agent.id) == []
  end

  test "an agent error ends the turn with an error status and event", ctx do
    expect_prompt(self())
    sid = ctx.session.opencode_session_id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive {:prompted, ^sid, _}, 2_000

    emit(sid, :agent_error, %{
      error: %{"name" => "ProviderAuthError", "data" => %{"message" => "bad key"}}
    })

    assert_receive {:timeline, %{event_type: "agent_error", payload: %{"reason" => "bad key"}}},
                   2_000

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "error"}}},
                   2_000

    assert %{status: "error", last_error: "bad key"} = AgentSessions.get!(ctx.session.id)
  end

  test "permission requests are recorded from events and answered through the client", ctx do
    expect_prompt(self())
    sid = ctx.session.opencode_session_id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "edit something")
    assert_receive {:prompted, ^sid, _}, 2_000

    request = %{
      "id" => "per_123",
      "sessionID" => sid,
      "permission" => "edit",
      "patterns" => ["notes.txt"],
      "metadata" => %{"diff" => "+perm: test"},
      "tool" => %{"messageID" => "m", "callID" => "c9"}
    }

    emit(sid, :approval_required, %{request: request})
    assert_receive {:timeline, %{event_type: "permission_requested", ref_id: pr_id}}, 2_000

    pr = PermissionRequests.get!(pr_id)
    assert pr.status == "pending"
    assert pr.metadata["diff"] == "+perm: test"
    assert pr.tool_call_id == "c9"
    assert pr.agent_session_id == ctx.session.id

    expect(OC, :reply_permission, fn _dir, "per_123", :once, _opts -> {:ok, true} end)
    assert {:ok, %{status: "once"}} = Runtime.respond_permission(ctx.channel.id, pr.id, :once)
    assert_receive {:timeline, %{event_type: "permission_resolved"}}, 2_000

    # a late approval_resolved event for the same request is a no-op
    emit(sid, :approval_resolved, %{request_id: "per_123", reply: "once"})
    Process.sleep(50)
    assert PermissionRequests.get!(pr.id).status == "once"
  end

  test "a delegation creates a child session under the delegator and wakes the delegate; completion wakes the delegator",
       ctx do
    reviewer = ctx.reviewer
    parent_sid = ctx.session.opencode_session_id
    test_pid = self()

    expect(OC, :create_session, fn _dir, %{parentID: ^parent_sid, agent: "build"}, _opts ->
      {:ok, %{"id" => "ses_child_1"}}
    end)

    expect_prompt(test_pid, 2)

    {:ok, delegation} =
      Delegations.create(%{
        channel_id: ctx.channel.id,
        task_id: ctx.task.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: reviewer.id,
        description: "trace every enqueue path"
      })

    assert_receive {:prompted, "ses_child_1", %{parts: [%{text: text}]}}, 2_000
    assert text =~ "Delegation ID: #{delegation.id}"
    assert text =~ "trace every enqueue path"

    delegation = Delegations.get!(delegation.id)
    assert delegation.status == "working"
    child = AgentSessions.get!(delegation.child_session_id)
    assert child.parent_session_id == ctx.session.id
    assert child.agent_id == reviewer.id

    # the delegate finishes its turn: reply stored under the reviewer, then completes the delegation
    emit("ses_child_1", :text_done, %{message_id: "m", part_id: "p", text: "Found three paths."})
    emit("ses_child_1", :agent_completed, %{})

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"delegation_id" => did}}},
                   2_000

    assert did == delegation.id

    {:ok, _} = Delegations.complete(delegation, "Found three paths.")
    assert_receive {:prompted, ^parent_sid, %{parts: [%{text: wake}]}}, 2_000
    assert wake =~ "completed by @#{reviewer.name}"
    assert wake =~ "Found three paths."
  end

  test "a handoff wakes the target, and acceptance wakes the previous owner", ctx do
    reviewer = ctx.reviewer
    owner_sid = ctx.session.opencode_session_id
    test_pid = self()

    expect(OC, :create_session, fn _dir, _body, _opts -> {:ok, %{"id" => "ses_reviewer_ho"}} end)
    expect_prompt(test_pid, 2)

    {:ok, handoff} =
      Handoffs.request(%{
        channel_id: ctx.channel.id,
        task_id: ctx.task.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: reviewer.id,
        summary: "race isolated",
        reason: "needs db work",
        suggested_next_step: "add uniqueness"
      })

    assert_receive {:prompted, "ses_reviewer_ho", %{parts: [%{text: text}]}}, 2_000
    assert text =~ "Handoff ID: #{handoff.id}"

    # the reviewer finishes inspecting and accepts
    emit("ses_reviewer_ho", :agent_completed, %{})
    {:ok, _} = Handoffs.accept(Handoffs.get!(handoff.id))
    assert_receive {:prompted, ^owner_sid, %{parts: [%{text: text}]}}, 2_000
    assert text =~ "accepted your handoff"
    assert_receive {:timeline, %{event_type: "owner_changed"}}, 2_000

    # the server refreshed the channel: a user message now wakes the new owner
    expect_prompt(test_pid)
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "how is it going?")
    assert_receive {:prompted, "ses_reviewer_ho", _}, 2_000
  end

  test "abort goes to the agent's session and telemetry is empty for unknown agents", ctx do
    sid = ctx.session.opencode_session_id
    expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
    assert {:ok, true} = Runtime.abort(ctx.channel.id, ctx.agent.id)
    assert {:error, :no_session} = ChannelServer.abort(ctx.pid, "agt_nobody")
    assert Runtime.telemetry(ctx.channel.id, "agt_nobody") == []
  end

  test "MCP registration is added when missing and checked only once per server" do
    # a fresh channel whose server has not registered yet
    fresh = Fixtures.scenario()
    Timeline.subscribe(fresh.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{}} end)

    expect(OC, :add_mcp, fn _dir, "canopy", config, _opts ->
      assert config.type == "remote"
      assert config.url =~ "/mcp"
      assert config.headers["Authorization"] =~ "Bearer "
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    expect_prompt(self(), 2)
    {:ok, _} = Runtime.ensure_channel(fresh.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(fresh.channel.id) end)

    {:ok, _} = Runtime.post_user_message(fresh.channel.id, "one")
    assert_receive {:prompted, _, _}, 2_000
    emit(fresh.session.opencode_session_id, :agent_completed, %{})
    {:ok, _} = Runtime.post_user_message(fresh.channel.id, "two")
    assert_receive {:prompted, _, _}, 2_000
  end

  test "messages posted by agents through contexts route like any other", ctx do
    # an agent post mentioning the reviewer wakes the reviewer, not the poster
    reviewer = ctx.reviewer
    expect(OC, :create_session, fn _dir, _body, _opts -> {:ok, %{"id" => "ses_rev_2"}} end)
    expect_prompt(self())

    {:ok, _} =
      Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "@#{reviewer.name} please review")

    assert_receive {:prompted, "ses_rev_2", _}, 2_000
    refute_receive {:prompted, _, _}, 200
  end
end
