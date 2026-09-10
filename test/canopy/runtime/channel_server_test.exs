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
    Canopy.MCP.mark_registered(scenario.repository.id)

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

  test "with pausing turned off, agents keep waking each other past the limit", ctx do
    {:ok, _} = Canopy.Settings.update(%{chatter_pause: false, chatter_limit: 1})
    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, _body, _opts ->
      send(test_pid, {:prompted, sid})
      {:ok, ""}
    end)

    owner_sid = ctx.session.opencode_session_id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive {:prompted, ^owner_sid}, 2_000
    emit(owner_sid, :agent_completed, %{})

    for _ <- 1..3 do
      {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "and another thing")
      assert_receive {:prompted, ^owner_sid}, 2_000
      emit(owner_sid, :agent_completed, %{})
    end

    refute_received {:chatter, :paused}
    refute Runtime.paused?(ctx.channel.id)
  end

  test "the chatter budget pauses agent-to-agent wakeups, and Continue or a user message resumes them",
       ctx do
    {:ok, _} = Canopy.Settings.update(%{chatter_pause: true, chatter_limit: 2})

    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    owner_sid = ctx.session.opencode_session_id

    # turn 1: the user's message wakes the owner
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "what do you think?")
    assert_receive {:prompted, ^owner_sid, _}, 2_000
    emit(owner_sid, :agent_completed, %{})

    # turn 2: the reviewer's unaddressed post wakes the owner (the budget's last turn)
    {:ok, _} =
      Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "I think it is the index.")

    assert_receive {:prompted, ^owner_sid, body}, 2_000
    assert [%{text: wake}] = body.parts
    assert wake =~ "from @#{ctx.reviewer.name}"
    emit(owner_sid, :agent_completed, %{})

    # turn 3 would exceed the budget: held, with a note and a broadcast, no prompt
    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "Also the scheduler.")
    assert_receive {:chatter, :paused}, 2_000

    assert_receive {:timeline, %{event_type: "message", message: %{kind: "system", body: note}}},
                   2_000

    assert note =~ "Paused after 2 agent turns"
    refute_receive {:prompted, _, _}, 300
    assert Runtime.paused?(ctx.channel.id)

    # Continue runs what was held
    assert :ok = Runtime.continue(ctx.channel.id)
    assert_receive {:chatter, :resumed}, 1_000
    assert_receive {:prompted, ^owner_sid, _}, 2_000
    refute Runtime.paused?(ctx.channel.id)
    emit(owner_sid, :agent_completed, %{})

    # a second pause, then the user's own message resets the budget and wakes the owner
    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "One more thing.")
    assert_receive {:prompted, ^owner_sid, _}, 2_000
    emit(owner_sid, :agent_completed, %{})
    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "And another.")
    assert_receive {:chatter, :paused}, 2_000
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "carry on")
    assert_receive {:chatter, :resumed}, 1_000
    assert_receive {:prompted, ^owner_sid, _}, 2_000
    refute Runtime.paused?(ctx.channel.id)
  end

  test "a turn that already posted through the tools keeps its closing text on the card, not as a reply",
       ctx do
    expect_prompt(self())
    sid = ctx.session.opencode_session_id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "what did you find?")
    assert_receive {:prompted, ^sid, _}, 2_000

    # the agent posts its findings itself, as message_send would
    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "Found it: the index.")
    assert_receive {:timeline, %{event_type: "message", message: %{kind: "post"}}}, 2_000

    emit(sid, :text_done, %{
      message_id: "m",
      part_id: "p9",
      text: "Posted my findings. Summary: the index."
    })

    emit(sid, :agent_completed, %{})

    assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 2_000
    assert payload["final_text"] == "Posted my findings. Summary: the index."
    refute_receive {:timeline, %{event_type: "message", message: %{kind: "reply"}}}, 300
  end

  test "a passed turn posts no reply and the summary says so", ctx do
    expect_prompt(self())
    sid = ctx.session.opencode_session_id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "thanks, all good")
    assert_receive {:prompted, ^sid, _}, 2_000

    assert :ok = Runtime.pass(ctx.channel.id, sid, "just an acknowledgement")
    assert {:error, :no_turn} = Runtime.pass(ctx.channel.id, "ses_nope", nil)

    emit(sid, :text_done, %{message_id: "m", part_id: "p1", text: "Acknowledged, nothing to do."})
    emit(sid, :agent_completed, %{})

    assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 2_000
    assert payload["passed"] == true
    assert payload["note"] == "just an acknowledgement"
    refute_receive {:timeline, %{event_type: "message", message: %{kind: "reply"}}}, 300
    assert_receive {:agent_status, _, :idle}, 1_000
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

    # file.edited has no session id on the wire; it must still land on the busy turn
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.repository_topic(ctx.repository.id),
      {:opencode_event, oc_event(nil, :file_changed, %{path: "/repo/lib/a.ex"})}
    )

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

    assert [
             %{"kind" => "tool", "status" => "ok", "label" => "README.md"},
             %{"kind" => "file", "label" => "a.ex", "detail" => "/repo/lib/a.ex"}
           ] = payload["activity"]

    # the summary is recorded before the reply so its card sits above the message
    [summary, reply] =
      Timeline.list(ctx.channel.id, types: ["agent_turn_completed", "message"]) |> Enum.take(-2)

    assert summary.event_type == "agent_turn_completed"
    assert reply.event_type == "message"
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

  test "MCP registration is added when missing, and once per boot even when OpenCode still has one" do
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

    # A second channel in the same repository, this boot: nothing to re-post.
    sibling =
      Fixtures.channel_fixture(%{
        repository_id: fresh.repository.id,
        owner_agent_id: fresh.agent.id
      })

    Fixtures.session_fixture(%{channel: sibling, agent_id: fresh.agent.id})
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    expect_prompt(self())
    {:ok, _} = Runtime.ensure_channel(sibling.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(sibling.id) end)
    {:ok, _} = Runtime.post_user_message(sibling.id, "three")
    assert_receive {:prompted, _, _}, 2_000

    # A registration left over from an earlier Canopy boot is reposted so
    # OpenCode picks up the current tool list.
    stale = Fixtures.scenario()
    Timeline.subscribe(stale.channel.id)

    expect(OC, :add_mcp, fn _dir, "canopy", _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    expect_prompt(self())
    {:ok, _} = Runtime.ensure_channel(stale.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(stale.channel.id) end)
    {:ok, _} = Runtime.post_user_message(stale.channel.id, "four")
    assert_receive {:prompted, _, _}, 2_000
    assert Canopy.MCP.registered_this_boot?(stale.repository.id)
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

defmodule Canopy.Runtime.ChannelServerReconcileTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{AgentSessions, Fixtures, PermissionRequests, Runtime, Settings, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()
    Timeline.subscribe(scenario.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(scenario.repository.id)
    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.put(scenario, :pid, pid)}
  end

  # the first connect after start is ignored (nothing to reconcile); a second one reconciles
  defp reconnect(repo_id) do
    for _ <- 1..2 do
      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        EventStream.repository_topic(repo_id),
        {:opencode_stream, :connected, repo_id}
      )
    end
  end

  test "a reconnect finishes turns OpenCode no longer reports as busy and records missed permissions",
       ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive :prompted, 2_000
    sid = ctx.session.opencode_session_id

    # OpenCode says: nothing busy, one permission pending for our session
    # age the turn past the grace period so reconciliation may finish it
    :sys.replace_state(ctx.pid, fn st ->
      %{
        st
        | turns: Map.new(st.turns, fn {k, t} -> {k, %{t | started_at: t.started_at - 60_000}} end)
      }
    end)

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)

    expect(OC, :pending_permissions, fn _dir, _opts ->
      {:ok,
       [
         %{
           "id" => "per_missed",
           "sessionID" => sid,
           "permission" => "edit",
           "patterns" => ["x.ex"],
           "metadata" => %{}
         }
       ]}
    end)

    reconnect(ctx.repository.id)

    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    assert_receive {:timeline, %{event_type: "permission_requested"}}, 2_000
    assert %{status: "idle"} = AgentSessions.get!(ctx.session.id)

    assert [%{opencode_permission_id: "per_missed", status: "pending"}] =
             PermissionRequests.pending_for_channel(ctx.channel.id)

    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :idle}
  end

  test "a reconnect leaves a turn alone when OpenCode still reports it busy and tolerates a 400 on permissions",
       ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive :prompted, 2_000
    sid = ctx.session.opencode_session_id

    expect(OC, :session_status, fn _dir, _opts -> {:ok, %{sid => %{"type" => "busy"}}} end)

    expect(OC, :pending_permissions, fn _dir, _opts ->
      {:error, {:http, 400, %{"name" => "BadRequest"}}}
    end)

    reconnect(ctx.repository.id)
    Process.sleep(100)
    assert Runtime.status(ctx.channel.id) == %{ctx.agent.id => :busy}
    refute_received {:timeline, %{event_type: "agent_turn_completed"}}
  end

  test "rotating the MCP token makes the next prompt re-register", ctx do
    test_pid = self()

    expect(OC, :prompt_async, 2, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "one")
    assert_receive :prompted, 2_000
    emit_idle(ctx.session.opencode_session_id)

    {:ok, _} = Settings.rotate_mcp_token()
    new_token = Settings.mcp_token()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{}} end)

    expect(OC, :add_mcp, fn _dir, "canopy", config, _opts ->
      assert config.headers["Authorization"] == "Bearer " <> new_token
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "two")
    assert_receive :prompted, 2_000
  end

  defp emit_idle(sid) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(sid),
      {:opencode_event,
       %Canopy.OpenCode.Event{type: :agent_completed, session_id: sid, data: %{}}}
    )

    Process.sleep(50)
  end
