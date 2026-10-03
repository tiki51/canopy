defmodule Canopy.Watches.SweepWorker do
  @moduledoc """
  Checks every GitHub watch that is due (`Canopy.Watches.sweep/1`). One
  static cron entry runs it each minute (`config :canopy, Oban`), in the
  `watches` queue: watches are rows, not jobs, so a watch checked every
  minute leaves no trail of 1,440 jobs a day.
  """

  # Its own queue (one at a time), so a slow sweep never holds a slot that
  # scheduled tasks and stall checks need; and unique across every live
  # state, so a sweep still running when the next minute comes is not joined
  # by a second one.
  use Oban.Worker,
    queue: :watches,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Canopy.Watches.sweep()
    :ok
  end
end
