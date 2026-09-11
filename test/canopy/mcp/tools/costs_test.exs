defmodule Canopy.MCP.Tools.CostsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.Timeline
  alias Canopy.MCP.Tools.CostsReport
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  test "costs_report returns the report for a period" do
    ctx = scenario()
    stub(OC, :providers, fn _opts -> {:error, :down} end)

    {:ok, _} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "agent_turn_completed",
        payload: %{"outcome" => "ok", "cost" => 1.25, "tools" => 2, "duration_ms" => 10}
      })

    assert {:ok, text} = call(CostsReport, %{}, ctx)
    assert text =~ "spend report for the last 7 days"
    assert text =~ "Total: $1.25 over 1 turns"

    assert {:ok, text} = call(CostsReport, %{period: "all"}, ctx)
    assert text =~ "spend report for all time"

    assert {:error, "unknown period \"soon\"" <> _} = call(CostsReport, %{period: "soon"}, ctx)
  end
end
