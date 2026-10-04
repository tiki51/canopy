defmodule CanopyWeb.RoutingLiveTest do
  @moduledoc "Model routing (experimental) on the Agents, Settings, and Costs pages."
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Agents, Fixtures, Settings, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  @providers %{
    "providers" => [
      %{
        "id" => "opencode",
        "name" => "OpenCode Zen",
        "models" => %{
          "small" => %{"cost" => %{"input" => 0.1, "output" => 0.4}},
          "big" => %{"cost" => %{"input" => 2, "output" => 10}}
        }
      }
    ],
    "default" => %{"opencode" => "small"}
  }

  setup do
    stub(OC, :providers, fn _opts -> {:ok, @providers} end)
    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :health, fn _opts -> {:ok, %{"healthy" => true}} end)
    :ok
  end

  describe "the agent form" do
    test "routing is off, labelled experimental; Default saves nil and the page says so", %{
      conn: conn
    } do
      {:ok, _} = Settings.put_light_profile("claude_code", %{model_id: "haiku"})
      agent = Fixtures.agent_fixture(%{name: "routy", engine: "claude_code", model_id: "sonnet"})

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert has_element?(view, "#agent-routing-fields", "experimental")

      assert has_element?(
               view,
               "#routing-experimental-note",
               "Experimental: not yet checked against the real engines."
             )

      refute has_element?(view, "#agent-routing-enabled[checked]")
      assert has_element?(view, "select#claude-light-model option[value='']", "Default (haiku)")

      view
      |> form("#agent-form",
        agent: %{routing_enabled: "true", light_model_id: "", light_effort: ""}
      )
      |> render_submit()

      assert %{routing_enabled: true, light_model_id: nil, light_effort: nil} =
               Agents.get!(agent.id)

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-routing", "on · light haiku (default)")
      assert has_element?(view, "#agent-routing", "experimental")
      assert has_element?(view, "#agent-routing-panel", "No light turns yet")

      {:ok, view, _html} = live(conn, ~p"/agents")
      assert has_element?(view, "#routed-#{agent.id}", "routed")
    end

    test "routing on with no light model anywhere says so", %{conn: conn} do
      agent =
        Fixtures.agent_fixture(%{name: "nolight", engine: "claude_code", routing_enabled: true})

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-routing", "Routing is on but no light model is set")
    end

    test "an OpenCode agent picks its light model from OpenCode's list", %{conn: conn} do
      agent = Fixtures.agent_fixture(%{name: "ocroute"})
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      _ = render_async(view)
      assert has_element?(view, "select#opencode-light-provider option[value='opencode']")

      view
      |> form("#agent-form", agent: %{light_model_provider: "opencode"})
      |> render_change()

      view
      |> form("#agent-form",
        agent: %{
          routing_enabled: "true",
          light_model_provider: "opencode",
          light_model_id: "small"
        }
      )
      |> render_submit()

      assert %{light_model_provider: "opencode", light_model_id: "small"} = Agents.get!(agent.id)
    end

    test "a paused rule shows with Resume", %{conn: conn} do
      agent = Fixtures.agent_fixture(%{name: "paused", routing_enabled: true})
      {:ok, _} = Agents.pause_routing(agent.id, "scheduled", "9 of 20 escalated")

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      assert has_element?(
               view,
               "#routing-pause-scheduled",
               "Routing paused for scheduled wakes: 9 of 20 escalated"
             )

      view |> element("#resume-routing-scheduled") |> render_click()
      refute has_element?(view, "#routing-pause-scheduled")
      assert Agents.paused_kinds(agent.id) == MapSet.new()
    end
  end

  describe "Settings" do
    test "a light model per engine", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      _ = render_async(view)
      assert has_element?(view, "select#claude-light-model option[value='']", "No light model")

      view
      |> form("#claude-form", setting: %{claude_light_model: "haiku", claude_light_effort: "low"})
      |> render_submit()

      assert Settings.light_profile("claude_code") ==
               %{model_provider: nil, model_id: "haiku", effort: "low"}

      assert has_element?(view, "select#opencode-light-provider option[value='opencode']")

      view
      |> form("#opencode-form", setting: %{opencode_light_provider: "opencode"})
      |> render_change()

      view
      |> form("#opencode-form",
        setting: %{opencode_light_provider: "opencode", opencode_light_model: "small"}
      )
      |> render_submit()

      assert %{model_provider: "opencode", model_id: "small"} = Settings.light_profile("opencode")
    end
  end

  describe "the Costs page" do
    defp turn(ctx, payload) do
      {:ok, _} =
        Timeline.record(%{
          channel_id: ctx.channel.id,
          agent_id: ctx.agent.id,
          event_type: "agent_turn_completed",
          payload:
            Map.merge(
              %{"outcome" => "ok", "cost" => 0.5, "tools" => 1, "model" => "opus"},
              payload
            )
        })
    end

    test "off for every agent, with the candidates", %{conn: conn} do
      ctx = Fixtures.scenario()
      turn(ctx, %{"trigger" => "scheduled", "passed" => true})

      {:ok, view, _html} = live(conn, ~p"/costs")

      assert has_element?(
               view,
               "#routing",
               "Experimental: not yet checked against the real engines."
             )

      assert has_element?(view, "#routing-off", "Off for every agent")
      assert has_element?(view, "#candidate-scheduled")
    end

    test "with a routed agent, its numbers and the light flags", %{conn: conn} do
      ctx = Fixtures.scenario()
      {:ok, _} = Agents.update(ctx.agent, %{routing_enabled: true})

      turn(ctx, %{
        "wake_kind" => "scheduled",
        "profile" => "light",
        "escalated" => true,
        "cost" => 0.9
      })

      {:ok, view, _html} = live(conn, ~p"/costs")
      assert has_element?(view, "#routing-agents", "1")
      assert has_element?(view, "#routing-light", "1")
      assert has_element?(view, "#routing-escalated", "100%")
      assert has_element?(view, "#routing-net")
      assert has_element?(view, "#top-turns", "escalated")
    end
  end
end
