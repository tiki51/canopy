defmodule Canopy.Timeline do
  @moduledoc """
  The channel feed: one table of events, one cursor (the event id).

  `record/1` inserts an event and broadcasts `{:timeline, event}` on the
  channel topic. Other contexts that write several rows in one transaction use
  `multi_record/3` and then `broadcast/1` after the transaction commits, so
  subscribers never see an event that was rolled back.
  """

  import Ecto.Query, warn: false

  alias Canopy.Repo
  alias Canopy.Timeline.Event
  alias Ecto.Multi

  @pubsub Canopy.PubSub
  @default_limit 50
  @preloads [:agent, message: [:agent, :user, :documents, :thread, reactions: [:agent, :user]]]

  @doc "PubSub topic for a channel."
  def topic(channel_id) when is_binary(channel_id), do: "channel:#{channel_id}"

  @doc "Subscribes the calling process to a channel's topic."
  def subscribe(channel_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(channel_id))

  @doc "Subscribe to `{:timeline_any, event}` for every channel, for cross-channel UI such as unread marks."
  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, "timeline:all")

  @doc "Unsubscribes the calling process from a channel's topic."
  def unsubscribe(channel_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(channel_id))

  @doc """
  Inserts an event and broadcasts it. Returns the event with preloads applied.
  """
  def record(attrs) when is_map(attrs) do
    with {:ok, event} <- Repo.insert(Event.changeset(%Event{}, attrs)) do
      {:ok, broadcast(event)}
    end
  end

  @doc """
  Adds an event insert to a multi. `attrs_or_fun` is either an attrs map or a
  function receiving the multi changes so far and returning the attrs.
  """
  def multi_record(%Multi{} = multi, name, attrs) when is_map(attrs) do
    Multi.insert(multi, name, Event.changeset(%Event{}, attrs))
  end

  def multi_record(%Multi{} = multi, name, fun) when is_function(fun, 1) do
    Multi.insert(multi, name, fn changes -> Event.changeset(%Event{}, fun.(changes)) end)
  end

  @doc """
  Preloads the event's associations and broadcasts `{:timeline, event}` on the
  channel topic. Returns the preloaded event.

  The channel topic also carries `{:reactions, %{channel_id, message_id,
  thread_id}}` from `Canopy.Reactions`: a message's reactions changed. It is
  not an event and is never routed.
  """
  def broadcast(%Event{} = event) do
    event = Repo.preload(event, @preloads)
    :ok = Phoenix.PubSub.broadcast(@pubsub, topic(event.channel_id), {:timeline, event})
    :ok = Phoenix.PubSub.broadcast(@pubsub, "timeline:all", {:timeline_any, event})
    event
  end

  @doc """
  Lists events for a channel in ascending id order, with `message` (plus its
  sender) and `agent` preloaded.

  Options: `:limit` (default #{@default_limit}), `:before` (event id; returns the
  events preceding it), `:types` (list of event types to include), `:scope`
  (`:channel` for the channel feed: everything but what only a thread shows;
  default all events).
  """
  def list(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Event
    |> where([e], e.channel_id == ^channel_id)
    |> maybe_scope(Keyword.get(opts, :scope))
    |> maybe_before(Keyword.get(opts, :before))
    |> maybe_types(Keyword.get(opts, :types))
    |> order_by([e], desc: e.id)
    |> limit(^limit)
    |> preload(^@preloads)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The events after `after_id` in ascending id order: the oldest `:limit`
  (default #{@default_limit}) of them, for paging forward through history.
  Takes `:scope` as `list/2` does.
  """
  def list_after(channel_id, after_id, opts \\ []) when is_binary(after_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Event
    |> where([e], e.channel_id == ^channel_id and e.id > ^after_id)
    |> maybe_scope(Keyword.get(opts, :scope))
    |> order_by([e], asc: e.id)
    |> limit(^limit)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc """
  A window of history around one event, in ascending id order: up to
  `:before` (default 50) events older than `event_id`, the event itself, and
  up to `:after` (default 50) newer ones. Takes `:scope` as `list/2` does.
  """
  def list_around(channel_id, event_id, opts \\ []) when is_binary(event_id) do
    scope = Keyword.get(opts, :scope)

    older =
      list(channel_id, limit: Keyword.get(opts, :before, 50), before: event_id, scope: scope)

    newer =
      Event
      |> where([e], e.channel_id == ^channel_id and e.id >= ^event_id)
      |> maybe_scope(scope)
      |> order_by([e], asc: e.id)
      |> limit(^(Keyword.get(opts, :after, 50) + 1))
      |> preload(^@preloads)
      |> Repo.all()

    older ++ newer
  end

  @doc """
  A thread's events in ascending id order: the root's own `message` event
  first, then the latest `:limit` (default #{@default_limit}) events of the
  thread: its replies and the turn cards of work done for it. `[]` when the
  root has no event.
  """
  def list_thread(root_id, opts \\ []) when is_binary(root_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    case for_message(root_id) do
      nil ->
        []

      root ->
        events =
          Event
          |> where([e], e.thread_id == ^root_id)
          |> order_by([e], desc: e.id)
          |> limit(^limit)
          |> preload(^@preloads)
          |> Repo.all()
          |> Enum.reverse()

        [root | events]
    end
  end

  @doc "Fetches one event with preloads."
  def get!(id), do: Event |> Repo.get!(id) |> Repo.preload(@preloads)

  @doc "Fetches one event with preloads, or nil."
  def get(id) when is_binary(id) do
    case Repo.get(Event, id) do
      nil -> nil
      event -> Repo.preload(event, @preloads)
    end
  end

  @doc "The agent's latest finished turn in the channel (its `agent_turn_completed` event), or nil."
  def last_turn(channel_id, agent_id) do
    Event
    |> where(
      [e],
      e.channel_id == ^channel_id and e.agent_id == ^agent_id and
        e.event_type == "agent_turn_completed"
    )
    |> order_by([e], desc: e.id)
    |> limit(1)
    |> preload(^@preloads)
    |> Repo.one()
  end

  @doc "The `message` event that refers to `message_id`, with preloads, or nil."
  def for_message(message_id) when is_binary(message_id) do
    Event
    |> where([e], e.event_type == "message" and e.ref_id == ^message_id)
    |> preload(^@preloads)
    |> Repo.one()
  end

  defp maybe_scope(query, :channel), do: where(query, [e], e.in_channel == true)
  defp maybe_scope(query, _all), do: query

  defp maybe_before(query, nil), do: query
  defp maybe_before(query, before), do: where(query, [e], e.id < ^before)

  defp maybe_types(query, nil), do: query
  defp maybe_types(query, types), do: where(query, [e], e.event_type in ^types)
end
