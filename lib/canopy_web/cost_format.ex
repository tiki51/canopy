defmodule CanopyWeb.CostFormat do
  @moduledoc """
  Cost figures that may hold an estimate. Claude Code and OpenCode report what
  a turn cost; Codex's cost is estimated from its tokens at OpenAI's API list
  prices (`Canopy.Costs` returns the estimated part as `estimated`). Any figure
  that contains an estimate reads `≈$1.03`, and its `title` gives the split.
  """

  alias Canopy.Costs

  @doc "`Costs.money/1`, with `≈` when part of `cost` is estimated."
  def money(cost, estimated) do
    if estimated?(estimated), do: "≈" <> Costs.money(cost), else: Costs.money(cost)
  end

  @doc "The same for an aggregate row with `cost` and `estimated`."
  def money(%{cost: cost} = row), do: money(cost, Map.get(row, :estimated))

  @doc "The 4-decimal form of the activity cards, with `≈` for an estimate."
  def format_cost(cost, estimated?) do
    if estimated? == true,
      do: "≈" <> Canopy.Runtime.Activity.format_cost(cost),
      else: Canopy.Runtime.Activity.format_cost(cost)
  end

  @doc """
  The split behind a `≈` figure, for its `title`, or nil when nothing in it
  is estimated.
  """
  def estimate_title(cost, estimated) do
    if estimated?(estimated) do
      reported = max(cost - estimated, 0.0)

      estimate =
        "≈#{Costs.money(estimated)} estimated from Codex tokens at OpenAI's API list prices"

      if reported > 0,
        do: "#{Costs.money(reported)} reported · #{estimate}",
        else: estimate
    end
  end

  @doc "`estimate_title/2` for an aggregate row."
  def estimate_title(%{cost: cost} = row), do: estimate_title(cost, Map.get(row, :estimated))

  @doc "Whether an `estimated` amount is worth marking."
  def estimated?(estimated), do: is_number(estimated) and estimated > 0
end
