defmodule Canopy.ClaudeCode.Supervisor do
  @moduledoc """
  Owns the `Canopy.ClaudeCode.Turn` processes: one per engine session while a
  turn runs, registered by engine session id in `Canopy.ClaudeCode.TurnRegistry`.
  """

  use Supervisor

  alias Canopy.ClaudeCode.Turn

  @registry Canopy.ClaudeCode.TurnRegistry
  @dynamic Canopy.ClaudeCode.TurnSupervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Starts a turn for the session; `{:error, :busy}` while one is already running."
  def start_turn(session_id, opts) do
    spec = {Turn, [name: via(session_id), session_id: session_id] ++ opts}

    case DynamicSupervisor.start_child(@dynamic, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :busy}
      other -> other
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
