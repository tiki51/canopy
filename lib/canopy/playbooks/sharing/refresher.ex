defmodule Canopy.Playbooks.Sharing.Refresher do
  @moduledoc """
  Holds what playbook sharing last read from GitHub (a snapshot: the account,
  push access, the branch and the prepared files), the folder listing's ETag,
  the blob cache and pending import undos.

  One read runs at a time, as a task under
  `Canopy.Playbooks.Sharing.TaskSupervisor`; callers that arrive during it get
  its result. A read is tagged with the config it started with, and a result
  whose config is no longer `Sharing.config/0` is dropped. While sharing is
  set up it reads every 10 minutes (`tick: false` in test), which is when an
  export's merged or closed pull request is noticed.
  """

  use GenServer

  require Logger

  alias Canopy.Playbooks.Sharing

  @tick_ms :timer.minutes(10)
  @undo_ttl_ms :timer.minutes(15)
  @blobs :playbook_sharing_blobs

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The snapshot for `config`, read now unless the cached one is for the same
  config and at most `max_age` seconds old. Callers wait up to 120 s.
  """
  def snapshot(config, max_age) do
    GenServer.call(__MODULE__, {:snapshot, config, max_age}, 120_000)
  end

  @doc "The cached snapshot, or nil; never reads."
  def cached, do: GenServer.call(__MODULE__, :cached)

  @doc "Forgets the cached snapshot and listing (sharing settings changed)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc """
  Test only: kills a read in flight (its waiters get `:gh_failed`), forgets
  the snapshot, listing, blob cache and undos.
  """
  def reset do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :reset), else: :ok
  end

  @doc "A blob's text from the cache, or nil."
  def cached_blob(sha) do
    case :ets.whereis(@blobs) != :undefined && :ets.lookup(@blobs, sha) do
      [{^sha, text}] -> text
      _ -> nil
    end
  end

  @doc "Caches a blob's text by its sha (blobs never change)."
  def cache_blob(sha, text) do
    if :ets.whereis(@blobs) != :undefined, do: :ets.insert(@blobs, {sha, text})
    :ok
  end

  @doc "Keeps an import's undo for 15 minutes; returns its token."
  def put_undo(data), do: GenServer.call(__MODULE__, {:put_undo, data})

  @doc "An undo by token, or nil when unknown or expired."
  def get_undo(token), do: GenServer.call(__MODULE__, {:get_undo, token})

  @doc "Forgets an undo once used."
  def drop_undo(token), do: GenServer.call(__MODULE__, {:drop_undo, token})

  # -- Server ---------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@blobs, [:set, :public, :named_table, read_concurrency: true])
    if tick?(), do: Process.send_after(self(), :tick, @tick_ms)
    {:ok, initial()}
  end

  defp initial,
    do: %{snapshot: nil, listing: nil, read: nil, undos: %{}}

  defp tick?, do: Application.get_env(:canopy, :playbook_sharing, [])[:tick] != false

  @impl true
  def handle_call({:snapshot, config, max_age}, from, state) do
    cond do
      state.read != nil ->
        {:noreply, update_in(state.read.waiters, &[from | &1])}

      fresh?(state.snapshot, config, max_age) ->
        {:reply, {:ok, state.snapshot}, state}

      true ->
        {:noreply, start_read(state, config, [from])}
    end
  end

  def handle_call(:cached, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:clear, _from, state),
    do: {:reply, :ok, %{state | snapshot: nil, listing: nil}}

  def handle_call(:reset, _from, state) do
    if read = state.read do
      Process.demonitor(read.ref, [:flush])
      Process.exit(read.pid, :kill)
      reply_all(read.waiters, {:error, {:gh_failed, "the read was stopped"}})
    end

    :ets.delete_all_objects(@blobs)
    {:reply, :ok, initial()}
  end

  def handle_call({:put_undo, data}, _from, state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    now = System.monotonic_time(:millisecond)

    undos =
      state.undos
      |> Map.reject(fn {_, {expires, _}} -> expires < now end)
      |> Map.put(token, {now + @undo_ttl_ms, data})

    {:reply, token, %{state | undos: undos}}
  end

  def handle_call({:get_undo, token}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case state.undos[token] do
      {expires, data} when expires >= now -> {:reply, data, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call({:drop_undo, token}, _from, state),
    do: {:reply, :ok, %{state | undos: Map.delete(state.undos, token)}}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)

    state =
      case {state.read, current_config()} do
        {nil, {:ok, config}} -> start_read(state, config, [])
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({ref, result}, %{read: %{ref: ref} = read} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, read, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{read: %{ref: ref} = read} = state) do
    Logger.warning("playbook sharing read crashed: #{inspect(reason)}")
    reply_all(read.waiters, {:error, {:gh_failed, "reading GitHub failed: #{inspect(reason)}"}})
    {:noreply, %{state | read: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fresh?(%{config: config, checked_at: at}, config, max_age) when is_integer(max_age) do
    max_age > 0 and DateTime.diff(DateTime.utc_now(), at, :second) <= max_age
  end

  defp fresh?(_snapshot, _config, _max_age), do: false

  defp start_read(state, config, waiters) do
    listing = if state.listing && state.listing.config == config, do: state.listing

    task =
      Task.Supervisor.async_nolink(Canopy.Playbooks.Sharing.TaskSupervisor, fn ->
        Sharing.read(config, listing)
      end)

    %{state | read: %{ref: task.ref, pid: task.pid, config: config, waiters: waiters}}
  end

  defp finish(state, read, {:ok, snapshot, listing, status}) do
    if current_config() == {:ok, read.config} do
      reply_all(read.waiters, {:ok, snapshot})
      Sharing.broadcast({:playbook_sharing, :status, status})
      %{state | read: nil, snapshot: snapshot, listing: listing}
    else
      reply_all(read.waiters, {:error, {:stale, "sharing settings changed"}})
      %{state | read: nil}
    end
  end

  defp finish(state, read, {:error, _} = error) do
    reply_all(read.waiters, error)
    %{state | read: nil}
  end

  # A failed settings read mustn't crash the Refresher and lose the blob
  # table and undo tokens (in tests: a read that outlives its sandbox owner)
  defp current_config do
    Sharing.config()
  rescue
    error -> {:error, error}
  end

  defp reply_all(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))
end
