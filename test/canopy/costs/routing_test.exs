defmodule Canopy.Costs.RoutingTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query

  alias Canopy.{Costs, Repo, Timeline}
  alias Canopy.Costs.{Report, Routing}
  alias Canopy.Timeline.Event

  # A turn summary for `agent` in `channel`, ended at `at` (default now),
  # in session `session`.
  defp turn(ctx, payload, opts \\ []) do
    {:ok, event} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: Keyword.get(opts, :agent, ctx.agent).id,
        event_type: "agent_turn_completed",
        ref_id: Keyword.get(opts, :session, "as_one"),
        payload:
          Map.merge(
            %{
              "outcome" => "ok",
              "cost" => 0.1,
              "tools" => 1,
              "duration_ms" => 1_000,
              "files" => []
            },
            payload
          )
      })

    if at = opts[:at] do
      {1, _} = Repo.update_all(from(e in Event, where: e.id == ^event.id), set: [inserted_at: at])
    end

    event
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  setup do
    {:ok, scenario()}
  end

  describe "wake_profile/1 (Phase 1)" do
    test "derives kinds from the trigger, splitting delegations into task and report", ctx do
      turn(ctx, %{"trigger" => "delegation", "delegation_ids" => ["dl_1"], "cost" => 0.5})
      turn(ctx, %{"trigger" => "delegation", "delegation_ids" => [], "passed" => true})
      turn(ctx, %{"trigger" => "agent", "passed" => true, "cost" => 0.2})
      turn(ctx, %{"trigger" => "agent", "files" => ["lib/a.ex"], "tools" => 9, "cost" => 0.4})
      turn(ctx, %{"trigger" => "scheduled", "wake_kind" => "scheduled"})

      rows = Map.new(Routing.wake_profile(nil), &{&1.kind, &1})

      assert %{turns: 1, light?: false} = rows["delegation_task"]
      assert %{turns: 1, passed: 1, light?: true} = rows["delegation_report"]
      assert %{turns: 2, pass_rate: 0.5, quiet_rate: 0.5, light?: true} = rows["agent_message"]
      assert_in_delta rows["agent_message"].cost, 0.6, 0.0001
      assert %{turns: 1} = rows["scheduled"]
    end

    test "a turn whose session's last turn ended within the cache window is warm", ctx do
      turn(ctx, %{"trigger" => "user"}, at: ago(600))
      # started 9 minutes after the first ended: cold
      turn(ctx, %{"trigger" => "scheduled", "duration_ms" => 1_000}, at: ago(59))
      # started a minute after: warm
      turn(ctx, %{"trigger" => "scheduled", "duration_ms" => 1_000}, at: ago(0))
      # another session's turn is not this one's
      turn(ctx, %{"trigger" => "scheduled"}, at: ago(0), session: "as_two")

      assert %{warm_share: share} =
               Enum.find(Routing.wake_profile(nil), &(&1.kind == "scheduled"))

      assert_in_delta share, 1 / 3, 0.001
    end

    test "turns that reacted are counted", ctx do
      turn(ctx, %{
        "trigger" => "agent",
        "passed" => true,
        "activity" => [%{"label" => "canopy react ✅"}]
      })

      assert [%{reacted: 1}] = Routing.wake_profile(nil)
    end
  end

  describe "candidates/1 (estimates)" do
    test "re-prices light kinds on the light model; a warm big context stays on main", ctx do
      tokens = %{
        "input" => 1_000,
        "output" => 1_000,
        "reasoning" => 0,
        "cache_read" => 0,
        "cache_write" => 0
      }

      turn(ctx, %{"trigger" => "scheduled", "model" => "opus", "cost" => 1.0, "tokens" => tokens})

      turn(ctx, %{"trigger" => "user", "model" => "opus", "cost" => 1.0, "tokens" => tokens},
        session: "as_two",
        at: ago(60)
      )

      turn(
        ctx,
        %{"trigger" => "scheduled", "model" => "opus", "cost" => 1.0, "context" => 50_000},
        session: "as_two"
      )

      c = Routing.candidates(nil, catalog: %{})
      assert c.light_models["claude_code"] == "haiku"
      assert c.assumed["claude_code"]

      assert [%{kind: "scheduled", candidates: 2, routed: 1, kept_main: 1} = row] = c.rows
      # haiku: 1k in at $1 + 1k out at $5 per million; the opus side is
      # re-priced from the same tokens at list price ($4 / $20)
      assert_in_delta row.light_cost, 0.006, 0.000001
      assert_in_delta row.cost, 0.024, 0.000001
      assert_in_delta row.saving, 0.018, 0.000001
    end

    test "an OpenCode turn needs a light model and a price", ctx do
      turn(ctx, %{"trigger" => "scheduled", "model" => "opencode/big", "cost" => 0.1})
      assert [%{no_estimate: 1, routed: 0}] = Routing.candidates(nil, catalog: %{}).rows

      {:ok, _} =
        Canopy.Settings.put_light_profile("opencode", %{
          model_provider: "opencode",
          model_id: "small"
        })

      catalog = %{"opencode/small" => %{input: 0.1, output: 0.4, cache_read: 0.01}}
      assert [%{routed: 1}] = Routing.candidates(nil, catalog: catalog).rows
    end
  end

  describe "once routing runs" do
    test "by_route/1 and routing_savings/1 against the agent's main turns", ctx do
      # baseline: two main scheduled turns at $1.00 and $0.60
      turn(ctx, %{"wake_kind" => "scheduled", "profile" => "main", "cost" => 1.0})
      turn(ctx, %{"wake_kind" => "scheduled", "profile" => "main", "cost" => 0.6})
      # kept light turns: $0.10 and $0.20 (baseline 0.80 each)
      turn(ctx, %{"wake_kind" => "scheduled", "profile" => "light", "cost" => 0.1})
      turn(ctx, %{"wake_kind" => "scheduled", "profile" => "light", "cost" => 0.2})
      # an escalated light turn and its re-run after a switch
      turn(ctx, %{
        "wake_kind" => "scheduled",
        "profile" => "light",
        "escalated" => true,
        "cost" => 0.05
      })

      turn(ctx, %{
        "wake_kind" => "escalation",
        "profile" => "main",
        "model_switch" => true,
        "cost" => 1.5
      })

      routes = Map.new(Routing.by_route(nil), &{&1.key, &1})
      assert %{turns: 2} = routes["main"]
      assert %{turns: 2} = routes["light"]
      assert %{turns: 1} = routes["escalated"]
      assert %{turns: 1} = routes["rerun"]

      s = Costs.routing_savings(nil)
      assert s.light_turns == 3
      assert_in_delta s.gross, 0.8 - 0.1 + (0.8 - 0.2), 0.0001
      assert_in_delta s.waste, 0.05, 0.0001
      # the re-run has no main baseline of its own kind: no penalty counted
      assert_in_delta s.penalty, 0.0, 0.0001
      assert_in_delta s.net, 1.3 - 0.05, 0.0001
    end

    test "rule_stats/1 counts an agent's recent light turns per kind", ctx do
      for escalated <- [true, false, false] do
        turn(ctx, %{"wake_kind" => "scheduled", "profile" => "light", "escalated" => escalated})
      end

      assert [%{kind: "scheduled", turns: 3, escalated: 1}] = Costs.rule_stats(ctx.agent.id)
    end
  end

  describe "the spend report" do
    test "says routing is off and lists the candidates", ctx do
      turn(ctx, %{"trigger" => "scheduled", "model" => "opus", "passed" => true})
      text = Report.render(:week)

      assert text =~
               "Model routing (experimental, unverified until the Phase 0 spike): off for every agent"

      assert text =~ "Routing candidates"
      assert text =~ "- scheduled (may go light): 1 turns"
      assert text =~ "Estimated saving with routing on"
    end

    test "with a routed agent, the routing section and its flags", ctx do
      {:ok, _} = Canopy.Agents.update(ctx.agent, %{routing_enabled: true})
      {:ok, _} = Canopy.Agents.pause_routing(ctx.agent.id, "scheduled", "9 of 20 escalated")

      turn(ctx, %{
        "wake_kind" => "scheduled",
        "profile" => "light",
        "escalated" => true,
        "cost" => 0.4
      })

      text = Report.render(:week)
      assert text =~ "- routed agents: @#{ctx.agent.name}"
      assert text =~ "escalated per wake kind: scheduled 1 of 1"
      assert text =~ "estimated net saving"
      assert text =~ "paused rules"
      assert text =~ "light model, escalated"
    end
  end
end
