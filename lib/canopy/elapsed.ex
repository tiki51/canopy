defmodule Canopy.Elapsed do
  @moduledoc """
  How long something has been going, in whole minutes: `<1m`, `4m`,
  `1h 5m`. One formatter for a lock's age (`Canopy.Locks.age/2`, which
  agents read too) and the coarse durations the channel shows
  (`CanopyWeb.TimelineComponents.elapsed/1`). The `.Elapsed` hook's
  JavaScript formatter, which ticks those in the browser, mirrors it.
  """

  @doc "A duration in milliseconds, in whole minutes; negative counts as 0."
  def coarse(ms) when is_integer(ms) do
    case max(0, div(ms, 60_000)) do
      0 -> "<1m"
      m when m < 60 -> "#{m}m"
      m -> "#{div(m, 60)}h #{rem(m, 60)}m"
    end
  end

  @doc "The time from `from` to `now`, as `coarse/1` says it."
  def since(%DateTime{} = from, %DateTime{} = now \\ DateTime.utc_now()),
    do: coarse(DateTime.diff(now, from, :millisecond))
end
