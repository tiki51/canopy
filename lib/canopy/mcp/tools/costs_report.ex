defmodule Canopy.MCP.Tools.CostsReport do
  @moduledoc """
  What agents have spent, as reported by the model providers through
  OpenCode: totals and breakdowns by agent, channel, model, and trigger,
  efficiency (model calls, tokens, cache hits, wasted turns), the costliest
  turns, channel spend limits, the settings that shape spend, and model
  prices. Use it when asked to audit or reduce costs.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Costs.Report
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :period, :string, description: "today, week (default), month, or all."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn _ctx, params ->
      with {:ok, period} <- Report.period(Map.get(params, :period)) do
        {:ok, Report.render(period)}
      end
    end)
  end
end
