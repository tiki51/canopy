defmodule Canopy.Playbooks.StallEnginePauseTest do
  # the stall check snoozes only when the run's coordinator waits for a paused engine
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Agents, EnginePauses}
  alias Canopy.Playbooks.{Runs, StallWorker}

  setup :set_mox_global

  setup do
    ctx = scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)

    playbook =
      playbook_fixture("slow-" <> unique_suffix(), [{"plan", "Plan", "coordinator"}])

    {:ok, run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    Map.put(ctx, :run, run)
  end

  defp pause(engine),
    do: EnginePauses.engage(engine, %{kind: "billing", reason: "usage limit", resets_at: nil})

  test "a coordinator waiting on its paused engine: the check snoozes", %{run: run, agent: agent} do
    assert Agents.effective_engine(agent) == "opencode"
    {:ok, _} = pause("opencode")
    assert {:snooze, 600} = perform_job(StallWorker, %{run_id: run.id})
  end

  test "another engine's pause doesn't hold the check", %{run: run} do
    {:ok, _} = pause("claude_code")
    refute match?({:snooze, _}, perform_job(StallWorker, %{run_id: run.id}))
  end

  test "a coordinator with a usable fallback isn't held", %{run: run, agent: agent} do
    {:ok, _} = Agents.update(agent, %{fallback: "claude_code:sonnet"})
    {:ok, _} = pause("opencode")

    if Canopy.Engine.available?("claude_code") do
      refute match?({:snooze, _}, perform_job(StallWorker, %{run_id: run.id}))
    else
      assert {:snooze, 600} = perform_job(StallWorker, %{run_id: run.id})
    end
  end
end
