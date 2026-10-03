defmodule Canopy.Messages do
  @moduledoc """
  Durable channel messages. Every insert also writes a `message` timeline event
  in the same transaction and broadcasts it after commit.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents
  alias Canopy.Documents
  alias Canopy.Messages.{Attachment, CodeMask, Message}
  alias Canopy.Repo
  alias Canopy.Teams
  alias Canopy.Threads
  alias Canopy.Timeline
  alias Ecto.Multi

  @default_limit 20
  @max_limit 200
  @preloads [:agent, :user, :documents, reactions: [:agent, :user]]
  @max_attachments 10
  @mention_regex ~r/(?<![\w@])@([a-z0-9][a-z0-9_-]*)/i

  @doc false
  # The composer highlight (assets/js/composer_tokens.js) mirrors this; the
  # parity test reads it from here.
  def mention_regex, do: @mention_regex

  @doc "The most documents one message may carry."
  def max_attachments, do: @max_attachments

  @doc """
  Posts a message from the local user. Options shared by every poster:

    * `:attachments` — document ids to attach, in order (max #{@max_attachments});
      with attachments the body may be blank
    * `:mentions` — override the mentions extracted from the body (with
      `:team_mentions`, default none)
    * `:id` — the message's id, chosen ahead (a turn names its reply on its
      summary before posting it)
    * `:interrupt` — a user's post or thread reply only: whether an agent it
      mentions that is working reads it after its current step rather than
      after its turn (default `Canopy.Settings.interrupt_on_mention?/0`, so a
      programmatic post such as a late answer follows the setting); agents'
      messages never interrupt
  """
  def post_user_message(channel_id, user_id, body, opts \\ []) do
    insert(%{channel_id: channel_id, user_id: user_id, body: body, kind: "post"}, opts)
  end

  @doc "Posts a message an agent sent deliberately through `message_send`."
  def post_agent_message(channel_id, agent_id, body, opts \\ []) do
    insert(%{channel_id: channel_id, agent_id: agent_id, body: body, kind: "post"}, opts)
  end

  @doc """
  Stores a note left by a user command such as `/handoff` (`kind: "system"`).
  It carries no mentions and the runtime never wakes anyone for it.
  """
  def post_user_note(channel_id, user_id, body) do
    insert(%{channel_id: channel_id, user_id: user_id, body: body, kind: "system"}, mentions: [])
  end

  @doc """
  Adds a system note from the local user (`kind: "system"`, no mentions) to
  a multi, for something Canopy records as part of a larger commit (a GitHub
  watch's delivery). It wakes nobody, and agents read it like any message.
  The message is `{name, :message}` and its timeline row `{name, :event}`;
  broadcast the event with `Canopy.Timeline.broadcast/1` after the commit.
  """
  def system_note_multi(%Multi{} = multi, name, channel_id, body) do
    attrs = %{
      channel_id: channel_id,
      user_id: Canopy.Users.local().id,
      body: body,
      kind: "system",
      mentions: [],
      team_mentions: [],
      mentions_user: false
    }

    multi
    |> Multi.insert({name, :message}, Message.changeset(%Message{}, attrs))
    |> Timeline.multi_record({name, :event}, fn changes ->
      message = Map.fetch!(changes, {name, :message})

      %{
        channel_id: message.channel_id,
        event_type: "message",
        ref_id: message.id,
        payload: %{
          "kind" => message.kind,
          "thread_id" => nil,
          "sent_to_channel" => false,
          "user_id" => message.user_id,
          "mentions" => [],
          "attachments" => []
        }
      }
    end)
  end

  @doc "Stores the assistant's final text reply to a wake prompt (`kind: \"reply\"`)."
  def post_agent_reply(channel_id, agent_id, body, opts \\ []) do
    insert(%{channel_id: channel_id, agent_id: agent_id, body: body, kind: "reply"}, opts)
  end

  @doc """
  Replies in the thread rooted at `parent_id` (the parent's own thread root is
  used when the parent is itself a reply). `sender` is `{:agent, id}` or
  `{:user, id}`. Besides the shared options:

    * `:to_channel` — also show the reply in the channel feed
      ("also send to channel"); otherwise only the thread shows it
    * `:kind` — `"thread_reply"` (default), or `"reply"` for a turn's final
      text that Canopy posts into the thread the turn was working in
  """
  def thread_reply(parent_id, sender, body, opts \\ []) do
    parent = get!(parent_id)
    root_id = parent.thread_id || parent.id

    attrs = %{
      channel_id: parent.channel_id,
      thread_id: root_id,
      body: body,
      kind: Keyword.get(opts, :kind, "thread_reply"),
      sent_to_channel: Keyword.get(opts, :to_channel, false) == true
    }

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
    * `:thread` — any message id in a thread; returns the root and the latest
      `limit` replies (see `list_thread/2`), or nothing when the thread is
      in another channel
  """
  def list(channel_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    base = from(m in Message, where: m.channel_id == ^channel_id, preload: ^@preloads)

    cond do
      thread_id = Keyword.get(opts, :thread) ->
        case list_thread(thread_id, limit: limit) do
          [%{channel_id: ^channel_id} | _] = messages -> messages
          _ -> []
        end

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

      after_id = Keyword.get(opts, :after) ->
        base
        |> where([m], m.id > ^after_id)
        |> order_by([m], asc: m.id)
        |> limit(^limit)
        |> Repo.all()

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
  The root of the thread `id` belongs to: the message itself when it is a
  top-level message, its root when it is a reply. Nil for an unknown id.
  """
  def thread_root(id) when is_binary(id) do
    case get(id) do
      %Message{thread_id: nil} = root -> root
      %Message{thread_id: root_id} -> get(root_id)
      nil -> nil
    end
  end

  def thread_root(_id), do: nil

  @doc """
  A thread, from any message id in it: the root followed by its **latest**
  `limit` replies (default #{@default_limit}, max #{@max_limit}), oldest first.
  `[]` for an unknown id.
  """
  def list_thread(id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    case thread_root(id) do
      nil ->
        []

      root ->
        replies =
          from(m in Message,
            where: m.thread_id == ^root.id,
            order_by: [desc: m.id],
            limit: ^limit,
            preload: ^@preloads
          )
          |> Repo.all()
          |> Enum.reverse()

        [root | replies]
    end
  end

  @max_participants 4

  @doc """
  What a thread's summary row shows, for the given roots (the ones on a loaded
  page): `%{root_id => %{count, last_reply_at, participants, last}}`, only for
  roots with replies. `participants` are the distinct senders, newest first,
  then the root's own sender, at most #{@max_participants}; each is
  `%{agent_id, user_id, agent}` (`agent` preloaded, nil for the user). `last`
  is the newest reply. Computed on demand: three grouped queries over the
  indexed `thread_id`.
  """
  def thread_summaries([]), do: %{}

  def thread_summaries(root_ids) when is_list(root_ids) do
    root_ids = Enum.uniq(root_ids)

    counts =
      from(m in Message,
        where: m.thread_id in ^root_ids,
        group_by: m.thread_id,
        select: {m.thread_id, count(m.id), max(m.id)}
      )
      |> Repo.all()

    case counts do
      [] ->
        %{}

      counts ->
        last =
          from(m in Message, where: m.id in ^Enum.map(counts, &elem(&1, 2)), preload: ^@preloads)
          |> Repo.all()
          |> Map.new(&{&1.thread_id, &1})

        participants = participants(Enum.map(counts, &elem(&1, 0)))

        Map.new(counts, fn {root_id, count, _last_id} ->
          reply = Map.fetch!(last, root_id)

          {root_id,
           %{
             count: count,
             last_reply_at: reply.inserted_at,
             participants: Map.get(participants, root_id, []),
             last: reply
           }}
        end)
    end
  end

  defp participants(root_ids) do
    repliers =
      from(m in Message,
        where: m.thread_id in ^root_ids,
        group_by: [m.thread_id, m.agent_id, m.user_id],
        select: {m.thread_id, m.agent_id, m.user_id, max(m.id)}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0))

    authors =
      from(m in Message, where: m.id in ^root_ids, select: {m.id, m.agent_id, m.user_id})
      |> Repo.all()
      |> Map.new(fn {id, agent_id, user_id} -> {id, {agent_id, user_id}} end)

    senders =
      Map.new(root_ids, fn root_id ->
        newest_first =
          repliers
          |> Map.get(root_id, [])
          |> Enum.sort_by(&elem(&1, 3), :desc)
          |> Enum.map(fn {_, agent_id, user_id, _} -> {agent_id, user_id} end)

        list =
          (newest_first ++ List.wrap(Map.get(authors, root_id)))
          |> Enum.uniq()
          |> Enum.take(@max_participants)

        {root_id, list}
      end)

    agents =
      senders
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(fn {agent_id, _} -> List.wrap(agent_id) end)
      |> Enum.uniq()
      |> then(&Repo.all(from a in Canopy.Agents.Agent, where: a.id in ^&1))
      |> Map.new(&{&1.id, &1})

    Map.new(senders, fn {root_id, list} ->
      {root_id,
       Enum.map(list, fn {agent_id, user_id} ->
         %{agent_id: agent_id, user_id: user_id, agent: agent_id && Map.get(agents, agent_id)}
       end)}
    end)
  end

  @doc """
  The agent that replied last in the thread rooted at `root_id`, or nil.
  Options narrow what counts:

    * `:except` — an agent id to leave out (the sender)
    * `:before` — a message id: only replies older than it count, so a reply
      routed late is not answered by an agent that replied after it
    * `:among` — agent ids that may count (the channel's members)
  """
  def thread_last_agent(root_id, opts \\ []) when is_binary(root_id) do
    query =
      from(m in Message,
        where: m.thread_id == ^root_id and not is_nil(m.agent_id),
        order_by: [desc: m.id],
        limit: 1,
        select: m.agent_id
      )

    query =
      case Keyword.get(opts, :except) do
        nil -> query
        except -> where(query, [m], m.agent_id != ^except)
      end

    query =
      case Keyword.get(opts, :before) do
        nil -> query
        before -> where(query, [m], m.id < ^before)
      end

    query =
      case Keyword.get(opts, :among) do
        nil -> query
        ids -> where(query, [m], m.agent_id in ^ids)
      end

    Repo.one(query)
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
  appearance. A team name expands in place to its active members, by name;
  the result has no duplicates. Unknown names are ignored, and so are names
  inside inline code or a fenced code block (see `Canopy.Messages.CodeMask`).
  """
  def extract_mentions(body), do: body |> resolve_mentions() |> elem(0)

  @doc "The teams named in `body`, as stored in `messages.team_mentions`."
  def team_mentions(body), do: body |> resolve_mentions() |> elem(1)

  @doc """
  Resolves the `@name`s in `body` to `{agent_ids, team_mentions}`. Each name is
  an agent first (an agent wins a name collision), then a team. A team entry
  is `%{"team_id", "name", "agent_ids"}`, where `agent_ids` are the members
  only that mention woke: not named directly anywhere in the body, nor
  claimed by an earlier team. The channel server charges each team one turn
  of the chatter budget for those wakes.
  """
  def resolve_mentions(body) when is_binary(body) do
    names =
      @mention_regex
      |> Regex.scan(CodeMask.mask(body))
      |> Enum.map(fn [_, name] -> String.downcase(name) end)
      |> Enum.uniq()

    case names do
      [] -> {[], []}
      names -> expand(names)
    end
  end

  def resolve_mentions(_), do: {[], []}

  defp expand(names) do
    agents = Agents.ids_by_names(names)
    teams = names |> Enum.reject(&Map.has_key?(agents, &1)) |> Teams.expand_names()

    ids =
      names
      |> Enum.flat_map(fn name ->
        case {Map.get(agents, name), Map.get(teams, name)} do
          {id, _} when is_binary(id) -> [id]
          {nil, %{agent_ids: ids}} -> ids
          _ -> []
        end
      end)
      |> Enum.uniq()

    {team_mentions, _claimed} =
      names
      |> Enum.filter(&Map.has_key?(teams, &1))
      |> Enum.map_reduce(MapSet.new(Map.values(agents)), fn name, claimed ->
        %{team_id: team_id, agent_ids: members} = Map.fetch!(teams, name)
        own = Enum.reject(members, &MapSet.member?(claimed, &1))

        {%{"team_id" => team_id, "name" => name, "agent_ids" => own},
         MapSet.union(claimed, MapSet.new(own))}
      end)

    {ids, team_mentions}
  end

  defp insert(attrs, opts) do
    {mentions, team_mentions} =
      case Keyword.fetch(opts, :mentions) do
        {:ok, mentions} when is_list(mentions) ->
          {mentions, Keyword.get(opts, :team_mentions, [])}

        _ ->
          resolve_mentions(attrs.body)
      end

    attrs =
      attrs
      |> Map.put(:mentions, mentions)
      |> Map.put(:team_mentions, team_mentions)
      |> Map.put(:opencode_message_id, Keyword.get(opts, :opencode_message_id))
      |> Map.put(:mentions_user, Canopy.Unread.mentions?(attrs.body, Canopy.Users.local()))
      |> Map.put(:interrupt, interrupt?(attrs, opts))

    with {:ok, document_ids} <- check_attachments(Keyword.get(opts, :attachments, [])) do
      Multi.new()
      |> Multi.insert(
        :message,
        Message.changeset(%Message{id: Keyword.get(opts, :id)}, attrs,
          attachments: document_ids != []
        )
      )
      |> Multi.run(:attachments, fn repo, %{message: message} ->
        document_ids
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {document_id, position}, {:ok, acc} ->
          case repo.insert(
                 Attachment.changeset(%Attachment{}, %{
                   message_id: message.id,
                   document_id: document_id,
                   position: position
                 })
               ) do
            {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)
      end)
      # a thread reply stays out of the channel feed unless also sent there
      |> Timeline.multi_record(:event, fn %{message: message} ->
        %{
          channel_id: message.channel_id,
          agent_id: message.agent_id,
          event_type: "message",
          ref_id: message.id,
          thread_id: message.thread_id,
          in_channel: is_nil(message.thread_id) or message.sent_to_channel,
          payload: %{
            "kind" => message.kind,
            "thread_id" => message.thread_id,
            "sent_to_channel" => message.sent_to_channel,
            "user_id" => message.user_id,
            "mentions" => message.mentions,
            "attachments" => document_ids,
            "interrupt" => message.interrupt
          }
        }
      end)
      # before the broadcast, so a view that hears of the reply sees the follow
      |> Multi.run(:follow, fn repo, %{message: message} ->
        {:ok, Threads.auto_follow(repo, message)}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{message: message, event: event, follow: follow}} ->
          Timeline.broadcast(event)
          if message.thread_id, do: Threads.broadcast_reply(message)
          if follow == :followed, do: Threads.broadcast_reads(message.thread_id)
          {:ok, Repo.preload(message, @preloads)}

        {:error, _step, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  # Only the user's own posts and thread replies may interrupt a working agent.
  defp interrupt?(%{user_id: user_id, kind: kind}, opts)
       when is_binary(user_id) and kind in ["post", "thread_reply"],
       do: Keyword.get_lazy(opts, :interrupt, &Canopy.Settings.interrupt_on_mention?/0) == true

  defp interrupt?(_attrs, _opts), do: false

  # Attachments are document ids that must exist; duplicates collapse and
  # order is kept. Errors are strings so tools and the UI can show them as is.
  defp check_attachments([]), do: {:ok, []}

  defp check_attachments(ids) when is_list(ids) do
    ids = Enum.uniq(ids)

    cond do
      length(ids) > @max_attachments ->
        {:error, "at most #{@max_attachments} attachments per message"}

      true ->
        case Enum.find(ids, &is_nil(Documents.get(&1))) do
          nil -> {:ok, ids}
          missing -> {:error, "unknown document #{missing}"}
        end
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

  # -- Read markers (agents) ----------------------------------------------------

  @doc "The newest message id an agent has read in a channel, or nil."
  def last_read(agent_id, channel_id) do
    case Repo.get_by(Canopy.Messages.MessageRead, agent_id: agent_id, channel_id: channel_id) do
      %{last_message_id: id} -> id
      nil -> nil
    end
  end

  @doc "Records the newest message an agent has read in a channel (never moves backwards)."
  def mark_read(agent_id, channel_id, message_id) when is_binary(message_id) do
    current = last_read(agent_id, channel_id)

    if is_nil(current) or message_id > current do
      Repo.insert!(
        %Canopy.Messages.MessageRead{
          agent_id: agent_id,
          channel_id: channel_id,
          last_message_id: message_id,
          updated_at: DateTime.utc_now()
        },
        on_conflict: [set: [last_message_id: message_id, updated_at: DateTime.utc_now()]],
        conflict_target: [:agent_id, :channel_id]
      )
    end

    :ok
  end

  def mark_read(_agent_id, _channel_id, _), do: :ok

  @doc "The newest reaction an agent has seen in a channel through `messages_read`, or nil."
  def last_reaction_read(agent_id, channel_id) do
    case Repo.get_by(Canopy.Messages.MessageRead, agent_id: agent_id, channel_id: channel_id) do
      %{last_reaction_id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Records the newest reaction an agent has seen in a channel (never moves
  backwards). It rides on the agent's message read marker, so it is a no-op
  until the agent has read the channel once.
  """
  def mark_reactions_read(agent_id, channel_id, reaction_id) when is_binary(reaction_id) do
    from(r in Canopy.Messages.MessageRead,
      where: r.agent_id == ^agent_id and r.channel_id == ^channel_id,
      where: is_nil(r.last_reaction_id) or r.last_reaction_id < ^reaction_id
    )
    |> Repo.update_all(set: [last_reaction_id: reaction_id, updated_at: DateTime.utc_now()])

    :ok
  end

  def mark_reactions_read(_agent_id, _channel_id, _), do: :ok
end
