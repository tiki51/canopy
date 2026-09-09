defmodule Canopy.OpenCode.Supervisor do
  @moduledoc """
  Owns the per-repository SSE event streams.

  `start_stream/2` is idempotent: one `Canopy.OpenCode.EventStream` per repository id,
  registered in `Canopy.OpenCode.StreamRegistry`.
  """

  use Supervisor

  alias Canopy.OpenCode.EventStream

  @registry Canopy.OpenCode.StreamRegistry
  @dynamic Canopy.OpenCode.StreamSupervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Starts (or returns) the event stream for a repository."
  def start_stream(repository_id, directory, opts \\ []) do
    spec =
      {EventStream,
       [repository_id: repository_id, directory: directory, name: via(repository_id)] ++ opts}

    case DynamicSupervisor.start_child(@dynamic, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def stop_stream(repository_id) do
    case stream_pid(repository_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@dynamic, pid)
    end
  end

  def stream_pid(repository_id) do
    case Registry.lookup(@registry, repository_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def subscribe_repository(repository_id),
    do: Phoenix.PubSub.subscribe(Canopy.PubSub, EventStream.repository_topic(repository_id))

  def subscribe_session(session_id),
    do: Phoenix.PubSub.subscribe(Canopy.PubSub, EventStream.session_topic(session_id))

  defp via(repository_id), do: {:via, Registry, {@registry, repository_id}}
end
