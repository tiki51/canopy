defmodule Canopy.Threads do
  @moduledoc """
  The user's side of threads: which ones they follow, what they have read,
  the Threads inbox, and which threads agents are working in right now.

  You follow a thread automatically when you write its root or a reply, when
  a message in it mentions you by display name, or when it is in a DM; the
  bell in the thread panel follows or unfollows by hand, and an unfollow is
  never undone by anything but your own reply. Unread counts per thread live
  in `Canopy.Unread.thread_summary/1`.

  Thread replies themselves are messages (`Canopy.Messages.thread_reply/4`);
  their reply counts and participants are computed per page by
  `Canopy.Messages.thread_summaries/1`.
  """

  import Ecto.Query

  alias Canopy.{Messages, Repo, Unread, Users}
  alias Canopy.Messages.Message
  alias Canopy.Threads.ThreadRead
  alias Canopy.Users.User

  @topic "threads"
  @reads_topic "threads:reads"
  @inbox_limit 50
  @active_days 7

  @doc """
  Subscribe to what changes threads across channels, for views that span
  them, such as the Threads inbox:

    * `{:thread_reply, channel_id, root_id}` — a thread got a reply
    * `{:thread_turn, channel_id, agent_id, thread_id | nil}` — an agent's
      turn started working for a thread (or for the channel, nil), or ended
      (nil)
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  @doc """
  Subscribe to `{:thread_reads, root_id}`: the user read, followed, or
  unfollowed a thread (or a reply made them follow it), so unread badges, the
  summary rows' dots, and the inbox can follow in every open view. The
  process that made the change is not told.
  """
  def subscribe_reads, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @reads_topic)

  @doc false
  def broadcast_reads(root_id) do
    Phoenix.PubSub.broadcast_from(Canopy.PubSub, self(), @reads_topic, {:thread_reads, root_id})
  end

  @doc false
  def broadcast_reply(%Message{channel_id: channel_id, thread_id: root_id})
      when is_binary(root_id) do
    Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:thread_reply, channel_id, root_id})
  end

  @doc false
  def broadcast_turn(channel_id, agent_id, thread_id) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      @topic,
      {:thread_turn, channel_id, agent_id, thread_id}
    )
  end

  @doc "The user's read state in a thread, or nil."
  def get_read(root_id, %User{id: user_id}),
    do: Repo.get_by(ThreadRead, root_id: root_id, user_id: user_id)

  @doc "True when the user follows the thread."
  def following?(root_id, %User{} = user) do
    match?(%ThreadRead{following: true}, get_read(root_id, user))
  end

  @doc "Follows (or unfollows) a thread by hand: the bell in the thread panel."
  def follow(root_id, %User{id: user_id}, following?) when is_boolean(following?) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ThreadRead{root_id: root_id, user_id: user_id, following: following?, updated_at: now},
      on_conflict: [set: [following: following?, updated_at: now]],
      conflict_target: [:root_id, :user_id]
    )

    broadcast_reads(root_id)
  end

  @doc "Records that the user has read the thread as of now (it is open in the panel)."
  def mark_read(root_id, %User{id: user_id}) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ThreadRead{root_id: root_id, user_id: user_id, last_read_at: now, updated_at: now},
      on_conflict: [set: [last_read_at: now, updated_at: now]],
      conflict_target: [:root_id, :user_id]
    )

    broadcast_reads(root_id)
  end

  @doc """
  Follows the thread a new reply is in, on the local user's behalf, when the
  reply is theirs (which also marks the thread read and re-follows it after
  an unfollow), when they wrote the root, when the reply or the root mentions
  them, or in a DM. Run inside the transaction that inserts the reply; the
  caller broadcasts `broadcast_reads/1` once it has committed.
  """
  def auto_follow(_repo, %Message{thread_id: nil}), do: :skip

  def auto_follow(repo, %Message{thread_id: root_id} = reply) do
    user = Users.local()
    now = DateTime.utc_now()

    cond do
      reply.user_id == user.id ->
        repo.insert!(
          %ThreadRead{
            root_id: root_id,
            user_id: user.id,
            following: true,
            last_read_at: now,
            updated_at: now
          },
          on_conflict: [set: [following: true, last_read_at: now, updated_at: now]],
          conflict_target: [:root_id, :user_id]
        )

        :followed

      follows_by_default?(repo, reply, user) ->
        # an explicit unfollow (false) stays; an undecided row (nil) follows
        repo.query!(
          """
          INSERT INTO thread_reads (root_id, user_id, following, updated_at)
          VALUES (?1, ?2, 1, ?3)
          ON CONFLICT (root_id, user_id) DO UPDATE SET following = 1, updated_at = ?3
          WHERE following IS NULL
          """,
          [root_id, user.id, now]
        )

        :followed

      true ->
        :skip
    end
  end

  defp follows_by_default?(repo, reply, user) do
    root = repo.get(Message, reply.thread_id)
    channel = repo.get(Canopy.Channels.Channel, reply.channel_id)

    (root && root.user_id == user.id) or reply.mentions_user or
      (root && root.mentions_user) or (channel && channel.kind == "dm")
  end

  # -- Inbox ---------------------------------------------------------------------

  @doc """
  The Threads inbox for one tab, newest activity first:

    * `:following` — threads the user follows
    * `:active` — any thread with a reply in the last #{@active_days} days
    * `:working` — the roots in `opts[:working]` (threads an agent is working
      in right now, from `Canopy.Runtime.turn_threads/1`)

  Each row is `%{id, root, channel, summary, recent, unread, following?}`:
  `root` with its sender and channel, `summary` from
  `Canopy.Messages.thread_summaries/1` (nil without replies), `recent` the
  last two replies, `unread` the replies the user has not read in a thread
  they follow.
  """
  def inbox(%User{} = user, tab, opts \\ []) do
    tab
    |> root_ids(user, opts)
    |> rows(user)
  end

  defp root_ids(:following, %User{id: user_id}, _opts) do
    from(r in ThreadRead,
      left_join: m in Message,
      on: m.thread_id == r.root_id,
      where: r.user_id == ^user_id and r.following == true,
      group_by: r.root_id,
      order_by: [desc: fragment("coalesce(max(?), ?)", m.id, r.root_id)],
      limit: @inbox_limit,
      select: r.root_id
    )
    |> Repo.all()
  end

  defp root_ids(:active, _user, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -@active_days * 86_400, :second)

    from(m in Message,
      where: not is_nil(m.thread_id) and m.inserted_at >= ^cutoff,
      group_by: m.thread_id,
      order_by: [desc: max(m.id)],
      limit: @inbox_limit,
      select: m.thread_id
    )
    |> Repo.all()
  end

  defp root_ids(:working, _user, opts), do: opts |> Keyword.get(:working, []) |> Enum.uniq()

  defp rows([], _user), do: []

  defp rows(root_ids, %User{id: user_id} = user) do
    roots =
      from(m in Message,
        where: m.id in ^root_ids,
        preload: [:agent, :user, channel: [:agents, :owner]]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    summaries = Messages.thread_summaries(root_ids)
    unread = Unread.thread_summary(user)

    following =
      from(r in ThreadRead,
        where: r.user_id == ^user_id and r.root_id in ^root_ids and r.following == true,
        select: r.root_id
      )
      |> Repo.all()
      |> MapSet.new()

    recent = recent_replies(root_ids)

    for id <- root_ids, root = Map.get(roots, id), not is_nil(root) do
      %{
        id: id,
        root: root,
        channel: root.channel,
        summary: Map.get(summaries, id),
        recent: Map.get(recent, id, []),
        unread: get_in(unread, [id, :count]) || 0,
        following?: MapSet.member?(following, id)
      }
    end
  end

  # The last two replies of every root, in one query: `%{root_id => [reply]}`.
  defp recent_replies(root_ids) do
    ranked =
      from(m in Message,
        where: m.thread_id in ^root_ids,
        windows: [newest: [partition_by: m.thread_id, order_by: [desc: m.id]]],
        select: %{id: m.id, rank: over(row_number(), :newest)}
      )

    from(m in Message,
      join: r in subquery(ranked),
      on: r.id == m.id,
      where: r.rank <= 2,
      order_by: [asc: m.id],
      preload: [:agent, :user]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.thread_id)
  end
end
