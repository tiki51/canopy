defmodule Canopy.OpenCode.EventStream do
  @moduledoc """
  One long-lived SSE subscription to `GET /event?directory=<repo>` per repository.

  Raw events are normalized with `Canopy.OpenCode.Events` and broadcast on
  `Phoenix.PubSub` as `{:opencode_event, %Canopy.OpenCode.Event{}}` on two topics:

    * `"opencode:repository:<repository_id>"` — every event for the repository
    * `"opencode:session:<session_id>"`       — events that carry a session id

  Reconnects with exponential backoff (1 s to 30 s) when the connection drops or when
  no bytes (including OpenCode's ~10 s heartbeats) arrive within the watchdog window.
  Text deltas are only forwarded for parts already seen as `text`; reasoning deltas are
  dropped here so the UI never streams chain-of-thought.
  """

  use GenServer
  require Logger

  alias Canopy.OpenCode.{Client, Events, SSE}

  @watchdog_ms 45_000
  @max_backoff_ms 30_000

  defstruct [
    :repository_id,
    :directory,
    :base_url,
    :pubsub,
    :resp,
    :watchdog,
    buffer: "",
    part_types: %{},
    backoff_ms: 1_000,
    connected?: false
  ]

  # -- API --------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def repository_topic(repository_id), do: "opencode:repository:#{repository_id}"
  def session_topic(session_id), do: "opencode:session:#{session_id}"

  @doc "True once the SSE connection is open."
  def connected?(server), do: GenServer.call(server, :connected?)

  # -- Callbacks --------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      repository_id: Keyword.fetch!(opts, :repository_id),
      directory: Keyword.fetch!(opts, :directory),
      base_url: Keyword.get(opts, :base_url),
      pubsub: Keyword.get(opts, :pubsub, Canopy.PubSub)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    req = Client.new(base_url: state.base_url, receive_timeout: :infinity)

    case Req.get(req, url: "/event", params: [directory: state.directory], into: :self) do
      {:ok, %Req.Response{status: 200} = resp} ->
        Logger.info("opencode event stream connected repository=#{state.repository_id}")

        {:noreply,
         %{state | resp: resp, buffer: "", connected?: true, backoff_ms: 1_000} |> arm_watchdog()}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning(
          "opencode event stream refused status=#{status} repository=#{state.repository_id}"
        )

        {:noreply, schedule_reconnect(state)}

      {:error, reason} ->
        Logger.warning(
          "opencode event stream failed reason=#{inspect(reason)} repository=#{state.repository_id}"
        )

        {:noreply, schedule_reconnect(state)}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.connected?, state}

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info(:watchdog, state) do
    Logger.warning(
      "opencode event stream silent for #{@watchdog_ms}ms, reconnecting repository=#{state.repository_id}"
    )

    {:noreply, state |> drop_connection() |> schedule_reconnect()}
  end

  def handle_info(message, %{resp: %Req.Response{} = resp} = state) do
    case Req.parse_message(resp, message) do
      {:ok, chunks} -> {:noreply, Enum.reduce(chunks, state, &handle_chunk/2)}
      {:error, reason} -> {:noreply, handle_closed(state, reason)}
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Internals --------------------------------------------------------------

  defp handle_chunk({:data, data}, state) do
    {events, rest} = SSE.feed(state.buffer, data)
    state = %{state | buffer: rest} |> arm_watchdog()
    Enum.reduce(events, state, &handle_sse_event/2)
  end

  defp handle_chunk(:done, state), do: handle_closed(state, :done)
  defp handle_chunk({:trailers, _}, state), do: state

  defp handle_sse_event(%{data: ""}, state), do: state

  defp handle_sse_event(%{data: data}, state) do
    case Jason.decode(data) do
      {:ok, raw} ->
        raw
        |> Events.normalize()
        |> Enum.reduce(state, &publish/2)

      {:error, _} ->
        Logger.debug(
          "opencode event stream: undecodable payload #{inspect(String.slice(data, 0, 120))}"
        )

        state
    end
  end

  # Remember part types so deltas can be attributed; drop reasoning deltas.
  defp publish(%{type: :part_delta} = event, state) do
    key = {event.session_id, event.data.part_id}

    case Map.get(state.part_types, key) do
      "text" ->
        broadcast(%{event | type: :text_delta, data: Map.delete(event.data, :field)}, state)

      _ ->
        state
    end
  end

  defp publish(event, state) do
    state = remember_part_type(event, state)
    broadcast(event, state)
  end

  defp remember_part_type(
         %{raw_type: "message.part.updated", session_id: sid, data: %{part_id: pid}} = ev,
         state
       )
       when is_binary(pid) do
    type =
      case ev.type do
        :text_done -> "text"
        :tool_started -> "tool"
        :tool_completed -> "tool"
        _ -> nil
      end

    if type, do: %{state | part_types: Map.put(state.part_types, {sid, pid}, type)}, else: state
  end

  defp remember_part_type(_event, state), do: state

  defp broadcast(event, state) do
    message = {:opencode_event, event}
    Phoenix.PubSub.broadcast(state.pubsub, repository_topic(state.repository_id), message)

    if event.session_id do
      Phoenix.PubSub.broadcast(state.pubsub, session_topic(event.session_id), message)
    end

    state
  end

  defp handle_closed(state, reason) do
    Logger.info(
      "opencode event stream closed reason=#{inspect(reason)} repository=#{state.repository_id}"
    )

    state |> drop_connection() |> schedule_reconnect()
  end

  defp drop_connection(%{resp: nil} = state), do: %{state | connected?: false}

  defp drop_connection(%{resp: resp} = state) do
    _ = Req.cancel_async_response(resp)
    %{state | resp: nil, buffer: "", connected?: false}
  end

  defp schedule_reconnect(state) do
    state = cancel_watchdog(state)
    Process.send_after(self(), :reconnect, state.backoff_ms)
    %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}
  end

  defp arm_watchdog(state) do
    state = cancel_watchdog(state)
    %{state | watchdog: Process.send_after(self(), :watchdog, @watchdog_ms)}
  end

  defp cancel_watchdog(%{watchdog: nil} = state), do: state

  defp cancel_watchdog(%{watchdog: ref} = state) do
    Process.cancel_timer(ref)
    %{state | watchdog: nil}
  end
end
