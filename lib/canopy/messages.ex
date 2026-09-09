defmodule Canopy.Messages do
  @moduledoc """
  Durable channel messages. Every insert also writes a `message` timeline event
  in the same transaction and broadcasts it after commit.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents
  alias Canopy.Messages.Message
  alias Canopy.Repo
  alias Canopy.Timeline
  alias Ecto.Multi

  @default_limit 20
  @max_limit 200
  @preloads [:agent, :user]
  @mention_regex ~r/(?<![\w@])@([a-z0-9][a-z0-9_-]*)/i

  @doc "Posts a message from the local user."
  def post_user_message(channel_id, user_id, body, opts \\ []) do
    insert(%{channel_id: channel_id, user_id: user_id, body: body, kind: "post"}, opts)
  end

  @doc "Posts a message an agent sent deliberately through `message_send`."
  def post_agent_message(channel_id, agent_id, body, opts \\ []) do
    insert(%{channel_id: channel_id, agent_id: agent_id, body: body, kind: "post"}, opts)
  end

  @doc "Stores the assistant's final text reply to a wake prompt (`kind: \"reply\"`)."
  def post_agent_reply(channel_id, agent_id, body, opts \\ []) do
    insert(%{channel_id: channel_id, agent_id: agent_id, body: body, kind: "reply"}, opts)
  end

  @doc """
  Replies in the thread rooted at `parent_id` (the parent's own thread root is
  used when the parent is itself a reply). `sender` is `{:agent, id}` or
  `{:user, id}`.
  """
  def thread_reply(parent_id, sender, body, opts \\ []) do
    parent = get!(parent_id)
    root_id = parent.thread_id || parent.id

    attrs = %{channel_id: parent.channel_id, thread_id: root_id, body: body, kind: "thread_reply"}

    attrs =
      case sender do
        {:agent, agent_id} -> Map.put(attrs, :agent_id, agent_id)
        {:user, user_id} -> Map.put(attrs, :user_id, user_id)
      end

    insert(attrs, opts)
  end

  def get!(id), do: Message |> Repo.get!(id) |> Repo.preload(@preloads)

  def get(id), do: Message |> Repo.get(id) |> Repo.preload(@preloads)

  @doc """
  Lists channel messages in ascending id order with sender preloaded.

  Options:
    * `:limit` — default #{@default_limit}, max #{@max_limit}
    * `:before` — message id; returns the messages preceding it
    * `:around` — message id; returns messages before and after it (inclusive)
    * `:thread` — root message id; returns the root and its replies
  """
  def list(channel_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    base = from(m in Message, where: m.channel_id == ^channel_id, preload: ^@preloads)

    cond do
      thread_id = Keyword.get(opts, :thread) ->
        base
        |> where([m], m.id == ^thread_id or m.thread_id == ^thread_id)
        |> order_by([m], asc: m.id)
        |> limit(^limit)
        |> Repo.all()

      anchor = Keyword.get(opts, :around) ->
        before_count = div(limit, 2)
        after_count = max(limit - before_count, 1)

        older =
          base
          |> where([m], m.id < ^anchor)
          |> order_by([m], desc: m.id)
          |> limit(^before_count)
          |> Repo.all()
          |> Enum.reverse()

        newer =
          base
          |> where([m], m.id >= ^anchor)
          |> order_by([m], asc: m.id)
          |> limit(^after_count)
          |> Repo.all()

        older ++ newer

      true ->
        base
        |> maybe_before(Keyword.get(opts, :before))
        |> order_by([m], desc: m.id)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.reverse()
    end
  end

  @doc """
  Full-text search over a channel's messages.

  Bare words are matched as whole tokens, `"quoted phrases"` as phrases, and a
  trailing `*` requests a prefix match (`retr*`). Returns
  `[%{message: %Message{}, snippet: String.t(), rank: float}]` ordered by
  relevance. Highlights in the snippet are wrapped in `**`.
  """
  def search(channel_id, query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    case to_fts_query(query) do
      "" ->
        []

      fts_query ->
        Repo.all(
          from m in Message,
            join: f in "messages_fts",
            on: fragment("? = ?", f.rowid, m.rowid),
            where: m.channel_id == ^channel_id,
            where: fragment("? MATCH ?", f.messages_fts, ^fts_query),
            order_by: fragment("bm25(?)", f.messages_fts),
            limit: ^limit,
            select: %{
              message: m,
              snippet: fragment("snippet(?, 0, '**', '**', '...', 16)", f.messages_fts),
              rank: fragment("bm25(?)", f.messages_fts)
            }
        )
        |> Enum.map(fn %{message: message} = hit ->
          %{hit | message: Repo.preload(message, @preloads)}
        end)
    end
  end

  @doc """
  Converts free text into a safe FTS5 query: every term becomes a quoted
  token or phrase, with `*` kept for prefix matches. Returns `""` when the
  text contains no searchable term.
  """
  def to_fts_query(text) when is_binary(text) do
    ~r/"[^"]*"\*?|\S+/
    |> Regex.scan(text)
    |> Enum.map(&List.first/1)
    |> Enum.map(&term_to_fts/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def to_fts_query(_), do: ""

  @doc """
  Returns the ids of agents mentioned as `@name` in `body`, in order of first
  appearance. Unknown names are ignored.
  """
  def extract_mentions(body) when is_binary(body) do
    names =
      @mention_regex
      |> Regex.scan(body)
      |> Enum.map(fn [_, name] -> String.downcase(name) end)
      |> Enum.uniq()

    case names do
      [] ->
        []

      names ->
        ids = Agents.ids_by_names(names)
        names |> Enum.map(&Map.get(ids, &1)) |> Enum.reject(&is_nil/1)
    end
  end

  def extract_mentions(_), do: []

  defp insert(attrs, opts) do
    attrs =
      attrs
      |> Map.put(:mentions, extract_mentions(attrs.body))
      |> Map.put(:opencode_message_id, Keyword.get(opts, :opencode_message_id))

    Multi.new()
    |> Multi.insert(:message, Message.changeset(%Message{}, attrs))
    |> Timeline.multi_record(:event, fn %{message: message} ->
      %{
        channel_id: message.channel_id,
        agent_id: message.agent_id,
        event_type: "message",
        ref_id: message.id,
        payload: %{
          "kind" => message.kind,
          "thread_id" => message.thread_id,
          "user_id" => message.user_id,
          "mentions" => message.mentions
        }
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message, event: event}} ->
        Timeline.broadcast(event)
        {:ok, Repo.preload(message, @preloads)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp term_to_fts(term) do
    {inner, prefix?} =
      case term do
        <<?", _::binary>> ->
          {stripped, prefix?} = strip_prefix_star(term)
          {String.trim(stripped, "\""), prefix?}

        _ ->
          strip_prefix_star(term)
      end

    inner = inner |> String.replace("\"", "") |> String.trim()

    cond do
      not Regex.match?(~r/[[:alnum:]]/u, inner) -> ""
      prefix? -> ~s("#{inner}"*)
      true -> ~s("#{inner}")
    end
  end

  defp strip_prefix_star(term) do
    if String.ends_with?(term, "*") do
      {String.trim_trailing(term, "*"), true}
    else
      {term, false}
    end
  end

  defp maybe_before(query, nil), do: query
  defp maybe_before(query, before), do: where(query, [m], m.id < ^before)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_), do: @default_limit
end
