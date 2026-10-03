defmodule Canopy.Runtime.ChannelServerRoutingTest do
  @moduledoc "Model routing (experimental) through the channel runtime, against the OpenCode mock."
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Agents, Delegations, Fixtures, Messages, Repositories, Timeline}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream
  alias Canopy.Runtime
  alias Canopy.Runtime.{ChannelServer, Prompts}

  setup :set_mox_global
  setup :verify_on_exit!

  @big %{providerID: "opencode", modelID: "big"}
  @small %{providerID: "opencode", modelID: "small"}

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
    scenario = Fixtures.scenario(members: [reviewer])
    {:ok, owner} = Agents.update(scenario.agent, %{model_provider: "opencode", model_id: "big"})
    Timeline.subscribe(scenario.channel.id)

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_rev_" <> Fixtures.unique_suffix()}}
    end)

    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)

    {:ok,
     Map.merge(scenario, %{
       agent: owner,
       reviewer: reviewer,
       pid: pid,
       sid: scenario.session.engine_session_id
     })}
  end

  defp route!(agent) do
    {:ok, agent} =
      Agents.update(agent, %{
        routing_enabled: true,
        light_model_provider: "opencode",
        light_model_id: "small"
      })

    agent
  end

  defp emit(session_id, type, data) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      EventStream.session_topic(session_id),
      {:engine_event, %Event{type: type, session_id: session_id, data: data, raw_type: "test"}}
    )
  end

  defp finish(sid, opts \\ []) do
    if cost = opts[:cost], do: emit(sid, :turn_usage, %{cost: cost})

    if context = opts[:context] do
      emit(sid, :step_completed, %{
        tokens: %{"input" => context, "output" => 10, "cache" => %{"read" => 0, "write" => 0}},
        message_id: "m_" <> Fixtures.unique_suffix()
      })
    end

    if text = opts[:text], do: emit(sid, :text_done, %{text: text})
    emit(sid, :agent_completed, %{})
    assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 2_000
    payload
  end

  defp text(%{parts: [%{text: text} | _]}), do: text

  defp system(ctx) do
    agent = Agents.get!(ctx.agent.id)
    channel = Canopy.Channels.get!(ctx.channel.id)
    Prompts.system(agent, channel, ctx.repository, Repositories.list())
  end

  describe "with routing off (every agent, by default)" do
    test "the prompt sent is byte-for-byte what it was: model, text, system, tools", ctx do
      refute ctx.agent.routing_enabled

      {:ok, _} =
        Canopy.Settings.put_light_profile("opencode", %{
          model_provider: "opencode",
          model_id: "small"
        })

      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, sid, body}, 2_000
      assert sid == ctx.sid

      assert body == %{
               parts: [%{type: "text", text: "Check the queue."}],
               agent: "build",
               system: system(ctx),
               tools: %{"canopy_*" => true},
               model: @big
             }

      payload = finish(sid)
      assert payload["model"] == "opencode/big"
      assert payload["profile"] == "main"
      assert payload["route_rule"] == "off"
      assert payload["wake_kind"] == "scheduled"
      refute Map.has_key?(payload, "escalated")
      refute Map.has_key?(payload, "model_switch")
    end

    test "a message wake records its kind, why it woke the agent, and nothing else changes",
         ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "please look at the queue")
      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      refute text(body) =~ "light model"

      payload = finish(ctx.sid)
      assert payload["wake_kind"] == "user_message"
      assert payload["wake_reason"] == "owner_fallback"
      assert payload["profile"] == "main"
    end
  end

  describe "with routing on" do
    setup ctx, do: {:ok, agent: route!(ctx.agent)}

    test "a scheduled wake runs light: the light model, the light note, the same system text",
         ctx do
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, body}, 2_000

      assert body.model == @small
      assert text(body) == "Check the queue." <> Prompts.light_note()
      assert body.system == system(ctx)
      assert body.tools == %{"canopy_*" => true}

      assert Runtime.telemetry(ctx.channel.id, ctx.agent.id).model == "opencode/small · light"

      payload = finish(ctx.sid, text: "All green.")
      assert payload["profile"] == "light"
      assert payload["route_rule"] == "scheduled"
      assert payload["model"] == "opencode/small"
      assert payload["wake_kind"] == "scheduled"
      # the light turn's reply is posted like any other
      assert_receive {:timeline, %{event_type: "message", message: %{body: "All green."}}}, 2_000
    end

    test "the user's own message runs on main", ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "please look at the queue")
      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      assert finish(ctx.sid)["route_rule"] == "user"
    end

    test "a delegation task always runs on main", ctx do
      {:ok, _} =
        Delegations.create(%{
          channel_id: ctx.channel.id,
          from_agent_id: ctx.reviewer.id,
          to_agent_id: ctx.agent.id,
          description: "Summarise the logs"
        })

      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      payload = finish(ctx.sid)
      assert payload["wake_kind"] == "delegation_task"
      assert payload["route_rule"] == "delegation"
    end

    test "an unaddressed agent post reaching the owner runs light", ctx do
      {:ok, _} =
        Messages.post_agent_message(ctx.channel.id, ctx.reviewer.id, "Reviewed the queue code.")

      assert_receive {:prompted, sid, body}, 2_000
      assert sid == ctx.sid
      assert body.model == @small
      payload = finish(ctx.sid)
      assert payload["wake_kind"] == "agent_owner_fallback"
      assert payload["wake_reason"] == "owner_fallback"
    end

    test "a warm main cache with a big context keeps a cheap wake on main", ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "please look at the queue")
      assert_receive {:prompted, _sid, _body}, 2_000
      # big enough for the guard, under OpenCode's compaction cap
      finish(ctx.sid, context: 30_000)

      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      assert finish(ctx.sid)["route_rule"] == "cache_warm"
    end

    test "a paused rule runs on main", ctx do
      {:ok, _} = Agents.pause_routing(ctx.agent.id, "scheduled", "9 of 20 escalated")
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      assert finish(ctx.sid)["route_rule"] == "paused"
    end

    test "canopy_escalate mid-turn: no reply, the wake again on main, the budget untouched",
         ctx do
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000
      chatter = :sys.get_state(ctx.pid).chatter

      assert {:ok, :escalating} = ChannelServer.escalate(ctx.pid, ctx.sid, "needs edits")

      light = finish(ctx.sid, text: "Escalating.")
      assert light["escalated"] == true
      assert light["profile"] == "light"

      assert_receive {:prompted, sid, body}, 2_000
      assert sid == ctx.sid
      assert body.model == @big
      assert text(body) == Prompts.escalated("needs edits") <> "Check the queue."
      assert body.system == system(ctx)
      refute_received {:timeline, %{event_type: "message", message: %{body: "Escalating."}}}
      assert :sys.get_state(ctx.pid).chatter == chatter

      rerun = finish(ctx.sid, text: "Fixed it.")
      assert rerun["wake_kind"] == "escalation"
      assert rerun["profile"] == "main"
      assert rerun["route_rule"] == "escalation"
      assert rerun["model_switch"] == true
      assert rerun["trigger"] == "scheduled"
      refute Map.has_key?(rerun, "fallback")
      assert_receive {:timeline, %{event_type: "message", message: %{body: "Fixed it."}}}, 2_000
    end

    test "with one turn at a time, the re-run starts before a wake already in line", ctx do
      {:ok, _} = Canopy.Settings.update(%{serialize_turns: true})
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000

      # the reviewer waits in line behind the light turn
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.reviewer.name} have a look")
      refute_receive {:prompted, _, _}, 200

      {:ok, :escalating} = ChannelServer.escalate(ctx.pid, ctx.sid, nil)
      finish(ctx.sid)

      assert_receive {:prompted, sid, %{model: @big}}, 2_000
      assert sid == ctx.sid
      refute_receive {:prompted, _, _}, 200

      finish(ctx.sid)
      assert_receive {:prompted, reviewer_sid, _body}, 2_000
      assert reviewer_sid != ctx.sid
    end

    test "escalate on a main turn changes nothing", ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "please look at the queue")
      assert_receive {:prompted, _sid, %{model: @big}}, 2_000
      assert {:ok, :main} = ChannelServer.escalate(ctx.pid, ctx.sid, "more")

      payload = finish(ctx.sid, text: "Done.")
      refute Map.has_key?(payload, "escalated")
      assert_receive {:timeline, %{event_type: "message", message: %{body: "Done."}}}, 2_000
      refute_receive {:prompted, _, _}, 200
    end

    test "a light turn's error runs the wake once more on main, marked fallback", ctx do
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000

      emit(ctx.sid, :agent_error, %{
        error: %{"name" => "APIError", "data" => %{"message" => "overloaded"}}
      })

      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: light}}, 2_000
      assert light["outcome"] == "error"

      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      assert text(body) == Prompts.light_failed("overloaded") <> "Check the queue."

      # the re-run's own error is not retried
      emit(ctx.sid, :agent_error, %{
        error: %{"name" => "APIError", "data" => %{"message" => "overloaded"}}
      })

      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: rerun}}, 2_000
      assert rerun["fallback"] == true
      refute_receive {:prompted, _, _}, 200
    end

    test "a light model the engine does not know pauses routing for the agent", ctx do
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000

      emit(ctx.sid, :agent_error, %{
        error: %{
          "name" => "ProviderModelNotFoundError",
          "data" => %{"message" => "Model not found: opencode/small"}
        }
      })

      assert_receive {:prompted, _sid, %{model: @big}}, 2_000
      assert Agents.paused_kinds(ctx.agent.id) == MapSet.new(["*"])
      finish(ctx.sid)
    end

    test "a billing error engages the hold and is not re-run", ctx do
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000
      on_exit(fn -> Canopy.Hold.release() end)

      emit(ctx.sid, :agent_error, %{
        error: %{"name" => "APIError", "data" => %{"message" => "Insufficient balance"}}
      })

      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
      assert Canopy.Hold.active?()
      refute_receive {:prompted, _, _}, 200
    end

    test "the spend limit stops the re-run", ctx do
      {:ok, _} = Canopy.Channels.set_spend_limit(ctx.channel, 1.0)
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000

      {:ok, :escalating} = ChannelServer.escalate(ctx.pid, ctx.sid, nil)
      finish(ctx.sid, cost: 2.0)

      assert_receive {:timeline, %{event_type: "spend_limit_reached"}}, 2_000
      refute_receive {:prompted, _, _}, 200
    end

    test "a light turn takes no steered message: it waits and runs on main", ctx do
      {:ok, _} = Canopy.Settings.update(%{interrupt_on_mention: true, serialize_turns: false})
      Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
      assert_receive {:prompted, _sid, %{model: @small}}, 2_000

      {:ok, _} =
        Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} stop that", interrupt: true)

      refute_receive {:prompted, _, _}, 200
      finish(ctx.sid)
      assert_receive {:prompted, _sid, body}, 2_000
      assert body.model == @big
      assert text(body) =~ "stop that"
    end
  end
end
