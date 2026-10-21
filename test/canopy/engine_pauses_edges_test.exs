defmodule Canopy.EnginePausesEdgesTest do
  @moduledoc """
  `Canopy.EnginePauses` at its edges: reset times that go missing or come
  late, a pause lifted twice over its life, the fallback's own pause lifting
  first, the Auto nudge and the lift job racing, and agents on other engines
  carrying on.
  """
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Canopy.Fixtures
  import Mox

  alias Canopy.{Agents, EnginePauses, Fallback, Runtime, Schedules}
  alias Canopy.EnginePauses.{LiftWorker, Pause}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  defp usage(resets_at),
    do: %{kind: "usage", reason: "usage limit", resets_at: resets_at, detail: "limit"}

  # ends an OpenCode turn, so the agent's next wake isn't queued behind it
  defp finish(sid) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      Canopy.OpenCode.EventStream.session_topic(sid),
      {:engine_event,
       %Canopy.Engine.Event{type: :agent_completed, session_id: sid, data: %{}, raw_type: "test"}}
    )
  end

  defp in_hours(h), do: DateTime.add(DateTime.utc_now(), h * 3600, :second)

  defp stub_opencode(test_pid) do
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> unique_suffix()}}
    end)

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)
  end

  test "a later limit with no reset time keeps the known one" do
    at = in_hours(2)
    {:ok, pause} = EnginePauses.engage("claude_code", usage(at))
    {:ok, again} = EnginePauses.engage("claude_code", usage(nil))
    assert again.id == pause.id
    assert again.resets_at == at
    assert_enqueued(worker: LiftWorker, args: %{pause_id: pause.id})
  end

  test "a reset learned after a pause with none schedules the lift then" do
    {:ok, _} = EnginePauses.engage("claude_code", usage(nil))
    refute_enqueued(worker: LiftWorker)

    at = in_hours(1)
    {:ok, pause} = EnginePauses.engage("claude_code", usage(at))
    assert pause.resets_at == at
    assert_enqueued(worker: LiftWorker, args: %{pause_id: pause.id})
  end

  test "after a lift the engine can pause again; the old pause stays as history" do
    {:ok, first} = EnginePauses.engage("codex", usage(nil))
    :ok = EnginePauses.resume("codex")
    refute EnginePauses.paused?("codex")
    assert EnginePauses.get("codex") == nil

    {:ok, second} = EnginePauses.engage("codex", usage(nil))
    assert second.id != first.id
    assert EnginePauses.get("codex").id == second.id
    assert %Pause{lifted_by: "user"} = EnginePauses.get_pause(first.id)
    assert Repo.aggregate(Pause, :count) == 2
  end

  test "changes are broadcast: a pause, a count, a lift" do
    stub_opencode(self())
    %{channel: channel, agent: agent, repository: repository} = scenario()
    Canopy.MCP.mark_registered(repository.id)
    on_exit(fn -> Runtime.stop_channel(channel.id) end)
    EnginePauses.subscribe()

    {:ok, pause} = EnginePauses.engage("codex", usage(nil))
    assert_receive {:engine_pauses, :changed}

    EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    assert_receive {:engine_pauses, :changed}

    # the same state again changes no count
    EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    refute_receive {:engine_pauses, :changed}, 50

    :ok = EnginePauses.resume("codex")
    assert_receive {:engine_pauses, :changed}

    # resuming what isn't paused says nothing
    :ok = EnginePauses.resume("codex")
    refute_receive {:engine_pauses, :changed}, 50
  end

  test "an environment clear doesn't schedule a lift for a pause with no reset time" do
    {:ok, _} = EnginePauses.engage("opencode", usage(nil))
    :ok = EnginePauses.reschedule_all()
    refute_enqueued(worker: LiftWorker)
    assert EnginePauses.paused?("opencode")
  end

  test "the fallback's own pause lifting first nudges nobody and sends the agent back to the fallback" do
    stub_opencode(self())

    agent =
      agent_fixture(%{engine: "claude_code", fallback: "opencode:opencode/gpt-5-nano"})

    %{channel: channel} = scenario(members: [agent])
    on_exit(fn -> Runtime.stop_channel(channel.id) end)

    {:ok, primary} = EnginePauses.engage("claude_code", usage(in_hours(3)))
    EnginePauses.mark(primary, agent.id, channel.id, "fallback")

    # the fallback turn hit OpenCode's limit too
    {:ok, _} = EnginePauses.engage("opencode", usage(in_hours(1)))
    :ok = EnginePauses.flip_to_waiting("claude_code", agent.id)
    assert {:wait, _} = Fallback.route(Agents.get!(agent.id))
    assert %{waiting: 1, on_fallback: 0} = EnginePauses.get("claude_code")

    :ok = EnginePauses.resume("opencode", "reset")
    refute_receive {:prompted, _, _}, 300

    assert {:fallback, %{engine: "opencode"}} = Fallback.route(Agents.get!(agent.id))
    # still counted as waiting on Claude Code's pause until its next wake moves it
    assert EnginePauses.paused?("claude_code")
  end

  test "the Auto nudge firing first cancels the lift job; a pending one after a lift fires as a plain schedule" do
    stub_opencode(self())
    %{channel: channel, agent: agent, repository: repository} = scenario()
    Canopy.MCP.mark_registered(repository.id)
    on_exit(fn -> Runtime.stop_channel(channel.id) end)

    {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))
    {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    row = EnginePauses.ensure_nudge(pause, row)
    assert_enqueued(worker: LiftWorker, args: %{pause_id: pause.id})

    :ok = Schedules.fire(row.schedule_id)
    refute EnginePauses.paused?("opencode")
    refute_enqueued(worker: LiftWorker)
    assert %{lifted_by: "reset"} = EnginePauses.get_pause(pause.id)
    assert_receive {:prompted, sid, _}, 2_000
    finish(sid)

    # a second Auto schedule of the lifted pause is not a lift any more
    {:ok, stray} =
      Schedules.create_auto(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "stray nudge",
        run_at: in_hours(1),
        source_ref: pause.id
      })

    refute EnginePauses.fire_auto(stray)
    :ok = Schedules.fire(stray.id)
    assert_receive {:prompted, _, body}, 2_000
    assert inspect(body) =~ "stray nudge"
  end

  test "the Auto nudge's schedule_created line carries when it runs" do
    %{channel: channel, agent: agent} = scenario()
    Canopy.Timeline.subscribe(channel.id)
    {:ok, pause} = EnginePauses.engage("claude_code", usage(in_hours(1)))
    {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    EnginePauses.ensure_nudge(pause, row)

    assert_receive {:timeline, %{event_type: "schedule_created", payload: p}}
    assert p["source"] == "auto"
    # the line reads "once at 15:01 · …" from it (CanopyWeb.TimelineComponents)
    assert p["run_at"] == DateTime.to_iso8601(EnginePauses.nudge_at(pause))
  end

  test "an agent on another engine keeps its schedules and wakes while one engine is paused" do
    stub_opencode(self())
    %{channel: channel, agent: agent, repository: repository} = scenario()
    Canopy.MCP.mark_registered(repository.id)
    on_exit(fn -> Runtime.stop_channel(channel.id) end)
    assert Agents.effective_engine(agent) == "opencode"

    {:ok, schedule} =
      Schedules.create(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "check the build",
        when: "2h"
      })

    {:ok, _} = EnginePauses.engage("claude_code", usage(in_hours(1)))
    assert %{status: "active"} = Schedules.get!(schedule.id)

    :ok = Schedules.fire(schedule.id)
    assert_receive {:prompted, sid, body}, 2_000
    assert inspect(body) =~ "check the build"
    finish(sid)

    {:ok, _} = Runtime.post_user_message(channel.id, "@#{agent.name} are you there?")
    assert_receive {:prompted, _, _}, 2_000
  end
end
