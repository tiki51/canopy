defmodule Canopy.Engine.CrossEngineTest do
  @moduledoc "OpenCode and Claude Code agents in one channel: delegation both ways, scheduled wakes."
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{AgentSessions, Delegations, Fixtures, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

  @fake Path.expand("../../support/fake_claude.sh", __DIR__)

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    dir = Path.join([File.cwd!(), "_build", "test", "tmp", "cross-" <> Fixtures.unique_suffix()])
    File.mkdir_p!(dir)
    log = Path.join(dir, "calls.log")
    script = Path.join(dir, "script.jsonl")

    File.write!(
      script,
      Enum.map_join(
        [
          %{
            type: "system",
            subtype: "init",
            session_id: "SESSION_ID",
            model: "claude-haiku-4-5",
            mcp_servers: []
          },
          %{
            type: "stream_event",
            session_id: "SESSION_ID",
            event: %{type: "message_start", message: %{id: "msg_1", usage: %{input_tokens: 5}}}
          },
          %{
            type: "assistant",
            session_id: "SESSION_ID",
            message: %{id: "msg_1", content: [%{type: "text", text: "Done."}]}
          },
          %{
            type: "stream_event",
            session_id: "SESSION_ID",
            event: %{
              type: "message_delta",
              usage: %{output_tokens: 2},
              delta: %{stop_reason: "end_turn"}
            }
          },
          %{
            type: "result",
            subtype: "success",
            is_error: false,
            num_turns: 1,
            result: "Done.",
            session_id: "SESSION_ID",
            total_cost_usd: 0.002,
            usage: %{input_tokens: 5, output_tokens: 2}
          }
        ],
        "\n",
        &JSON.encode!/1
      ) <> "\n"
    )

    previous = Application.get_env(:canopy, :claude_code)

    Application.put_env(:canopy, :claude_code,
      # never the real ~/.claude
      default_config_dir: Application.get_env(:canopy, :claude_code)[:default_config_dir],
      binary: @fake,
      env: [{"FAKE_CLAUDE_SCRIPT", script}, {"FAKE_CLAUDE_LOG", log}]
    )

    on_exit(fn ->
      Application.put_env(:canopy, :claude_code, previous)
      File.rm_rf!(dir)
    end)

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    coder =
      Fixtures.agent_fixture(%{name: "coder" <> Fixtures.unique_suffix(), engine: "claude_code"})

    scenario = Fixtures.scenario(members: [coder])
    Canopy.MCP.mark_registered(scenario.repository.id)
    Timeline.subscribe(scenario.channel.id)
    {:ok, _} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{coder: coder, log: log})}
  end

  test "an OpenCode owner delegates to a Claude Code agent: the work runs in the delegate's Claude session",
       ctx do
    {:ok, delegation} =
      Delegations.create(%{
        channel_id: ctx.channel.id,
        task_id: ctx.task.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: ctx.coder.id,
        description: "list every retry path"
      })

    assert_receive {:timeline,
                    %{
                      event_type: "agent_turn_completed",
                      payload: %{"delegation_id" => did, "cost" => 0.002} = payload
                    }},
                   10_000

    assert did == delegation.id

    session = AgentSessions.get!(Delegations.get!(delegation.id).child_session_id)

    # where the turn sits in the Claude Code transcript: the API message ids
    assert payload["engine_session_id"] == session.engine_session_id
    assert payload["engine_message_ids"] == %{"first" => "msg_1", "last" => "msg_1"}
    assert session.id == AgentSessions.get_root(ctx.channel.id, ctx.coder.id).id
    assert session.engine == "claude_code"
    assert is_nil(session.parent_session_id)
    assert is_binary(session.mcp_token)

    stdin =
      ctx.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "STDIN "))

    assert stdin =~ "Delegation ID: #{delegation.id}"
    assert stdin =~ "list every retry path"
  end

  test "a Claude Code owner delegates to an OpenCode agent: the delegate's own OpenCode session",
       ctx do
    test_pid = self()
    helper = Fixtures.agent_fixture(%{name: "helper" <> Fixtures.unique_suffix()})

    channel =
      Fixtures.channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.coder.id,
        agent_ids: [helper.id]
      })

    Timeline.subscribe(channel.id)
    {:ok, _} = Runtime.ensure_channel(channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(channel.id) end)

    expect(OC, :create_session, fn _dir, body, _opts ->
      send(test_pid, {:created, body})
      {:ok, %{"id" => "ses_helper"}}
    end)

    expect(OC, :prompt_async, fn _dir, sid, _body, _opts ->
      send(test_pid, {:prompted, sid})
      {:ok, ""}
    end)

    # the Claude Code owner's own session is created on its first wake
    {:ok, _} = Runtime.post_user_message(channel.id, "hello owner")
    assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: owner_id}}, 10_000
    assert owner_id == ctx.coder.id
    owner_session = AgentSessions.get_root(channel.id, ctx.coder.id)
    assert owner_session.engine == "claude_code"

    {:ok, _} =
      Delegations.create(%{
        channel_id: channel.id,
        task_id: Canopy.Channels.get!(channel.id).task.id,
        from_agent_id: ctx.coder.id,
        to_agent_id: helper.id,
        description: "check the tests"
      })

    assert_receive {:created, body}, 5_000
    refute Map.has_key?(body, :parentID)
    assert_receive {:prompted, "ses_helper"}, 5_000

    assert [session] =
             Enum.filter(AgentSessions.list_for_channel(channel.id), &(&1.agent_id == helper.id))

    assert session.engine == "opencode"
    assert is_nil(session.parent_session_id)
  end

  describe "the default engine changes under an agent" do
    defp stdin(log) do
      log
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "STDIN "))
      |> Enum.join("\n")
    end

    defp emit_idle(sid) do
      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        Canopy.OpenCode.EventStream.session_topic(sid),
        {:engine_event, %Canopy.Engine.Event{type: :agent_completed, session_id: sid, data: %{}}}
      )
    end

    test "its next wake starts a fresh session on the new engine, with a line saying why",
         ctx do
      old = ctx.session
      assert ctx.agent.engine == nil
      assert old.engine == "opencode"

      # the OpenCode session is never prompted again
      expect(OC, :prompt_async, 0, fn _dir, _sid, _body, _opts -> {:ok, ""} end)

      {:ok, _} = Canopy.Settings.put_default_engine("claude_code")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "hello after the switch")

      assert_receive {:timeline,
                      %{event_type: "session_reset", agent_id: agent_id, payload: payload}},
                     5_000

      assert agent_id == ctx.agent.id

      assert %{
               "by" => "engine_change",
               "from_engine" => "opencode",
               "to_engine" => "claude_code",
               "engine" => "opencode",
               "engine_session_id" => old_sid
             } = payload

      assert old_sid == old.engine_session_id

      assert_receive {:timeline,
                      %{
                        event_type: "agent_turn_completed",
                        agent_id: ^agent_id,
                        payload: %{"cost" => 0.002}
                      }},
                     10_000

      new = AgentSessions.get_root(ctx.channel.id, ctx.agent.id)
      assert new.engine == "claude_code"
      refute new.id == old.id
      assert is_binary(new.mcp_token)
      assert stdin(ctx.log) =~ "hello after the switch"

      # the agent itself still follows the default
      assert Canopy.Agents.get!(ctx.agent.id).engine == nil
    end

    test "a turn in flight keeps its session; the wake queued behind it starts fresh", ctx do
      test_pid = self()
      old = ctx.session

      stub(OC, :session_status, fn _dir, _opts -> {:ok, %{}} end)
      stub(OC, :pending_permissions, fn _dir, _opts -> {:ok, []} end)

      # exactly one OpenCode prompt: the turn that was already running
      expect(OC, :prompt_async, 1, fn _dir, sid, _body, _opts ->
        send(test_pid, {:oc_prompted, sid})
        {:ok, ""}
      end)

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "first, on OpenCode")
      assert_receive {:oc_prompted, sid}, 5_000
      assert sid == old.engine_session_id

      {:ok, _} = Canopy.Settings.put_default_engine("claude_code")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "second, after the switch")

      # nothing moves while the OpenCode turn runs
      refute_receive {:timeline, %{event_type: "session_reset"}}, 300
      assert AgentSessions.get_root(ctx.channel.id, ctx.agent.id).id == old.id

      emit_idle(sid)

      assert_receive {:timeline,
                      %{event_type: "session_reset", payload: %{"by" => "engine_change"}}},
                     5_000

      assert_receive {:timeline,
                      %{event_type: "agent_turn_completed", payload: %{"cost" => 0.002}}},
                     10_000

      assert AgentSessions.get_root(ctx.channel.id, ctx.agent.id).engine == "claude_code"
      assert stdin(ctx.log) =~ "second, after the switch"
    end

    test "an agent with an engine of its own keeps its session", ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} first")

      assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: coder_id}},
                     10_000

      assert coder_id == ctx.coder.id
      session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)

      {:ok, _} = Canopy.Settings.put_default_engine("opencode")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} second")

      assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^coder_id}},
                     10_000

      refute_received {:timeline, %{event_type: "session_reset"}}
      assert AgentSessions.get_root(ctx.channel.id, ctx.coder.id).id == session.id
    end
  end

  test "a scheduled wake runs a Claude Code turn with the scheduled trigger", ctx do
    :ok =
      Runtime.wake_scheduled(ctx.channel.id, ctx.coder.id, "Nightly check: is the build green?")

    assert_receive {:timeline,
                    %{
                      event_type: "agent_turn_completed",
                      agent_id: agent_id,
                      payload: %{"trigger" => "scheduled"}
                    }},
                   10_000

    assert agent_id == ctx.coder.id

    stdin =
      ctx.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "STDIN "))

    assert stdin =~ "Nightly check"
  end
end
