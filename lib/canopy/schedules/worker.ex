defmodule Canopy.Schedules.Worker do
  @moduledoc """
  Fires a schedule: wakes its agent in its channel with the instruction, then
  marks the run and, for recurring schedules, enqueues the next one.

  A job that finds its schedule inactive (cancelled, paused, done) or its
  channel archived, or its agent deactivated, records a skip and stops.
  """

  # One pending job per schedule. Executing and completed jobs are not counted,
  # or a recurring schedule could never enqueue its successor from inside its run.
  use Oban.Worker,
    queue: :schedules,
    max_attempts: 3,
    unique: [
      keys: [:schedule_id],
      states: [:scheduled, :available, :retryable],
      period: :infinity
    ]

  alias Canopy.Schedules

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"schedule_id" => id}}) do
    Schedules.fire(id)
  end
end
