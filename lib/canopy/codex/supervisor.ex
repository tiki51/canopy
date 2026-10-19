defmodule Canopy.Codex.Supervisor do
  @moduledoc """
  Owns the `Canopy.Codex.Turn` processes: one per engine session while a turn
  runs, registered in `Canopy.Codex.TurnRegistry` under the session's id, and
  again under the thread id once Codex names it (a session's first turn
  starts under a placeholder id). Also owns `Canopy.Codex.Approvals` (the
  remembered Always rules) and the `:canopy_codex_cache` ETS table that
  `Canopy.Codex.Models` and the version check cache into.
  """

  use Supervisor

  alias Canopy.Codex.Turn

  @registry Canopy.Codex.TurnRegistry
  @dynamic Canopy.Codex.TurnSupervisor
  @cache :canopy_codex_cache

  # A turn reports completion before its process has finished exiting, so the
  # next turn for the session can arrive while the last one is still
  # registered. It waits this long for that process to go.
  @handoff_wait_ms 5_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if :ets.whereis(@cache) == :undefined,
      do: :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])

    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic, strategy: :one_for_one},
      Canopy.Codex.Approvals
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The cache table (`Canopy.Codex.Models`, the binary's version)."
  def cache, do: @cache

  @doc """
  Starts a turn for the session. While the session's previous turn process is
  still alive (finishing after its result), waits up to `wait_ms` for it to
  exit; `{:error, :busy}` if it is still running then.
  """
  def start_turn(session_id, opts, wait_ms \\ @handoff_wait_ms) do
    spec = {Turn, [name: via(session_id), session_id: session_id] ++ opts}
    start_child(spec, System.monotonic_time(:millisecond) + wait_ms)
  end

  defp start_child(spec, deadline) do
    case DynamicSupervisor.start_child(@dynamic, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        if await_exit(pid, deadline - System.monotonic_time(:millisecond)),
          do: start_child(spec, deadline),
          else: {:error, :busy}

      other ->
        other
    end
  end

  defp await_exit(_pid, remaining) when remaining <= 0, do: false

  defp await_exit(pid, remaining) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :noproc} ->
        Process.sleep(min(remaining, 5))
        true

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        true
    after
      remaining ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  @doc "Terminates every turn left (a reset's last sweep); each kills its `codex` process."
  def stop_all_turns do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@dynamic), is_pid(pid) do
      DynamicSupervisor.terminate_child(@dynamic, pid)
    end

    :ok
  end

  @doc "The turn running for a session, under its placeholder or its thread id."
  def whereis(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Engine session ids with a turn in flight (a renamed turn is listed under both ids)."
  def running, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @doc "Every turn process with the ids it is registered under."
  def turns do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}
end
