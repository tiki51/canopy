defmodule Canopy.Playbooks.StallWorker do
  @moduledoc """
  Checks a playbook run for a stall when its `stall_after` is due: one
  pending job per run, scheduled for the last activity plus `stall_after`.
  A run that saw activity since the job was scheduled gets a new job for
  its new due time; a stalled one gets its nudge (`Canopy.Playbooks.Runs.check_stall/2`),
  and the chain stops there until activity resumes and enqueues it again.
  Runs finished, waiting on the user's approval, or without `stall_after`
  need no job.
  """

  # One pending job per run. The executing job does not count, so a job can
  # enqueue its successor for a later due time from inside its own run.
  use Oban.Worker,
    queue: :schedules,
    max_attempts: 3,
    unique: [keys: [:run_id], states: [:scheduled, :available, :retryable], period: :infinity]

  import Ecto.Query, only: [from: 2]

  alias Canopy.Playbooks.{Run, Runs}
  alias Canopy.Repo

  @doc """
  Makes sure an active run with a stall timeout has its check scheduled.
  Returns `{:ok, job}`, `:ok` when the run needs none, or `{:error, reason}`.
  """
  def enqueue(%{status: "active", stall_after_minutes: minutes, nudged_at: nil} = run)
      when is_integer(minutes) do
    %{run_id: run.id} |> new(scheduled_at: Runs.stall_due(run)) |> Oban.insert()
  end

  def enqueue(_run), do: :ok

  @doc """
  Schedules the check of every run that should have one and may have lost it
  (a crash between a check and its successor's insert). Uniqueness makes it
  a no-op for runs whose check is pending. Run when the app boots.
  """
  def reconcile do
    from(r in Run,
      where: r.status == "active" and not is_nil(r.stall_after_minutes) and is_nil(r.nudged_at)
    )
    |> Repo.all()
    |> Enum.each(&enqueue/1)
  end

  @doc false
  # the job's result once it scheduled its successor: an insert that failed
  # fails the job (Oban retries it), so the run is never left unchecked
  def after_enqueue({:error, reason}), do: {:error, reason}
  def after_enqueue(_ok), do: :ok

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => id}}) do
    cond do
      # agent runs are on hold: look again later rather than nudge into it
      Canopy.Hold.active?() ->
        {:snooze, 600}

      run = Runs.get(id) ->
        case Runs.check_stall(run) do
          # the successor must exist, or the run is never checked again: a
          # failed insert fails this job, and Oban retries it
          {:wait, _due} ->
            run |> enqueue() |> after_enqueue()

          _ ->
            :ok
        end

      true ->
        :ok
    end
  end
end
