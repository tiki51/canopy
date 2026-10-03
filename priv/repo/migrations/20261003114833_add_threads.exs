defmodule Canopy.Repo.Migrations.AddThreads do
  use Ecto.Migration

  # Threads become a place of their own. A timeline event names the thread it
  # belongs to (`thread_id`, the root message id) and whether the channel feed
  # shows it (`in_channel`): a thread reply and the turn cards of thread work
  # stay in the thread unless the reply was also sent to the channel. The
  # backfill moves existing thread replies out of the feed; old turn events
  # stay in the channel, since their thread cannot be recovered. Plain SQL, so
  # later schema changes cannot break it, and safe to run again.
  #
  # `thread_reads` is the user's state per thread: when they last read it and
  # whether they follow it. On upgrade, the threads the user took part in
  # (started, replied in, was mentioned in, or in a DM) are followed and read
  # up to their newest reply, so they show under Following without flooding
  # the unread badge. An explicit unfollow is never undone.
  #
  # `messages.mentions_user` says whether a message mentions the local user
  # (`@` + display name, compared with Elixir's Unicode-aware downcase, the
  # same test as `Canopy.Unread.mentions?/2`), so channel unread, mention
  # counts, and auto-follow agree on non-ASCII names.

  def up do
    alter table(:timeline_events) do
      add :thread_id, :string
      add :in_channel, :boolean, null: false, default: true
    end

    create index(:timeline_events, [:channel_id, :in_channel, :id])
    create index(:timeline_events, [:thread_id, :id])

    alter table(:messages) do
      add :sent_to_channel, :boolean, null: false, default: false
      add :mentions_user, :boolean, null: false, default: false
    end

    create table(:thread_reads, primary_key: false) do
      add :root_id, references(:messages, type: :string, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :string, on_delete: :delete_all), primary_key: true
      add :last_read_at, :utc_datetime_usec
      # nil until decided: following is set by the bell or by participating;
      # auto-follow never overrides an explicit unfollow
      add :following, :boolean
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:thread_reads, [:user_id, :following])

    flush()
    backfill(repo())
    backfill_mentions(repo())
    backfill_following(repo(), DateTime.utc_now())
  end

  def down do
    drop table(:thread_reads)

    alter table(:messages) do
      remove :sent_to_channel
      remove :mentions_user
    end

    drop index(:timeline_events, [:thread_id, :id])
    drop index(:timeline_events, [:channel_id, :in_channel, :id])

    alter table(:timeline_events) do
      remove :thread_id
      remove :in_channel
    end
  end

  @doc false
  def backfill(repo) do
    repo.query!("""
    UPDATE timeline_events
    SET thread_id = (SELECT m.thread_id FROM messages m WHERE m.id = timeline_events.ref_id),
        in_channel = (SELECT m.sent_to_channel FROM messages m WHERE m.id = timeline_events.ref_id)
    WHERE event_type = 'message'
      AND ref_id IN (SELECT id FROM messages WHERE thread_id IS NOT NULL)
    """)

    :ok
  end

  @doc false
  def backfill_mentions(repo) do
    case local_user(repo) do
      nil ->
        :ok

      {_id, name} ->
        repo.query!("SELECT id, body FROM messages WHERE body LIKE '%@%'").rows
        |> Enum.filter(fn [_id, body] -> mentions?(body, name) end)
        |> Enum.map(fn [id, _body] -> id end)
        |> Enum.chunk_every(500)
        |> Enum.each(fn ids ->
          marks = Enum.map_join(ids, ", ", fn _ -> "?" end)
          repo.query!("UPDATE messages SET mentions_user = 1 WHERE id IN (#{marks})", ids)
        end)
    end

    :ok
  end

  @doc false
  def backfill_following(repo, now) do
    case local_user(repo) do
      nil ->
        :ok

      {user_id, _name} ->
        repo.query!(
          """
          INSERT INTO thread_reads (root_id, user_id, following, last_read_at, updated_at)
          SELECT r.id, ?1, 1, max(m.inserted_at), ?2
          FROM messages r
          JOIN messages m ON m.thread_id = r.id
          JOIN channels c ON c.id = r.channel_id
          GROUP BY r.id
          HAVING r.user_id = ?1 OR r.mentions_user = 1 OR c.kind = 'dm'
              OR max(m.user_id = ?1) = 1 OR max(m.mentions_user) = 1
          ON CONFLICT (root_id, user_id) DO UPDATE SET
            following = coalesce(thread_reads.following, 1),
            last_read_at = coalesce(thread_reads.last_read_at, excluded.last_read_at)
          """,
          [user_id, DateTime.to_iso8601(now)]
        )

        :ok
    end
  end

  # The one local user (the first by id), as `{id, display_name}`.
  defp local_user(repo) do
    case repo.query!("SELECT id, display_name FROM users ORDER BY id LIMIT 1").rows do
      [[id, name]] -> {id, name}
      [] -> nil
    end
  end

  # As `Canopy.Unread.mentions?/2`, kept here so later code changes cannot
  # change what this migration did.
  defp mentions?(body, name) do
    case String.trim(name || "") do
      "" -> false
      name -> String.contains?(String.downcase(body || ""), "@" <> String.downcase(name))
    end
  end
end
