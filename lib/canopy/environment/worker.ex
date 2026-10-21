defmodule Canopy.Environment.Worker do
  @moduledoc false
  # The reset's steps, run in a process `Canopy.Environment.Resetter` starts,
  # links and monitors. It reports `{:step, id, step}`, `{:backup, id, path}`,
  # `{:committed, id}` and, last, `{:outcome, id, result | failure}` to the
  # Resetter, and reopens (gate down, queues resumed) before it exits.
  #
  # `fail_at:` (a step, `:sweeping`, or a list of them) raises "injected
  # failure" at the start of that step: the tests' seam. For `:clearing` the
  # raise happens inside the transaction, so it rolls back.
  #
  # `step_delay_ms:` sleeps after each step is announced and before it runs
  # (dev only, from CANOPY_RESET_STEP_DELAY_MS in config/dev.exs), so the
  # running state lasts long enough to test by hand.

  require Logger

  alias Canopy.Environment
  alias Canopy.Environment.{Backup, Clear, Resetter}

  @oban_wait_ms 10_000

  def run(id, opts, resetter) do
    ctx = %{
      id: id,
      resetter: resetter,
      fail_at: opts |> Keyword.get(:fail_at) |> List.wrap(),
      step_delay_ms: Keyword.get(opts, :step_delay_ms, 0),
      backup_path: nil,
      sweep_error: nil,
      report: nil
    }

    outcome =
      try do
        steps(ctx)
      after
        Resetter.reopen()
      end

    send(resetter, {:outcome, id, outcome})
  end

  defp steps(ctx) do
    with {:ok, ctx} <- step(ctx, :stopping, &stop/1),
         {:ok, ctx} <- step(ctx, :backing_up, &back_up/1),
         {:ok, ctx} <- step(ctx, :clearing, &clear/1),
         {:ok, ctx} <- step(ctx, :seeding, &seed/1) do
      case ctx.sweep_error do
        nil ->
          %{
            id: ctx.id,
            status: :done,
            at: DateTime.utc_now(),
            backup_path: ctx.backup_path,
            seed: ctx.report
          }

        reason ->
          # seeding ran, so the starters exist; only the files are left over
          failure(ctx, :clearing, reason)
      end
    else
      {:failed, failure} -> failure
    end
  end

  # The Resetter broadcast :stopping itself when the run started.
  defp step(ctx, name, fun) do
    if name != :stopping, do: send(ctx.resetter, {:step, ctx.id, name})
    if ctx.step_delay_ms > 0, do: Process.sleep(ctx.step_delay_ms)

    try do
      case fun.(ctx) do
        {:ok, ctx} -> {:ok, ctx}
        {:error, reason} -> {:failed, failure(ctx, name, reason)}
      end
    rescue
      e -> {:failed, failure(ctx, name, Environment.error_message(e))}
    catch
      :exit, reason -> {:failed, failure(ctx, name, "exited: #{inspect(reason)}")}
    end
  end

  # Only seeding comes after the commit; a failed :clearing rolled back.
  defp failure(ctx, step, reason) do
    %{
      id: ctx.id,
      status: :failed,
      at: DateTime.utc_now(),
      step: step,
      reason: reason,
      backup_path: ctx.backup_path,
      deleted?: step == :seeding or (step == :clearing and ctx.sweep_error != nil)
    }
  end

  defp inject(ctx, step) do
    if step in ctx.fail_at, do: raise("injected failure")
  end

  ## 1. Stop everything that could write or wake an agent

  defp stop(ctx) do
    inject(ctx, :stopping)

    case Resetter.await_seeds() do
      :ok ->
        pause_oban()
        Canopy.Runtime.Supervisor.stop_all_channels()
        Canopy.ClaudeCode.Supervisor.stop_all_turns()
        Canopy.Codex.Supervisor.stop_all_turns()
        {:ok, ctx}

      {:error, :timeout} ->
        {:error, "a seeder run didn't finish within 10 seconds"}
    end
  end

  # A job still executing after the wait is left alone: it finds its row gone.
  defp pause_oban do
    if Resetter.oban_running?() do
      :ok = Oban.pause_all_queues(Oban)
      deadline = System.monotonic_time(:millisecond) + @oban_wait_ms
      wait_for_jobs(deadline)
    end
  end

  defp wait_for_jobs(deadline) do
    busy? = Enum.any?(Oban.check_all_queues(Oban), &(&1.running != []))

    cond do
      not busy? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("environment reset: Oban jobs still executing after the wait")

      true ->
        Process.sleep(100)
        wait_for_jobs(deadline)
    end
  end

  ## 2. Back up the database

  defp back_up(ctx) do
    inject(ctx, :backing_up)
    backup = Backup.impl()
    path = backup.path(NaiveDateTime.local_now())

    result =
      try do
        backup.run(path)
      rescue
        e -> {:error, Environment.error_message(e)}
      end

    case {result, File.stat(path)} do
      {:ok, {:ok, %File.Stat{size: size}}} when size > 0 ->
        send(ctx.resetter, {:backup, ctx.id, path})
        {:ok, %{ctx | backup_path: path}}

      {:ok, _} ->
        File.rm(path)
        {:error, "the backup file is missing or empty"}

      {{:error, reason}, _} ->
        File.rm(path)
        {:error, reason}
    end
  end

  ## 3. Delete, then sweep the documents' files

  defp clear(ctx) do
    case Clear.run(fn -> inject(ctx, :clearing) end) do
      {:ok, _} ->
        send(ctx.resetter, {:committed, ctx.id})
        # the clear deleted the pending lifts of the pauses it kept
        Canopy.EnginePauses.reschedule_all()
        {:ok, %{ctx | sweep_error: sweep(ctx)}}

      {:error, reason} when is_exception(reason) ->
        {:error, Environment.error_message(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Not fatal: the run goes on to seed and reports the sweep at the end.
  defp sweep(ctx) do
    inject(ctx, :sweeping)

    case Clear.sweep() do
      :ok -> nil
      {:error, reason} -> reason
    end
  rescue
    e -> Environment.error_message(e)
  end

  ## 4. Seed the starters

  defp seed(ctx) do
    inject(ctx, :seeding)

    case Canopy.Seeds.run() do
      {:ok, report} -> {:ok, %{ctx | report: report}}
      {:error, reason, _partial} -> {:error, reason}
    end
  end
end
