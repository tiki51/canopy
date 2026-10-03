defmodule Canopy.Costs.RoutingPauseTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Agents, Timeline}
  alias Canopy.Costs.Routing

  defp light_turns(ctx, kind, escalated, total) do
    for i <- 1..total do
      {:ok, _} =
        Timeline.record(%{
          channel_id: ctx.channel.id,
          agent_id: ctx.agent.id,
          event_type: "agent_turn_completed",
          payload: %{
            "outcome" => "ok",
            "cost" => 0.01,
            "profile" => "light",
            "wake_kind" => kind,
            "escalated" => i <= escalated
          }
        })
    end
  end

  setup do
    {:ok, scenario()}
  end

  test "fewer than 10 light turns never pause", ctx do
    light_turns(ctx, "scheduled", 9, 9)
    assert Routing.check_pause(ctx.agent.id, "scheduled") == :ok
  end

  test "10 of 20 escalated pauses the rule; 3 of 20 does not", ctx do
    light_turns(ctx, "handoff_accepted", 3, 20)
    assert Routing.check_pause(ctx.agent.id, "handoff_accepted") == :ok

    light_turns(ctx, "scheduled", 10, 20)
    assert {:paused, "10 of 20 escalated"} = Routing.check_pause(ctx.agent.id, "scheduled")
    assert Agents.paused_kinds(ctx.agent.id) == MapSet.new(["scheduled"])
  end

  test "resume restarts the window", ctx do
    light_turns(ctx, "scheduled", 10, 20)
    assert {:paused, _} = Routing.check_pause(ctx.agent.id, "scheduled")
    {:ok, _} = Agents.resume_routing(ctx.agent.id, "scheduled")

    # the old escalations are before the window: nothing to pause on
    assert Routing.check_pause(ctx.agent.id, "scheduled") == :ok
    assert Routing.rule_stats(ctx.agent.id) == []

    light_turns(ctx, "scheduled", 4, 10)
    assert {:paused, "4 of 10 escalated"} = Routing.check_pause(ctx.agent.id, "scheduled")
  end
end
