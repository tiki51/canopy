defmodule Canopy.CostsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query

  alias Canopy.{Costs, Repo, Timeline}

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

    assert Costs.total() == %{cost: 0.0, estimated: 0.0, turns: 0, tools: 0}

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

  describe "estimated costs and engines" do
    setup do
      # Codex may not be registered yet; by_engine/1 only reads the names
      old = Application.get_env(:canopy, :engines)

      Application.put_env(
        :canopy,
        :engines,
        Map.put(old, "codex", Canopy.Engine.Codex)
      )

      on_exit(fn -> Application.put_env(:canopy, :engines, old) end)

      %{channel: channel, agent: agent, session: session} = scenario()
      coder = agent_fixture(%{name: "coder"})
      codex_session = session_fixture(%{channel: channel, agent_id: coder.id, engine: "codex"})

      on = fn who, ref, cost, extra ->
        {:ok, _} =
          Timeline.record(%{
            channel_id: channel.id,
            agent_id: who.id,
            event_type: "agent_turn_completed",
            ref_id: ref,
            payload:
              Map.merge(
                %{"outcome" => "ok", "cost" => cost, "tools" => 1, "duration_ms" => 1_000},
                extra
              )
          })
      end

      # Codex turns: one recording its engine, one from before the payload did
      on.(coder, codex_session.id, 0.3, %{
        "engine" => "codex",
        "cost_estimated" => true,
        "model" => "gpt-5-codex",
        "trigger" => "user"
      })

      on.(coder, codex_session.id, 0.2, %{"cost_estimated" => true, "model" => "gpt-5-codex"})
      # an OpenCode turn whose session row says so
      on.(agent, session.id, 1.0, %{"model" => "opencode/big", "trigger" => "user"})

      # a Claude Code session dropped since: its reset line names the engine
      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "session_reset",
          ref_id: "as_gone",
          payload: %{"engine" => "claude_code", "by" => "engine_change"}
        })

      on.(agent, "as_gone", 0.5, %{"model" => "custom"})
      # no engine, no session: Claude Code by its model name, else OpenCode
      on.(agent, nil, 0.25, %{"model" => "sonnet"})
      on.(agent, nil, 0.05, %{"model" => "opencode/small"})

      %{channel: channel, coder: coder}
    end

    test "every aggregate carries the estimated part of its cost", %{channel: channel} do
      assert %{cost: cost, estimated: estimated, turns: 6} = Costs.total()
      assert_in_delta cost, 2.3, 1.0e-9
      assert_in_delta estimated, 0.5, 1.0e-9

      assert [%{estimated: +0.0}, %{label: "@coder", estimated: e1}] = Costs.by_agent()
      assert_in_delta e1, 0.5, 1.0e-9

      assert [%{estimated: e2}] = Costs.by_channel()
      assert_in_delta e2, 0.5, 1.0e-9

      models = Map.new(Costs.by_model(), &{&1.key, &1})
      assert_in_delta models["gpt-5-codex"].estimated, 0.5, 1.0e-9
      assert models["opencode/big"].estimated == 0.0

      triggers = Map.new(Costs.by_trigger(), &{&1.key, &1})
      assert_in_delta triggers["user"].estimated, 0.3, 1.0e-9
      assert_in_delta triggers["unknown"].estimated, 0.2, 1.0e-9

      assert %{estimated: e3} = List.last(Costs.by_day(2))
      assert_in_delta e3, 0.5, 1.0e-9
      assert %{estimated: +0.0} = hd(Costs.by_day(2))

      eff = Costs.efficiency()
      assert_in_delta eff.estimated, 0.5, 1.0e-9
      assert_in_delta eff.avg_estimated, 0.5 / 6, 1.0e-9

      top = Costs.top_turns(nil, 6)
      assert Enum.count(top, & &1.cost_estimated) == 2
      assert %{cost: 1.0, cost_estimated: false} = hd(top)

      assert %{cost: c4, estimated: e4} = Costs.channel_spend(channel.id)
      assert_in_delta c4, 2.3, 1.0e-9
      assert_in_delta e4, 0.5, 1.0e-9
      assert Costs.channel_spend("ch_none") == %{cost: 0.0, estimated: 0.0}
    end

    test "the spend limit counts estimates", %{channel: channel} do
      # 1.8 reported + 0.5 estimated: over 2.00 only with the estimates
      assert_in_delta Costs.channel_total(channel.id), 2.3, 1.0e-9

      {:ok, _} = Canopy.Channels.set_spend_limit(channel, 2.0)
      assert [%{reached?: true, spent: spent, estimated: estimated}] = Costs.channel_budgets()
      assert_in_delta spent, 2.3, 1.0e-9
      assert_in_delta estimated, 0.5, 1.0e-9
    end

    test "by_engine/1 in engine order, older turns falling back to their session or model" do
      assert [claude, codex, opencode] = Costs.by_engine()

      assert %{key: "claude_code", label: "Claude Code", turns: 2, tools: 2} = claude
      assert_in_delta claude.cost, 0.75, 1.0e-9
      assert claude.estimated == 0.0

      assert %{key: "codex", label: "Codex", turns: 2, duration_ms: 2_000} = codex
      assert_in_delta codex.cost, 0.5, 1.0e-9
      assert_in_delta codex.estimated, 0.5, 1.0e-9

      assert %{key: "opencode", label: "OpenCode", turns: 2} = opencode
      assert_in_delta opencode.cost, 1.05, 1.0e-9

      assert Costs.models_on("codex") == ["gpt-5-codex"]
    end

    test "by_engine/1 leaves out engines with no turns in the period" do
      Repo.update_all(
        from(e in Canopy.Timeline.Event,
          where: fragment("json_extract(?, '$.model')", e.payload) != "gpt-5-codex"
        ),
        set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]]
      )

      assert [%{key: "codex", turns: 2}] = Costs.by_engine(Costs.since(:week))
      assert length(Costs.by_engine()) == 3
    end
  end

  test "money puts a minus sign before the dollar and never shows a negative zero" do
    assert Costs.money(-0.01) == "−$0.01"
    assert Costs.money(-1.234) == "−$1.23"
    assert Costs.money(-0.0042) == "−$0.0042"
    assert Costs.money(-0.0) == "$0.00"
    assert Costs.money(-0.000001) == "$0.00"
    assert Costs.money(-0.004) == "−$0.0040"
    assert Costs.money(0) == "$0.00"
    assert Costs.money(12) == "$12.00"
    refute Costs.money(-0.001) =~ "$-"
  end

  test "an activity cost reads −$ when negative and never $-0.0000" do
    assert Canopy.Runtime.Activity.format_cost(0.0123) == "$0.0123"
    assert Canopy.Runtime.Activity.format_cost(-0.0123) == "−$0.0123"
    assert Canopy.Runtime.Activity.format_cost(-0.00001) == "$0.0000"
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
    assert eff.passed == %{turns: 1, cost: 0.5, estimated: 0.0}
    assert eff.errors == %{turns: 1, cost: 0.25, estimated: 0.0}
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

  test "an inherited model and the same model chosen per agent share one By model row" do
    %{channel: channel, agent: inheriting} = scenario()
    chosen = agent_fixture(%{name: "chosen", model_provider: "opencode", model_id: "gpt-5-nano"})

    {:ok, _} =
      Canopy.Settings.put_default_model("opencode", %{
        model_provider: "opencode",
        model_id: "gpt-5-nano"
      })

    {:ok, _} = Canopy.Settings.put_default_model("claude_code", %{model_id: "sonnet"})
    stub(OC, :providers, fn _opts -> {:error, :down} end)

    for agent <- [inheriting, chosen] do
      turn(channel, agent, %{"model" => Canopy.Engine.OpenCode.model_label(agent)})
    end

    assert [%{label: "opencode/gpt-5-nano", turns: 2}] = Costs.by_model()

    # the report names the defaults, so the auditor can recommend a cheaper one
    assert Report.render(:week) =~
             "Default models (Settings; agents without a model of their own use them): Claude Code sonnet; Codex its own default; OpenCode opencode/gpt-5-nano. 1 of 2 active agents use them."
  end
end
