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
            type: "assistant",
            session_id: "SESSION_ID",
            message: %{id: "msg_1", content: [%{type: "text", text: "Done."}]}
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

  test "an OpenCode owner delegates to a Claude Code agent: a Claude child session, linked to the parent",
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
                      payload: %{"delegation_id" => did, "cost" => 0.002}
                    }},
                   10_000

    assert did == delegation.id

    child = AgentSessions.get!(Delegations.get!(delegation.id).child_session_id)
    assert child.engine == "claude_code"
    assert child.agent_id == ctx.coder.id
    assert child.parent_session_id == ctx.session.id
    assert is_binary(child.mcp_token)

    stdin =
      ctx.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "STDIN "))

    assert stdin =~ "Delegation ID: #{delegation.id}"
    assert stdin =~ "list every retry path"
  end

  test "a Claude Code owner delegates to an OpenCode agent: the OpenCode child has no parent id",
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
      {:ok, %{"id" => "ses_helper_child"}}
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
    assert_receive {:prompted, "ses_helper_child"}, 5_000

    child = Enum.find(AgentSessions.list_for_channel(channel.id), &(&1.agent_id == helper.id))
    assert child.engine == "opencode"
    assert child.parent_session_id == owner_session.id
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