end

defmodule Canopy.Runtime.ChannelServerErrorsTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Fixtures, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.{Event, EventStream}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()
    Timeline.subscribe(scenario.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(scenario.repository.id)
    {:ok, _} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, scenario}
  end

  defp emit(session_id, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(session_id),
      {:opencode_event, %Event{type: type, session_id: session_id, data: data, raw_type: "test"}}
    )
  end

  test "activity after session.idle and empty diffs do not reopen telemetry", ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive :prompted, 2_000
    sid = ctx.session.opencode_session_id
    # An empty session.diff during the turn is noise, not a telemetry entry.
    emit(sid, :diff, %{files: []})
    emit(sid, :tool_started, %{call_id: "c1", tool: "read", status: :running, input: %{}})
    assert_receive {:telemetry, _, %Event{type: :tool_started}}, 1_000
    refute_received {:telemetry, _, %Event{type: :diff}}

    emit(sid, :agent_completed, %{})
    assert_receive {:agent_status, agent_id, :idle}, 2_000

    # OpenCode keeps talking after idle: none of it may resurrect the working card.
    emit(sid, :diff, %{files: [%{"file" => "a.ex"}]})
    emit(sid, :tool_completed, %{call_id: "c2", tool: "read", status: :ok, input: %{}})
    emit(sid, :text_delta, %{delta: "late", message_id: "m", part_id: "p"})

    refute_receive {:telemetry, _, _}, 300
    assert Runtime.telemetry(ctx.channel.id, agent_id) == []
  end

  test "repeated session errors record one concise agent_error per turn", ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "go")
    assert_receive :prompted, 2_000
    sid = ctx.session.opencode_session_id

    error = %{
      "name" => "ProviderModelNotFoundError",
      "data" => %{
        "message" =>
          "Model not found: anthropic/claude-sonnet-4-5. Did you mean: claude-sonnet-4-5?\n    at SessionPrompt.getModel (/chunk.js:1085:11482)\n    at more (/chunk.js:1)"
      }
    }

    for _ <- 1..4 do
      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        EventStream.session_topic(sid),
        {:opencode_event, %Event{type: :agent_error, session_id: sid, data: %{error: error}}}
      )
    end

    assert_receive {:timeline, %{event_type: "agent_error", payload: %{"reason" => reason}}},
                   2_000

    assert reason ==
             "Model not found: anthropic/claude-sonnet-4-5. Did you mean: claude-sonnet-4-5? (check the agent's model provider and id on the Agents page)"

    refute reason =~ "at SessionPrompt"

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", payload: %{"outcome" => "error"}}},
                   2_000

    refute_receive {:timeline, %{event_type: "agent_error"}}, 300
    refute_receive {:timeline, %{event_type: "agent_turn_completed"}}, 100
  end
end
