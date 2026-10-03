defmodule Canopy.ClaudeCode.Supervisor do
  @moduledoc """
  Owns the `Canopy.ClaudeCode.Turn` processes: one per engine session while a
  turn runs, registered by engine session id in `Canopy.ClaudeCode.TurnRegistry`;
  and `Canopy.ClaudeCode.TranscriptIndex`, the line index the transcript page reads through.
  """

  use Supervisor

  alias Canopy.ClaudeCode.Turn

  @registry Canopy.ClaudeCode.TurnRegistry
  @dynamic Canopy.ClaudeCode.TurnSupervisor

  # A turn reports its result before its process has finished exiting, so the
  # next turn for the session can arrive while the last one is still
  # registered. It waits this long for that process to go.
  @handoff_wait_ms 5_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic, strategy: :one_for_one},
      Canopy.ClaudeCode.TranscriptIndex
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

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
      # already gone: the registry has yet to forget it, so give it a moment
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

  def whereis(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Engine session ids with a turn in flight."
  def running, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}
end
