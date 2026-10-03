defmodule Canopy.Runtime.RoutingTest do
  use ExUnit.Case, async: true

  alias Canopy.Runtime.Routing

  @ttl 300_000
  @now 10_000_000

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{enabled?: true, light?: true, paused: MapSet.new(), cache: %{}, now: @now, ttl: @ttl},
      Map.new(overrides)
    )
  end

  defp wake(kind, ack \\ false), do: %{kinds: [{kind, ack}]}

  describe "route/2: the rules table" do
    for {kind, ack, expected} <- [
          {"user_message", false, {:main, "user"}},
          {"agent_mention", true, {:light, "ack"}},
          {"agent_mention", false, {:main, "not_ack"}},
          {"agent_thread", true, {:light, "ack"}},
          {"agent_thread", false, {:main, "not_ack"}},
          {"agent_owner_fallback", false, {:light, "agent_owner_fallback"}},
          {"delegation_task", false, {:main, "delegation"}},
          {"delegation_report", false, {:light, "delegation_report"}},
          {"handoff_request", false, {:main, "handoff"}},
          {"handoff_rejected", false, {:main, "handoff"}},
          {"handoff_accepted", false, {:light, "handoff_accepted"}},
          {"scheduled", false, {:light, "scheduled"}},
          {"escalation", false, {:main, "escalation"}},
          {"playbook", false, {:main, "playbook"}},
          {"playbook_nudge", false, {:main, "playbook"}},
          {"watch", false, {:main, "watch"}},
          {"lock_grant", false, {:main, "lock"}},
          {"other", false, {:main, "other"}}
        ] do
      test "#{kind}#{if ack, do: " (ack)", else: ""} -> #{inspect(expected)}" do
        assert Routing.route(wake(unquote(kind), unquote(ack)), facts()) == unquote(expected)
      end
    end

    test "any wake carrying delegation ids runs on main" do
      assert Routing.route(%{kinds: [{"scheduled", false}], delegation_ids: ["dl_1"]}, facts()) ==
               {:main, "delegation"}
    end

    test "routing off, or no light profile, runs everything on main" do
      assert Routing.route(wake("scheduled"), facts(enabled?: false)) == {:main, "off"}
      assert Routing.route(wake("scheduled"), facts(light?: false)) == {:main, "no_light_model"}
    end
  end

  describe "route/2: merged wakes" do
    test "light only when every part would go light" do
      assert Routing.route(%{kinds: [{"scheduled", false}, {"handoff_accepted", false}]}, facts()) ==
               {:light, "handoff_accepted"}

      assert Routing.route(%{kinds: [{"scheduled", false}, {"user_message", false}]}, facts()) ==
               {:main, "merged"}
    end

    test "light plus a delegation task is main" do
      assert Routing.route(%{kinds: [{"scheduled", false}, {"delegation_task", false}]}, facts()) ==
               {:main, "merged"}
    end
  end

  describe "route/2: cache warmth" do
    test "a warm main cache with a cold light lineage and a big context stays on main" do
      cache = %{main: @now - (@ttl - 1), context: 60_000}
      assert Routing.route(wake("scheduled"), facts(cache: cache)) == {:main, "cache_warm"}
    end

    test "at the TTL boundary the main cache counts as cold" do
      cache = %{main: @now - @ttl, context: 60_000}
      assert Routing.route(wake("scheduled"), facts(cache: cache)) == {:light, "scheduled"}
    end

    test "a warm light lineage, or a small context, goes light" do
      warm_light = %{main: @now - 1_000, light: @now - 2_000, context: 60_000}
      assert Routing.route(wake("scheduled"), facts(cache: warm_light)) == {:light, "scheduled"}

      small = %{main: @now - 1_000, context: 19_999}
      assert Routing.route(wake("scheduled"), facts(cache: small)) == {:light, "scheduled"}
    end
  end

  describe "route/2: paused rules" do
    test "a paused kind runs on main" do
      paused = MapSet.new(["scheduled"])
      assert Routing.route(wake("scheduled"), facts(paused: paused)) == {:main, "paused"}

      assert Routing.route(wake("handoff_accepted"), facts(paused: paused)) ==
               {:light, "handoff_accepted"}
    end

    test "\"*\" pauses every kind" do
      assert Routing.route(wake("scheduled"), facts(paused: MapSet.new(["*"]))) ==
               {:main, "paused"}
    end
  end

  describe "ack?/1" do
    test "acknowledgements" do
      for body <- ["thanks!", "👍", "ok, done", "Got it", "LGTM", "sounds good, thank you"] do
        assert Routing.ack?(body), body
      end
    end

    test "not acknowledgements" do
      for body <- [
            "ok?",
            "see https://example.com",
            "done, see `lib/a.ex`",
            "thanks, but the build on main is still failing in three places and I need you to dig into the logs",
            "",
            nil
          ] do
        refute Routing.ack?(body), inspect(body)
      end
    end

    test "three words or fewer count even outside the lexicon" do
      assert Routing.ack?("Merged and deployed.")
      refute Routing.ack?("Please investigate the flaky test")
    end
  end

  test "kinds for Canopy's own wakes come from the trigger" do
    assert Routing.kind_for_trigger("scheduled") == "scheduled"
    assert Routing.kind_for_trigger("watch") == "watch"
    assert Routing.kind_for_trigger("playbook_nudge") == "playbook_nudge"
    assert Routing.kind_for_trigger("lock") == "lock_grant"
    assert Routing.kind_for_trigger("whatever") == "other"
  end

  describe "event_kind/3" do
    test "a user message is user_message whatever it says; ack is for agent posts only" do
      user = %{event_type: "message", message: %{agent_id: nil}}

      assert Routing.event_kind(user, :owner_fallback, true) ==
               %{wake_kind: "user_message", wake_reason: "owner_fallback", ack: nil}

      agent = %{event_type: "message", message: %{agent_id: "agt_1"}}
      assert %{wake_kind: "agent_mention", ack: true} = Routing.event_kind(agent, :mention, true)

      assert %{wake_kind: "agent_thread", ack: false} =
               Routing.event_kind(agent, :thread_author, false)

      assert %{wake_kind: "agent_owner_fallback"} =
               Routing.event_kind(agent, :owner_fallback, false)
    end

    test "delegation and handoff events" do
      for {type, kind} <- [
            {"delegation_created", "delegation_task"},
            {"delegation_completed", "delegation_report"},
            {"delegation_failed", "delegation_report"},
            {"handoff_requested", "handoff_request"},
            {"handoff_accepted", "handoff_accepted"},
            {"handoff_rejected", "handoff_rejected"}
          ] do
        assert %{wake_kind: ^kind} = Routing.event_kind(%{event_type: type}, nil, nil)
      end
    end
  end
end
