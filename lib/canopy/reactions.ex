defmodule Canopy.Reactions do
  @moduledoc """
  Emoji reactions on messages: quiet signals that never wake anyone.

  A reaction is row state on a message, not something that happened in the
  channel, so it writes no timeline event. That is the "never wakes"
  guarantee, and it is structural: nothing routes a reaction, the channel
  server ignores the `{:reactions, _}` broadcast, a chatter pause stays put,
  and unread counts (which count messages) never see one. Agents read
  reactions through `canopy_messages_read`, inline on each message and as a
  "since your last read" trailer.

  A `reactor` is `{:user, user_id}` or `{:agent, agent_id}`, always set by the
  caller's code, never from a form or a tool's params.

  The palette is small and fixed: agents get a closed vocabulary, keys avoid
  glyph normalisation (❤ vs ❤️), and there is no negative reaction on purpose
  (disagreement should be a message, which does wake).
  """

  import Ecto.Query, warn: false

  alias Canopy.Channels.Channel
  alias Canopy.Messages.{Message, Reaction}
  alias Canopy.Repo
  alias Canopy.Timeline

  @palette [
    %{key: "thumbs_up", glyph: "👍", label: "agree / sounds good"},
    %{key: "check", glyph: "✅", label: "done / approved"},
    %{key: "eyes", glyph: "👀", label: "looking at it"},
    %{key: "tada", glyph: "🎉", label: "nice work"},
    %{key: "heart", glyph: "❤️", label: "thanks"}
  ]
  @keys Enum.map(@palette, & &1.key)
  @by_key Map.new(@palette, &{&1.key, &1})
  @default_since_limit 10

  @type reactor :: {:user, String.t()} | {:agent, String.t()}

  @doc "The palette, in display order: `[%{key, glyph, label}]`."
  def palette, do: @palette

  @doc "The palette keys, in display order."
  def keys, do: @keys

  @doc "The palette entry for `key`, or nil."
  def entry(key), do: Map.get(@by_key, key)

  @doc """
  The palette key for a key or a glyph (with or without the emoji variation
  selector), or nil.
  """
  def resolve_key(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim(":")
    bare = String.replace(value, "️", "")

    cond do
      Map.has_key?(@by_key, value) -> value
      entry = Enum.find(@palette, &(String.replace(&1.glyph, "️", "") == bare)) -> entry.key
      true -> nil
    end
  end

  def resolve_key(_value), do: nil

  @doc """
  Adds the reactor's reaction if absent, removes it if present (the UI's
  click). `{:ok, :added | :removed}`, or an error (see `add/3`).
  """
  def toggle(message_id, reactor, key) do
    with {:ok, message} <- reactable(message_id, key) do
      if find(message.id, reactor, key),
        do: remove_from(message, reactor, key),
        else: add_to(message, reactor, key)
    end
  end

  @doc """
  Adds a reaction; idempotent. `{:ok, :added | :exists}`, or
  `{:error, :not_found | :unknown_emoji | :system_message | :archived}`.
  Broadcasts only when something changed.
  """
  def add(message_id, reactor, key) do
    with {:ok, message} <- reactable(message_id, key), do: add_to(message, reactor, key)
  end

  @doc "Removes a reaction; idempotent. `{:ok, :removed | :absent}`, or an error as `add/3`."
  def remove(message_id, reactor, key) do
    with {:ok, message} <- reactable(message_id, key), do: remove_from(message, reactor, key)
  end

  # System notes are not conversation, and an archived channel is read-only.
  defp reactable(message_id, key) do
    with {:key, true} <- {:key, key in @keys},
         %Message{} = message <- is_binary(message_id) && Repo.get(Message, message_id),
         {:system, false} <- {:system, message.kind == "system"},
         %Channel{status: status} when status != "archived" <-
           Repo.get(Channel, message.channel_id) do
      {:ok, message}
    else
      {:key, false} -> {:error, :unknown_emoji}
      {:system, true} -> {:error, :system_message}
      %Channel{} -> {:error, :archived}
      _ -> {:error, :not_found}
    end
  end

  defp add_to(message, reactor, key) do
    attrs =
      reactor
      |> reactor_attrs()
      |> Map.merge(%{message_id: message.id, channel_id: message.channel_id, emoji: key})

    case Repo.insert(Reaction.changeset(%Reaction{}, attrs)) do
      {:ok, _reaction} ->
        broadcast(message)
        {:ok, :added}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # a concurrent add of the same reaction landed first
        if Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end),
          do: {:ok, :exists},
          else: {:error, changeset}
    end
  end

  defp remove_from(message, reactor, key) do
    {count, _} =
      reactor
      |> reactor_query(message.id, key)
      |> Repo.delete_all()

    if count > 0 do
      broadcast(message)
      {:ok, :removed}
    else
      {:ok, :absent}
    end
  end

  defp find(message_id, reactor, key), do: Repo.one(reactor_query(reactor, message_id, key))

  defp reactor_query({:user, user_id}, message_id, key),
    do:
      from(r in Reaction,
        where: r.message_id == ^message_id and r.emoji == ^key and r.user_id == ^user_id
      )

  defp reactor_query({:agent, agent_id}, message_id, key),
    do:
      from(r in Reaction,
        where: r.message_id == ^message_id and r.emoji == ^key and r.agent_id == ^agent_id
      )

  defp reactor_attrs({:user, user_id}) when is_binary(user_id), do: %{user_id: user_id}
  defp reactor_attrs({:agent, agent_id}) when is_binary(agent_id), do: %{agent_id: agent_id}

  # On the channel topic only: the open channel's views redraw the message;
  # the channel server's catch-all ignores it, and the cross-channel
  # "timeline:all" topic (unread marks) never hears of it.
  defp broadcast(%Message{} = message) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      Timeline.topic(message.channel_id),
      {:reactions,
       %{channel_id: message.channel_id, message_id: message.id, thread_id: message.thread_id}}
    )
  end

  @doc """
  A message's reactions grouped by emoji, in palette order:
  `[%{key, glyph, label, count, user?, agent_ids, reactions}]`. `user?` is
  true when the user is among the reactors; `reactions` keeps the rows (with
  whatever reactors were preloaded) in the order they were added.
  """
  def group(reactions) when is_list(reactions) do
    by_key = Enum.group_by(reactions, & &1.emoji)

    Enum.flat_map(@palette, fn %{key: key} = entry ->
      case Map.get(by_key, key) do
        nil ->
          []

        rows ->
          rows = Enum.sort_by(rows, & &1.id)

          [
            Map.merge(entry, %{
              count: length(rows),
              user?: Enum.any?(rows, &is_binary(&1.user_id)),
              agent_ids: for(%{agent_id: id} when is_binary(id) <- rows, do: id),
              reactions: rows
            })
          ]
      end
    end)
  end

  def group(_not_loaded), do: []

  @doc """
  The channel's reactions newer than the cursor `after_id` (all of them for
  nil), oldest first, with the message (and its sender) and the reactor
  preloaded. Options:

    * `:exclude_agent` — leave out this agent's own reactions (the reader's)
    * `:except_messages` — leave out reactions on these message ids (ones the
      reader is already shown)
    * `:limit` — keep only the newest this many (default #{@default_since_limit})
  """
  def since(channel_id, after_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_since_limit)

    Reaction
    |> where([r], r.channel_id == ^channel_id)
    |> then(&if(after_id, do: where(&1, [r], r.id > ^after_id), else: &1))
    |> then(fn query ->
      case Keyword.get(opts, :exclude_agent) do
        nil -> query
        agent_id -> where(query, [r], is_nil(r.agent_id) or r.agent_id != ^agent_id)
      end
    end)
    |> then(fn query ->
      case Keyword.get(opts, :except_messages, []) do
        [] -> query
        ids -> where(query, [r], r.message_id not in ^ids)
      end
    end)
    |> order_by([r], desc: r.id)
    |> limit(^limit)
    |> preload([:agent, :user, message: [:agent, :user]])
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "The newest reaction id in the channel, or nil: the cursor to store after a read."
  def newest_id(channel_id) do
    Repo.one(from r in Reaction, where: r.channel_id == ^channel_id, select: max(r.id))
  end
end
