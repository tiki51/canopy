defmodule Canopy.Environment.Resetter do
  @moduledoc """
  Runs one reset at a time and remembers the last one's outcome (in memory;
  a restart forgets it).

  `reset/1` decides in one call: the busy check, the gate, the first state and
  the first `:reset_step` broadcast all happen there, so two tabs can't both
  start one, and `status/0` is `{:running, _}` as soon as it returns. The work
  runs in a linked worker (`Canopy.Environment.Worker`):

  1. `:stopping`: waits for a seed in flight, pauses Oban and waits for
     executing jobs, shuts every channel server down (aborting its turns
     through the engine) and stops any Claude Code turn left.
  2. `:backing_up`: `VACUUM INTO` a file next to the database.
  3. `:clearing`: one `IMMEDIATE` transaction empties every cleared table
     (`Canopy.Environment.Clear`), then the documents' files are deleted. A
     failed file sweep doesn't stop the run.
  4. `:seeding`: `Canopy.Seeds.run/0`.

  Then the gate comes down and the queues resume. The worker reports progress
  here; this process updates its state, then broadcasts, so `status/0` is
  never behind a broadcast. `status/0` and `last_reset/0` are answered from
  state and never wait on the worker.

  **A run ends on the worker's `:DOWN`.** The worker sends its outcome as its
  last message and reopens (gate down, queues resumed) before it exits; this
  process only stashes the outcome. On the `:DOWN` of the current run's
  monitor it reopens again (idempotent: this covers a worker that was killed),
  broadcasts the outcome, then replies to `await_idle/1` callers and goes idle
  (a `status/0` call is served after that, so it never sees the old run). A worker that died
  without an outcome fails at the step it reached, except after the commit,
  which is reported as `:seeding` with `deleted?: true`: the starters may be
  missing, and Rerun seeder is the user's next step. So the gate is down
  before every final broadcast, and a second reset can't have its gate
  lowered by the first run's worker.

  **The gate can't stick.** `reopen/0` runs in the worker's `after`, on its
  `:DOWN`, and in `init/1`, so a restart of this process lowers it too. The
  worker is linked and this process traps exits: a worker crash doesn't take
  this process down, and if this process is killed outright the link kills
  the worker with it (its open transaction rolls back with its connection).

  **Seeds are serialized with the reset.** `Canopy.Environment.seed/0` calls
  `seed_begin/0`, refused while a run is in progress, and `seed_end/0` (a
  `:DOWN` of the caller counts too). The worker's first step waits for seeds
  in flight with `await_seeds/0`, for at most 10 s.

  **Slowing a run down (dev only).** `CANOPY_RESET_STEP_DELAY_MS=<ms>` makes
  the worker sleep that long at the start of each step, so a reload, a second
  tab or an MCP call can be tried while the reset runs. It is read in
  `config/dev.exs` into `:environment_reset_opts`, never in `runtime.exs`, so
  a release ignores it. Unset, there is no delay.
  """

  use GenServer

  require Logger

  alias Canopy.Environment
  alias Canopy.Environment.Worker

  @steps [:stopping, :backing_up, :clearing, :seeding]
  @seed_wait_ms 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts a reset: `{:ok, id}` or `{:error, :already_running}`."
  def reset(opts \\ []), do: GenServer.call(__MODULE__, {:reset, opts})

  def status, do: GenServer.call(__MODULE__, :status)

  def last_reset, do: GenServer.call(__MODULE__, :last_reset)

  @doc "Registers the caller's seed: `:ok`, or `{:error, :resetting}` while a reset runs."
  def seed_begin, do: GenServer.call(__MODULE__, :seed_begin)

  def seed_end, do: GenServer.cast(__MODULE__, {:seed_end, self()})

  @doc "For the worker: `:ok` once no seed is in flight, or `{:error, :timeout}` after 10 s."
  def await_seeds, do: GenServer.call(__MODULE__, :await_seeds, @seed_wait_ms + 5_000)

  @doc "Returns once no reset is running and its worker has exited (tests' `await_reset/0`)."
  def await_idle(timeout \\ 5_000), do: GenServer.call(__MODULE__, :await_idle, timeout)

  @doc false
  # Tests only: banner tests must not depend on the order tests ran in.
  def forget, do: GenServer.call(__MODULE__, :forget)

  @doc "Lowers the gate and resumes Oban's queues. Idempotent."
  def reopen do
    Environment.lower_gate()
    if oban_running?(), do: Oban.resume_all_queues(Oban)
    :ok
  end

  @doc false
  def oban_running? do
    Oban.config(Oban).testing == :disabled
  rescue
    _ -> false
  end

  @doc false
  def progress(id, step) do
    %{id: id, step: step, index: Enum.find_index(@steps, &(&1 == step)) + 1, total: 4}
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # Open tabs aren't told: a Settings tab locked in :running stays so until it reloads.
    if Environment.resetting?(),
      do: Logger.warning("environment reset: the Resetter restarted mid-run; lowering the gate")

    reopen()

    {:ok,
     %{
       run: nil,
       last_reset: nil,
       seeds: %{},
       seed_waiters: %{},
       idle_waiters: []
     }}
  end

  @impl true
  def handle_call({:reset, _opts}, _from, %{run: %{}} = state),
    do: {:reply, {:error, :already_running}, state}

  def handle_call({:reset, opts}, _from, state) do
    id = Canopy.ID.generate("rst")
    opts = Keyword.merge(Application.get_env(:canopy, :environment_reset_opts, []), opts)

    Environment.raise_gate()
    pid = spawn_link(Worker, :run, [id, opts, self()])
    ref = Process.monitor(pid)

    run = %{
      id: id,
      pid: pid,
      ref: ref,
      step: :stopping,
      committed?: false,
      backup_path: nil,
      outcome: nil
    }

    Environment.broadcast({:reset_step, progress(id, :stopping)})
    {:reply, {:ok, id}, %{state | run: run}}
  end

  def handle_call(:status, _from, %{run: nil} = state), do: {:reply, :idle, state}

  def handle_call(:status, _from, %{run: run} = state),
    do: {:reply, {:running, progress(run.id, run.step)}, state}

  def handle_call(:last_reset, _from, state), do: {:reply, state.last_reset, state}

  def handle_call(:seed_begin, {pid, _}, state) do
    cond do
      state.run || Environment.resetting?() ->
        {:reply, {:error, :resetting}, state}

      Map.has_key?(state.seeds, pid) ->
        {:reply, :ok, state}

      true ->
        {:reply, :ok, put_in(state.seeds[pid], Process.monitor(pid))}
    end
  end

  def handle_call(:await_seeds, _from, %{seeds: seeds} = state) when map_size(seeds) == 0,
    do: {:reply, :ok, state}

  def handle_call(:await_seeds, from, state) do
    tag = make_ref()
    timer = Process.send_after(self(), {:seed_wait_timeout, tag}, @seed_wait_ms)
    {:noreply, put_in(state.seed_waiters[tag], {from, timer})}
  end

  def handle_call(:await_idle, _from, %{run: nil} = state), do: {:reply, :ok, state}

  def handle_call(:await_idle, from, state),
    do: {:noreply, %{state | idle_waiters: [from | state.idle_waiters]}}

  def handle_call(:forget, _from, state), do: {:reply, :ok, %{state | last_reset: nil}}

  @impl true
  def handle_cast({:seed_end, pid}, state), do: {:noreply, end_seed(state, pid)}

  @impl true
  def handle_info({:step, id, step}, %{run: %{id: id} = run} = state) do
    Environment.broadcast({:reset_step, progress(id, step)})
    {:noreply, %{state | run: %{run | step: step}}}
  end

  def handle_info({:backup, id, path}, %{run: %{id: id} = run} = state),
    do: {:noreply, %{state | run: %{run | backup_path: path}}}

  def handle_info({:committed, id}, %{run: %{id: id} = run} = state),
    do: {:noreply, %{state | run: %{run | committed?: true}}}

  def handle_info({:outcome, id, outcome}, %{run: %{id: id} = run} = state),
    do: {:noreply, %{state | run: %{run | outcome: outcome}}}

  # the current run's worker is gone: the run ends here
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{ref: ref} = run} = state) do
    reopen()
    outcome = run.outcome || crash_failure(run, reason)

    case outcome do
      %{status: :done} -> Environment.broadcast({:reset_done, outcome})
      %{status: :failed} -> Environment.broadcast({:reset_failed, outcome})
    end

    # after the broadcast, so a test's await_reset/0 can't overtake it
    Enum.each(state.idle_waiters, &GenServer.reply(&1, :ok))
    {:noreply, %{state | run: nil, last_reset: outcome, idle_waiters: []}}
  end

  # a seed's caller went away without saying so
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, end_seed(state, pid)}

  def handle_info({:seed_wait_timeout, tag}, state) do
    case Map.pop(state.seed_waiters, tag) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | seed_waiters: waiters}}
    end
  end

  # a worker's exit signal (we trap exits); its :DOWN does the work
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # a stale message from an earlier run
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{run: %{pid: pid}}) do
    Process.exit(pid, :kill)
    reopen()
  end

  def terminate(_reason, _state), do: reopen()

  defp end_seed(state, pid) do
    case Map.pop(state.seeds, pid) do
      {nil, _} ->
        state

      {ref, seeds} ->
        Process.demonitor(ref, [:flush])
        state = %{state | seeds: seeds}

        if map_size(seeds) == 0 do
          Enum.each(state.seed_waiters, fn {_tag, {from, timer}} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, :ok)
          end)

          %{state | seed_waiters: %{}}
        else
          state
        end
    end
  end

  defp crash_failure(run, reason) do
    Logger.error("environment reset #{run.id} stopped unexpectedly: #{inspect(reason)}")

    {step, deleted?} = if run.committed?, do: {:seeding, true}, else: {run.step, false}

    %{
      id: run.id,
      status: :failed,
      at: DateTime.utc_now(),
      step: step,
      reason: "the reset stopped unexpectedly (#{exit_reason(reason)})",
      backup_path: run.backup_path,
      deleted?: deleted?
    }
  end

  defp exit_reason({exception, _stack}) when is_exception(exception),
    do: Environment.error_message(exception)

  defp exit_reason(reason), do: inspect(reason)
end
