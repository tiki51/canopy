defmodule Canopy.Elapsed do
  @moduledoc """
  How long something has been going, in whole minutes: `<1m`, `4m`,
  `1h 5m`, and the time left on a countdown (`remaining/1`). One formatter for a lock's age (`Canopy.Locks.age/2`, which
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

  @doc """
  Time left in milliseconds, for a countdown: `coarse/1` up to a day, then
  whole days and hours (`2d 3h`), since a weekly limit resets days away.
  Negative counts as 0. The `.Countdown` hook mirrors it.
  """
  def remaining(ms) when is_integer(ms) do
    case max(0, div(ms, 60_000)) do
      m when m < 24 * 60 -> coarse(ms)
      m -> "#{div(m, 24 * 60)}d #{div(rem(m, 24 * 60), 60)}h"
    end
  end

  @doc "The time from `from` to `now`, as `coarse/1` says it."
  def since(%DateTime{} = from, %DateTime{} = now \\ DateTime.utc_now()),
    do: coarse(DateTime.diff(now, from, :millisecond))
end
