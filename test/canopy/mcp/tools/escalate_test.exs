defmodule Canopy.MCP.Tools.EscalateTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.{Agents, Runtime}
  alias Canopy.MCP.Tools.Escalate
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ctx = scenario()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(ctx.repository.id)
    test_pid = self()

    stub(OC, :prompt_async, fn _dir, _sid, body, _opts ->
      send(test_pid, {:prompted, body})
      {:ok, ""}
    end)

    {:ok, _} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
    ctx
  end

  test "it is in the tool list" do
    assert "escalate" in Canopy.MCP.Server.tool_names()
  end

  test "without a turn in flight it says there is nothing to escalate", ctx do
    assert {:ok, text} = call(Escalate, %{reason: "needs edits"}, ctx)
    assert text =~ "no Canopy turn is in flight"
  end

  test "on a main turn nothing changes", ctx do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "please look")
    assert_receive {:prompted, _body}, 2_000

    assert {:ok, text} = call(Escalate, %{}, ctx)
    assert text =~ "already on your main model"
  end

  test "on a light turn it escalates; the identity comes from the session token", ctx do
    {:ok, _} =
      Agents.update(ctx.agent, %{
        model_provider: "opencode",
        model_id: "big",
        routing_enabled: true,
        light_model_provider: "opencode",
        light_model_id: "small"
      })

    Runtime.wake_scheduled(ctx.channel.id, ctx.agent.id, "Check the queue.")
    assert_receive {:prompted, %{model: %{modelID: "small"}}}, 2_000

    assert {:ok, text} = call_as_session(Escalate, %{"reason" => "needs edits"}, ctx.session)
    assert text =~ "Escalating"
  end
end
