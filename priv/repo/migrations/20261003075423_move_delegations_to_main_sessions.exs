defmodule Canopy.Repo.Migrations.MoveDelegationsToMainSessions do
  use Ecto.Migration

  # A delegation from one agent to another used to run in a child session of
  # the delegate; every delegation now runs in the delegate's one session in
  # the channel. Pending delegations that have gone a day without a turn were
  # abandoned in practice: they are cancelled, with one note per channel
  # saying so. The rest point at the delegate's main session (or at nothing,
  # when it has none yet), and the reminder on its next prompt lists them.
  # Child sessions stay, since turn summaries and costs name them, but are
  # never woken again. Plain SQL, so later schema changes cannot break it, and
  # safe to run again.

  @stale_after_hours 24

  def up, do: move(repo(), DateTime.utc_now())

  def down, do: :ok

  @doc false
  def move(repo, now) do
    cutoff = DateTime.add(now, -@stale_after_hours * 3600, :second)
    stamp = DateTime.to_iso8601(now)

    # Each pending delegation, whether its session is a child session, and
    # when it last saw a turn there (or when it was created, if never).
    pending =
      repo.query!("""
      SELECT d.id, d.channel_id, d.child_session_id, s.parent_session_id, d.inserted_at,
             (SELECT max(e.inserted_at) FROM timeline_events e
               WHERE e.event_type = 'agent_started' AND e.ref_id = d.child_session_id)
      FROM delegations d
      LEFT JOIN agent_sessions s ON s.id = d.child_session_id
      WHERE d.status IN ('requested', 'working')
      """).rows

    {stale, live} =
      Enum.split_with(pending, fn [_id, _channel, _session, _parent, created, started] ->
        DateTime.compare(latest(created, started), cutoff) == :lt
      end)

    cancel(repo, stale, stamp)

    live
    |> Enum.filter(fn [_id, _channel, session, parent, _created, _started] ->
      is_nil(session) or not is_nil(parent)
    end)
    |> Enum.map(&hd/1)
    |> repoint(repo, stamp)
  end

  defp cancel(_repo, [], _stamp), do: :ok

  defp cancel(repo, stale, stamp) do
    ids = Enum.map(stale, &hd/1)

    repo.query!(
      "UPDATE delegations SET status = 'cancelled', completed_at = ?, updated_at = ? " <>
        "WHERE id IN (#{placeholders(ids)})",
      [stamp, stamp | ids]
    )

    stale
    |> Enum.group_by(fn [_id, channel | _] -> channel end, &hd/1)
    |> Enum.each(fn {channel_id, cancelled} ->
      n = length(cancelled)
      noun = if n == 1, do: "delegation", else: "delegations"

      payload = %{
        "note" =>
          "Cancelled #{n} stale #{noun} while moving delegated work into agents' main sessions.",
        "delegation_ids" => cancelled
      }

      repo.query!(
        "INSERT INTO timeline_events (id, channel_id, event_type, payload, inserted_at, updated_at) " <>
          "VALUES (?, ?, 'delegation_cancelled', ?, ?, ?)",
        [Canopy.ID.generate("evt"), channel_id, JSON.encode!(payload), stamp, stamp]
      )
    end)
  end

  defp repoint([], _repo, _stamp), do: :ok

  defp repoint(ids, repo, stamp) do
    repo.query!(
      """
      UPDATE delegations SET updated_at = ?, child_session_id =
        (SELECT r.id FROM agent_sessions r
          WHERE r.channel_id = delegations.channel_id AND r.agent_id = delegations.to_agent_id
            AND r.parent_session_id IS NULL)
      WHERE id IN (#{placeholders(ids)})
      """,
      [stamp | ids]
    )
  end

  defp placeholders(ids), do: Enum.map_join(ids, ", ", fn _ -> "?" end)

  defp latest(created, nil), do: to_datetime(created)

  defp latest(created, started) do
    [to_datetime(created), to_datetime(started)] |> Enum.max(DateTime)
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp to_datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> text |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    end
  end
end
