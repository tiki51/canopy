defmodule Canopy.EnginePauses.LiftWorker do
  @moduledoc """
  Lifts an engine's pause a minute after its reset time
  (`Canopy.EnginePauses.resume/2` with `"reset"`), whether or not any agent
  is waiting. One pending job per pause: a later reset time re-times it
  (`replace: [scheduled: [:scheduled_at]]` at insert).
  """

  use Oban.Worker,
    queue: :schedules,
    max_attempts: 3,
    unique: [
      keys: [:pause_id],
      states: [:scheduled, :available, :retryable],
      period: :infinity
    ]

  alias Canopy.EnginePauses

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pause_id" => id}}) do
    case EnginePauses.get_pause(id) do
      %{lifted_at: nil, engine: engine} -> EnginePauses.resume(engine, "reset")
      _ -> :ok
    end
  end
end
