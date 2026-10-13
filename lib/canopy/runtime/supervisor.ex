defmodule Canopy.Runtime.Supervisor do
  @moduledoc "Registry plus dynamic supervisor for `Canopy.Runtime.ChannelServer` processes."

  use Supervisor

  alias Canopy.Runtime.ChannelServer

  @registry Canopy.Runtime.ChannelRegistry
  @dynamic Canopy.Runtime.ChannelSupervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts (or returns) the channel server for a channel id. While Canopy
  resets (`Canopy.Environment.resetting?/0`) it starts nothing and returns
  `{:error, :resetting}`.
  """
  def ensure_channel(channel_id, opts \\ []) do
    if Canopy.Environment.resetting?() do
      {:error, :resetting}
    else
      spec = {ChannelServer, [channel_id: channel_id, name: via(channel_id)] ++ opts}

      case DynamicSupervisor.start_child(@dynamic, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    end
  end

  def stop_channel(channel_id) do
    case whereis(channel_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@dynamic, pid)
    end
  end

  @doc """
  Stops every channel server for a reset: each aborts its turns through the
  engine first (`ChannelServer.shutdown/1`), without the notes and state of
  the user's Stop.
  """
  def stop_all_channels do
    for channel_id <- running_channel_ids() do
      if pid = whereis(channel_id) do
        try do
          ChannelServer.shutdown(pid)
        catch
          :exit, _ -> :ok
        end
      end

      stop_channel(channel_id)
    end

    :ok
  end

  def whereis(channel_id) do
    case Registry.lookup(@registry, channel_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The ids of the channels whose server is running."
  def running_channel_ids, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  def via(channel_id), do: {:via, Registry, {@registry, channel_id}}
end
