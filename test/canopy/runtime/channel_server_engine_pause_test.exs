defmodule Canopy.Runtime.ChannelServerEnginePauseTest do
  @moduledoc """
  An engine that hits a usage or billing limit pauses (`Canopy.EnginePauses`):
  its agents move to their fallback model (`Canopy.Fallback`) in a second
  session, or wait for the reset. Claude Code turns run the fake CLI (its
  limit read from the stream); OpenCode, the fallback, is a Mox double.
  """
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.RuntimeHelpers, only: [settle: 0]

  alias Canopy.{
    AgentSessions,
    Agents,
    EnginePauses,
    Fixtures,
    Messages,
    Runtime,
    Schedules,
    Timeline
  }

  alias Canopy.Engine.Event
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream
  alias Canopy.Runtime.ChannelServer

  @fake Path.expand("../../support/fake_claude.sh", __DIR__)
  @fixtures Path.expand("../../support/claude_code_fixtures", __DIR__)
  @fallback "opencode:opencode/gpt-5-nano"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    dir = Path.join([File.cwd!(), "_build", "test", "tmp", "pause-" <> Fixtures.unique_suffix()])
    File.mkdir_p!(dir)
    previous = Application.get_env(:canopy, :claude_code)

    on_exit(fn ->
      Application.put_env(:canopy, :claude_code, previous)
      File.rm_rf!(dir)
    end)

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    coder =
      Fixtures.agent_fixture(%{
        name: "coder" <> Fixtures.unique_suffix(),
        engine: "claude_code",
        model_id: "opus",
        fallback: @fallback
      })

    scenario = Fixtures.scenario(members: [coder])
    Canopy.MCP.mark_registered(scenario.repository.id)
    Timeline.subscribe(scenario.channel.id)
    ctx = Map.merge(scenario, %{coder: coder, dir: dir, previous: previous})
    claude_script(ctx, "usage-limit.jsonl")
    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.put(ctx, :pid, pid)}
  end

  # The fake Claude Code plays `name` (a fixture, or a script written here).
  defp claude_script(ctx, name) do
    script = if File.exists?(name), do: name, else: Path.join(@fixtures, name)

    Application.put_env(:canopy, :claude_code,
      default_config_dir: ctx.previous[:default_config_dir],
      binary: @fake,
      env: [{"FAKE_CLAUDE_SCRIPT", script}]
    )
  end

  defp done_script(ctx, text) do
    path = Path.join(ctx.dir, "done-#{Fixtures.unique_suffix()}.jsonl")

    File.write!(
      path,
      Enum.map_join(
        [
          %{
            type: "system",
            subtype: "init",
            session_id: "SESSION_ID",
            model: "claude-opus-4",
            mcp_servers: []
          },
          %{
            type: "assistant",
            session_id: "SESSION_ID",
            message: %{id: "msg_1", content: [%{type: "text", text: text}]}
          },
          %{
            type: "result",
            subtype: "success",
            is_error: false,
            num_turns: 1,
            result: text,
            session_id: "SESSION_ID",
            total_cost_usd: 0.002,
            usage: %{input_tokens: 5, output_tokens: 2}
          }
        ],
        "\n",
        &JSON.encode!/1
      ) <> "\n"
    )

    path
  end

  defp expect_fallback_session(test_pid, sid \\ "ses_fb") do
    expect(OC, :create_session, fn _dir, _body, _opts ->
      send(test_pid, {:created, sid})
      {:ok, %{"id" => sid}}
    end)
  end

  defp stub_prompts(test_pid) do
    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)
  end

  defp emit(session_id, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(session_id),
      {:engine_event, %Event{type: type, session_id: session_id, data: data, raw_type: "test"}}
    )
  end

  defp finish_oc(sid, text) do
    emit(sid, :text_done, %{message_id: "m", part_id: "p", text: text})
    emit(sid, :agent_completed, %{})
  end

  defp prompt_text(%{parts: [%{text: text} | _]}), do: text

  defp flush_timeline do
    receive do
      {:timeline, _} -> flush_timeline()
    after
      0 -> :ok
    end
  end

  test "a limit with a fallback: the wake reruns on it in a second session, its messages are marked, and after the reset the next wake is on the primary",
       ctx do
    test_pid = self()
    expect_fallback_session(test_pid)
    stub_prompts(test_pid)
    cid = ctx.coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} fix the retry bug")

    assert_receive {:timeline, %{event_type: "engine_fallback", agent_id: ^cid, payload: p}},
                   10_000

    assert p["hit"] == true
    assert p["new_session"] == true
    assert p["from_engine"] == "claude_code"
    assert p["from_model"] == "opus"
    assert p["to_engine"] == "opencode"
    assert p["to_model"] == "opencode/gpt-5-nano"
    assert p["reason"] == "usage limit"
    assert is_binary(p["resets_at"])
    refute_received {:timeline, %{event_type: "agent_error"}}

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", agent_id: ^cid, payload: hit}},
                   2_000

    assert hit["engine"] == "claude_code"
    assert hit["limit"]["kind"] == "usage"

    assert_receive {:prompted, "ses_fb", body}, 5_000

    assert prompt_text(body) =~
             "You were moved from Claude Code (usage limit). Read the channel to catch up."

    assert prompt_text(body) =~ "fix the retry bug"

    fallback = AgentSessions.get_fallback_root(ctx.channel.id, cid)

    assert %{engine: "opencode", fallback_of: "claude_code", engine_session_id: "ses_fb"} =
             fallback

    assert %{engine: "claude_code"} = primary = AgentSessions.get_root(ctx.channel.id, cid)
    assert %{waiting: 0, on_fallback: 1} = EnginePauses.get("claude_code")

    finish_oc("ses_fb", "Fixed on the fallback.")

    assert_receive {:timeline,
                    %{event_type: "agent_turn_completed", agent_id: ^cid, payload: done}},
                   2_000

    marker = %{
      "engine" => "opencode",
      "model" => "opencode/gpt-5-nano",
      "from_engine" => "claude_code"
    }

    assert done["fallback"] == marker
    assert done["engine"] == "opencode"

    assert_receive {:timeline,
                    %{event_type: "message", message: %{body: "Fixed on the fallback."} = m}},
                   2_000

    assert Messages.get!(m.id).fallback == marker

    # the reset: back to the primary session, the fallback root dropped
    claude_script(ctx, done_script(ctx, "Back on opus."))
    :ok = EnginePauses.resume("claude_code", "reset")

    assert_receive {:timeline, %{event_type: "engine_resumed", payload: r}}, 2_000
    assert r["returned"] == [%{"agent_id" => cid, "model" => "opus"}]
    assert r["nudged"] == []

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} anything else?")

    assert_receive {:timeline, %{event_type: "message", message: %{body: "Back on opus."}}},
                   10_000

    assert AgentSessions.get_root(ctx.channel.id, cid).id == primary.id
    assert AgentSessions.get_fallback_root(ctx.channel.id, cid) == nil
    refute_received {:prompted, _, _}
  end

  test "a limit with no fallback: the agent waits with a nudge; later wakes are dropped with one line",
       ctx do
    {:ok, coder} = Agents.update(ctx.coder, %{fallback: "none"})
    cid = coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} fix it")

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid, payload: p}}, 10_000
    assert p["engine"] == "claude_code"
    assert p["fallback_unavailable"] == nil
    assert is_binary(p["nudge_at"])

    assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^cid}}, 2_000

    assert [%{source: "auto", status: "active"} = nudge] =
             Schedules.list_for_agent(cid) |> Enum.filter(&(&1.source == "auto"))

    assert nudge.source_ref == EnginePauses.get("claude_code").id
    assert %{waiting: 1, on_fallback: 0} = EnginePauses.get("claude_code")
    flush_timeline()

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} hello?")
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} anyone?")

    assert_receive {:timeline, %{event_type: "engine_wake_dropped", agent_id: ^cid, payload: d}},
                   2_000

    assert d["engine"] == "claude_code"
    settle()
    refute_received {:timeline, %{event_type: "engine_wake_dropped"}}
    refute_received {:timeline, %{event_type: "agent_started", agent_id: ^cid}}
  end

  test "a fallback turn that hits a limit pauses the fallback's engine too; the agent then waits once",
       ctx do
    test_pid = self()
    expect_fallback_session(test_pid)
    stub_prompts(test_pid)
    cid = ctx.coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
    assert_receive {:prompted, "ses_fb", _}, 10_000

    emit("ses_fb", :agent_error, %{
      error: %{"name" => "APIError", "data" => %{"message" => "Rate limited"}},
      limit: %{kind: "usage", reason: "usage limit", resets_at: ~U[2100-01-01 00:00:00.000000Z]}
    })

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid, payload: p}}, 2_000
    assert p["engine"] == "claude_code"
    assert p["fallback_unavailable"] == "OpenCode › opencode/gpt-5-nano"

    assert EnginePauses.paused?("opencode")
    assert %{waiting: 1, on_fallback: 0} = EnginePauses.get("claude_code")
    # no rerun
    refute_receive {:prompted, _, _}, 200
  end

  test "a wake while a fallback turn runs queues on it; it goes to the primary only when that turn ends",
       ctx do
    test_pid = self()
    expect_fallback_session(test_pid)
    stub_prompts(test_pid)
    cid = ctx.coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
    assert_receive {:prompted, "ses_fb", _}, 10_000

    # the reset while the fallback turn still runs
    flush_timeline()
    claude_script(ctx, done_script(ctx, "On the primary now."))
    :ok = EnginePauses.resume("claude_code", "reset")
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} and this?")
    settle()

    # it waits behind the fallback turn (in the channel's line, one turn at a time)
    state = :sys.get_state(ctx.pid)
    assert map_size(state.turns) == 1
    assert [{{:root, ^cid}, _wake}] = state.waiting
    assert AgentSessions.get_fallback_root(ctx.channel.id, cid)

    refute_received {:timeline,
                     %{event_type: "agent_started", payload: %{"engine" => "claude_code"}}}

    finish_oc("ses_fb", "Done on the fallback.")

    assert_receive {:timeline, %{event_type: "message", message: %{body: "On the primary now."}}},
                   10_000

    assert AgentSessions.get_fallback_root(ctx.channel.id, cid) == nil
  end

  test "another agent woken while its engine is paused moves to its fallback with hit: false, once",
       ctx do
    test_pid = self()
    stub_prompts(test_pid)

    other =
      Fixtures.agent_fixture(%{
        name: "other" <> Fixtures.unique_suffix(),
        engine: "claude_code",
        fallback: @fallback
      })

    channel =
      Fixtures.channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.agent.id,
        agent_ids: [other.id]
      })

    Timeline.subscribe(channel.id)
    {:ok, _} = Runtime.ensure_channel(channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(channel.id) end)

    {:ok, _} =
      EnginePauses.engage("claude_code", %{kind: "usage", reason: "usage limit", resets_at: nil})

    expect_fallback_session(test_pid, "ses_other")
    oid = other.id
    {:ok, _} = Runtime.post_user_message(channel.id, "@#{other.name} look at this")

    assert_receive {:timeline, %{event_type: "engine_fallback", agent_id: ^oid, payload: p}},
                   5_000

    assert p["hit"] == false
    assert p["new_session"] == true
    assert_receive {:prompted, "ses_other", body}, 2_000
    refute prompt_text(body) =~ "You were moved"

    finish_oc("ses_other", "Looked.")
    assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^oid}}, 2_000

    {:ok, _} = Runtime.post_user_message(channel.id, "@#{other.name} again")
    assert_receive {:prompted, "ses_other", _}, 2_000
    refute_received {:timeline, %{event_type: "engine_fallback"}}
  end

  test "the fallback rerun is refused over the channel's spend limit", ctx do
    {:ok, _} = Canopy.Channels.set_spend_limit(ctx.channel, 1.0)
    path = Path.join(ctx.dir, "costly-limit.jsonl")

    File.write!(
      path,
      @fixtures
      |> Path.join("usage-limit.jsonl")
      |> File.read!()
      |> String.replace(~s("total_cost_usd":0,), ~s("total_cost_usd":2.0,))
    )

    claude_script(ctx, path)
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
    assert_receive {:timeline, %{event_type: "spend_limit_reached"}}, 10_000

    refute_receive {:timeline,
                    %{event_type: "agent_started", payload: %{"engine" => "opencode"}}},
                   300

    # the agent didn't carry on, so no line says it did
    refute_received {:timeline, %{event_type: "engine_fallback"}}
  end

  test "reset_session drops both roots; a restart loads the root the agent routes to", ctx do
    cid = ctx.coder.id

    primary =
      Fixtures.session_fixture(%{channel: ctx.channel, agent_id: cid, engine: "claude_code"})

    fallback =
      Fixtures.session_fixture(%{
        channel: ctx.channel,
        agent_id: cid,
        engine: "opencode",
        fallback_of: "claude_code"
      })

    {:ok, _} =
      EnginePauses.engage("claude_code", %{kind: "usage", reason: "usage limit", resets_at: nil})

    Runtime.stop_channel(ctx.channel.id)
    {:ok, pid} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
    assert :sys.get_state(pid).sessions[cid].id == fallback.id

    :ok = EnginePauses.resume("claude_code")
    Runtime.stop_channel(ctx.channel.id)
    {:ok, pid} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
    assert :sys.get_state(pid).sessions[cid].id == primary.id

    assert :ok = ChannelServer.reset_session(pid, cid, "user")
    assert AgentSessions.list_roots(ctx.channel.id, cid) == []

    # one line for the reset, not one per root
    assert_receive {:timeline, %{event_type: "session_reset", payload: %{"by" => "user"}}}
    refute_receive {:timeline, %{event_type: "session_reset"}}, 100
  end
end
