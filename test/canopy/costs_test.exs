defmodule Canopy.CostsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Costs, Timeline}

  defp turn(channel, agent, cost, extra \\ %{}) do
    {:ok, _} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        payload:
          Map.merge(
            %{
              "outcome" => "ok",
              "cost" => cost,
              "tools" => 3,
              "duration_ms" => 4_000,
              "model" => "opencode/gpt-5-nano"
            },
            extra
          )
      })
  end

  test "totals and breakdowns by agent, channel, model, and day" do
    %{channel: channel, agent: agent, repository: repository} = scenario()
    other_agent = agent_fixture(%{name: "spender"})
    {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, other_agent)

    assert Costs.total() == %{cost: 0.0, turns: 0, tools: 0}

    turn(channel, agent, 0.25)
    turn(channel, agent, 0.05, %{"model" => "openai/gpt-5.4"})
    turn(dm, other_agent, 1.5)
    turn(dm, other_agent, 0, %{"outcome" => "error", "cost" => nil})

    assert %{cost: cost, turns: 4, tools: 12} = Costs.total()
    assert_in_delta cost, 1.8, 0.0001
    assert %{turns: 4} = Costs.total(Costs.since(:today))

    assert [%{label: "@spender", cost: 1.5, turns: 2}, %{label: "@" <> _, turns: 2}] =
             Costs.by_agent()

    assert [%{label: "DM @spender", cost: 1.5}, %{label: "#" <> _}] = Costs.by_channel()

    assert [%{label: "opencode/gpt-5-nano", turns: 3}, %{label: "openai/gpt-5.4", turns: 1}] =
             Costs.by_model()

    days = Costs.by_day(3)
    assert length(days) == 3
    assert List.last(days).day == NaiveDateTime.to_date(NaiveDateTime.local_now())
    assert_in_delta List.last(days).cost, 1.8, 0.0001
    assert hd(days).cost == 0.0

    # older turns without a model get the agent's configured one
    {:ok, _} =
      Canopy.Agents.update(other_agent, %{model_provider: "opencode", model_id: "big-pickle"})

    turn(dm, other_agent, 0.2, %{"model" => nil})
    assert Costs.backfill_models() >= 1
    assert Enum.any?(Costs.by_model(), &(&1.label == "opencode/big-pickle"))
    refute Enum.any?(Costs.by_model(), &(&1.label == "unknown"))

    assert Costs.money(1.8) == "$1.80"
    assert Costs.money(0.0042) == "$0.0042"
    assert Costs.money(nil) == "$0.00"
  end
end

defmodule Canopy.CostsDetailTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Mox

  alias Canopy.{Channels, Costs, Timeline}
  alias Canopy.Costs.Report
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  defp turn(channel, agent, payload) do
    {:ok, event} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        payload:
          Map.merge(
            %{"outcome" => "ok", "tools" => 1, "duration_ms" => 1_000, "cost" => 0.1},
            payload
          )
      })

    event
  end

  test "efficiency, triggers, the costliest turns, and per-channel spend" do
    %{channel: channel, agent: agent} = scenario()

    big =
      turn(channel, agent, %{
        "cost" => 2.0,
        "trigger" => "agent",
        "steps" => 4,
        "context" => 50_000,
        "tokens" => %{
          "input" => 10_000,
          "cache_read" => 40_000,
          "output" => 500,
          "reasoning" => 100
        }
      })

    turn(channel, agent, %{
      "cost" => 0.5,
      "trigger" => "user",
      "steps" => 1,
      "context" => 10_000,
      "tokens" => %{"input" => 10_000, "output" => 100},
      "passed" => true
    })

    turn(channel, agent, %{"cost" => 0.25, "trigger" => "scheduled", "outcome" => "error"})

    {:ok, _} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "session_compacted",
        payload: %{"context" => 50_000, "cap" => 40_000}
      })

    eff = Costs.efficiency()
    assert eff.turns == 3
    assert eff.steps == 5
    # only turns that recorded a context count toward the average
    assert eff.avg_context == 30_000

    assert eff.tokens == %{
             input: 20_000,
             output: 600,
             reasoning: 100,
             cache_read: 40_000,
             cache_write: 0
           }

    assert_in_delta eff.cache_rate, 40_000 / 60_000, 0.001
    assert eff.passed == %{turns: 1, cost: 0.5}
    assert eff.errors == %{turns: 1, cost: 0.25}
    assert eff.compactions == 1
    assert_in_delta eff.avg_cost, 2.75 / 3, 0.0001

    assert [
             %{key: "agent", label: "agent messages", cost: 2.0},
             %{key: "user"},
             %{key: "scheduled"}
           ] =
             Costs.by_trigger()

    assert [%{id: top_id, agent: "@" <> _, channel: "#" <> _, context: 50_000, steps: 4} | _] =
             Costs.top_turns(nil, 2)

    assert top_id == big.id
    assert length(Costs.top_turns(nil, 2)) == 2

    assert_in_delta Costs.channel_total(channel.id), 2.75, 0.0001
    assert Costs.channel_budgets() == []

    {:ok, _} = Channels.set_spend_limit(channel, 2.0)
    assert [%{channel_id: cid, limit: 2.0, reached?: true}] = Costs.channel_budgets()
    assert cid == channel.id
  end

  test "the report reads as text, with settings and prices" do
    %{channel: channel, agent: agent} = scenario()
    turn(channel, agent, %{"cost" => 0.4, "trigger" => "user", "model" => "opencode/gpt-5-nano"})
    {:ok, _} = Channels.set_spend_limit(channel, 5.0)

    stub(OC, :providers, fn _opts ->
      {:ok,
       %{
         "providers" => [
           %{
             "id" => "opencode",
             "models" => %{"gpt-5-nano" => %{"cost" => %{"input" => 0.05, "output" => 0.4}}}
           }
         ]
       }}
    end)

    assert {:ok, :week} = Report.period(nil)
    assert {:ok, :all} = Report.period("All")
    assert {:error, "unknown period " <> _} = Report.period("yesterday")

    text = Report.render(:week)
    assert text =~ "Canopy spend report for the last 7 days"
    assert text =~ "Total: $0.40 over 1 turns"
    assert text =~ "- @#{agent.name}: $0.40 (100%), 1 turns"
    assert text =~ "- ##{channel.name}: $0.40"
    assert text =~ "- your messages: $0.40"
    assert text =~ "Efficiency:"
    assert text =~ "Costliest turns:\n- $0.40 @#{agent.name} in ##{channel.name}"
    assert text =~ "- ##{channel.name}: $0.40 of $5.00"
    assert text =~ "Settings that shape spend: pause after 6 agent turns"
    assert text =~ "- opencode/gpt-5-nano: $0.050 in / $0.40 out"

    stub(OC, :providers, fn _opts -> {:error, :down} end)
    assert Report.render(:all) =~ "Model prices: unavailable"
  end
end
