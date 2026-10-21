defmodule Canopy.Runtime.ChannelServerEnginePauseEdgesTest do
  @moduledoc """
  The channel server at an engine limit, at the edges: a limit with no
  reset time (or one already past), a fallback that can't start or shares
  the paused engine, a restart while an agent waits, agents on other
  engines, and the line a flipped agent's next wake writes. Claude Code
  turns run the fake CLI; OpenCode, the fallback, is a Mox double.
  """
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Mox
  import Canopy.RuntimeHelpers, only: [settle: 0]

  alias Canopy.{Agents, EnginePauses, Fixtures, Runtime, Schedules, Timeline}
  alias Canopy.EnginePauses.LiftWorker
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

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

  defp claude_script(ctx, name) do
    script = if File.exists?(name), do: name, else: Path.join(@fixtures, name)

    Application.put_env(:canopy, :claude_code,
      default_config_dir: ctx.previous[:default_config_dir],
      binary: @fake,
      env: [{"FAKE_CLAUDE_SCRIPT", script}]
    )
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

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  defp flush_timeline do
    receive do
      {:timeline, _} -> flush_timeline()
    after
      0 -> :ok
    end
  end

  defp auto_schedules(agent_id),
    do: agent_id |> Schedules.list_for_agent() |> Enum.filter(&(&1.source == "auto"))

  test "no reset time, with a fallback: the agent moves; no lift and no nudge are scheduled",
       ctx do
    claude_script(ctx, "usage-limit-no-reset.jsonl")
    stub_prompts(self())
    expect(OC, :create_session, fn _dir, _body, _opts -> {:ok, %{"id" => "ses_fb"}} end)
    cid = ctx.coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")

    assert_receive {:timeline, %{event_type: "engine_fallback", agent_id: ^cid, payload: p}},
                   10_000

    assert p["resets_at"] == nil
    assert p["kind"] == "billing"
    assert_receive {:prompted, "ses_fb", _}, 5_000

    assert %{resets_at: nil, reason: "insufficient balance", on_fallback: 1} =
             EnginePauses.get("claude_code")

    refute_enqueued(worker: LiftWorker)
    assert auto_schedules(cid) == []
  end

  test "no reset time and no fallback: the agent waits until Release, which nudges it", ctx do
    claude_script(ctx, "usage-limit-no-reset.jsonl")
    {:ok, coder} = Agents.update(ctx.coder, %{fallback: "none"})
    cid = coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} go")

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid, payload: p}}, 10_000
    assert p["resets_at"] == nil
    assert p["nudge_at"] == nil
    assert auto_schedules(cid) == []
    refute_enqueued(worker: LiftWorker)
    assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^cid}}, 2_000

    # Release: the nudge is a turn on the primary, with the "resumed" text
    log = Path.join(ctx.dir, "claude.log")

    Application.put_env(:canopy, :claude_code,
      default_config_dir: ctx.previous[:default_config_dir],
      binary: @fake,
      env: [{"FAKE_CLAUDE_LOG", log}]
    )

    :ok = EnginePauses.resume("claude_code")

    assert_receive {:timeline, %{event_type: "engine_resumed", payload: r}}, 2_000
    assert r["by"] == "user"
    assert r["nudged"] == [cid]
    assert_receive {:timeline, %{event_type: "agent_started", agent_id: ^cid}}, 5_000

    assert eventually(fn ->
             File.exists?(log) and File.read!(log) =~ "Claude Code has been resumed."
           end)
  end

  test "a reset time already past counts as unknown: no lift loop", ctx do
    {:ok, coder} = Agents.update(ctx.coder, %{fallback: "none"})
    cid = coder.id
    past = Path.join(ctx.dir, "past.jsonl")

    File.write!(
      past,
      @fixtures
      |> Path.join("usage-limit.jsonl")
      |> File.read!()
      |> String.replace("__RESETS_AT__", "#{System.os_time(:second) - 600}")
    )

    claude_script(ctx, past)
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} go")

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid, payload: p}}, 10_000
    assert p["resets_at"] == nil
    assert %{resets_at: nil, kind: "usage"} = EnginePauses.get("claude_code")
    refute_enqueued(worker: LiftWorker)
    assert auto_schedules(cid) == []
  end

  test "a fallback on the paused engine can't be used: the agent waits and the line names it",
       ctx do
    {:ok, coder} = Agents.update(ctx.coder, %{fallback: "claude_code:sonnet"})
    cid = coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} go")

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid, payload: p}}, 10_000
    assert p["fallback_unavailable"] == "Claude Code › sonnet"
    assert %{waiting: 1, on_fallback: 0} = EnginePauses.get("claude_code")
  end

  test "a fallback that fails to start: the agent waits with its nudge, the wake isn't lost silently",
       ctx do
    expect(OC, :create_session, fn _dir, _body, _opts -> {:error, :econnrefused} end)
    cid = ctx.coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid, payload: p}}, 10_000
    assert p["fallback_unavailable"] == "OpenCode › opencode/gpt-5-nano"
    settle()
    assert %{waiting: 1, on_fallback: 0} = EnginePauses.get("claude_code")
    assert [%{status: "active"}] = auto_schedules(cid)
  end

  test "an agent on another engine answers while Claude Code is paused", ctx do
    stub_prompts(self())

    {:ok, _} =
      EnginePauses.engage("claude_code", %{kind: "usage", reason: "usage limit", resets_at: nil})

    # the scenario's own agent runs on OpenCode, the default engine
    assert Agents.effective_engine(ctx.agent) == "opencode"
    aid = ctx.agent.id
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} status?")

    # the scenario's session: the agent's own, on OpenCode
    oc_session = ctx.session.engine_session_id
    assert_receive {:prompted, ^oc_session, _}, 5_000
    settle()

    refute_received {:timeline, %{event_type: "engine_" <> _, agent_id: ^aid}}
    assert %{waiting: 0, on_fallback: 0} = EnginePauses.get("claude_code")
  end

  test "a restart while an agent waits keeps dropping its wakes, without a second line", ctx do
    {:ok, coder} = Agents.update(ctx.coder, %{fallback: "none"})
    cid = coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} go")
    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid}}, 10_000
    assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^cid}}, 2_000

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} hello?")
    assert_receive {:timeline, %{event_type: "engine_wake_dropped", agent_id: ^cid}}, 2_000
    settle()
    flush_timeline()

    Runtime.stop_channel(ctx.channel.id)
    {:ok, _} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{coder.name} still there?")
    settle()
    refute_received {:timeline, %{event_type: "engine_wake_dropped"}}
    refute_received {:timeline, %{event_type: "agent_started", agent_id: ^cid}}
    assert EnginePauses.paused?("claude_code")
  end

  test "after its fallback turn hits a limit, the agent's next wake is dropped with a line",
       ctx do
    stub_prompts(self())
    expect(OC, :create_session, fn _dir, _body, _opts -> {:ok, %{"id" => "ses_fb"}} end)
    cid = ctx.coder.id

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
    assert_receive {:prompted, "ses_fb", _}, 10_000

    emit("ses_fb", :agent_error, %{
      error: %{"name" => "APIError", "data" => %{"message" => "Usage limit reached"}},
      limit: %{kind: "usage", reason: "usage limit", resets_at: ~U[2100-01-01 00:00:00.000000Z]}
    })

    assert_receive {:timeline, %{event_type: "engine_paused", agent_id: ^cid}}, 2_000
    assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^cid}}, 2_000

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} and now?")

    assert_receive {:timeline, %{event_type: "engine_wake_dropped", agent_id: ^cid, payload: d}},
                   2_000

    assert d["engine"] == "claude_code"
    refute_receive {:prompted, _, _}, 200
  end
end
