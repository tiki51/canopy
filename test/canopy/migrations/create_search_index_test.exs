defmodule Canopy.Migrations.CreateSearchIndexTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Canopy.{Repo, Search}
  alias Canopy.Search.Entry

  @migration Canopy.Repo.Migrations.CreateSearchIndex
  @path "priv/repo/migrations/20261003180058_create_search_index.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    scenario()
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp backfill, do: apply(@migration, :backfill, [Repo])

  defp count(source),
    do: Repo.aggregate(from(e in Entry, where: e.source == ^source), :count)

  defp fts_count, do: Repo.one(from(f in "search_fts", select: count()))

  # Rows as an older Canopy wrote them, straight in SQL, then the index
  # emptied as it was before the migration.
  defp seed(ctx) do
    now = "2026-09-01T10:00:00.000000Z"

    for {id, body} <- [
          {"msg_01J0000000000000000000000A", "the retry worker double charges"},
          {"msg_01J0000000000000000000000B", "unrelated lunch plans"}
        ] do
      Repo.query!(
        """
        INSERT INTO messages (id, channel_id, user_id, kind, body, mentions, inserted_at, updated_at)
        VALUES (?, ?, ?, 'post', ?, '[]', ?, ?)
        """,
        [id, ctx.channel.id, ctx.user.id, body, now, now]
      )
    end

    payload =
      Jason.encode!(%{
        "files" => ["src/billing/enqueue_charge.py"],
        "activity" => [%{"kind" => "tool", "label" => "bash", "detail" => "pytest -k retry"}]
      })

    for {id, type, payload} <- [
          {"evt_01J0000000000000000000000C", "agent_turn_completed", payload},
          {"evt_01J0000000000000000000000D", "task_updated", ~s({"final_text":"ignored"})}
        ] do
      Repo.query!(
        """
        INSERT INTO timeline_events (id, channel_id, agent_id, event_type, payload, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [id, ctx.channel.id, ctx.agent.id, type, payload, now, now]
      )
    end

    Repo.query!("DELETE FROM search_entries")
  end

  test "messages and finished turns are indexed, once", ctx do
    seed(ctx)
    assert count("message") == 0
    assert fts_count() == 0

    backfill()

    assert count("message") == 2
    assert count("turn") == 1
    assert fts_count() == 3

    assert [%{ref_id: "msg_01J0000000000000000000000A"}] = Search.search("double charges").results
    assert [%{ref_id: "evt_01J0000000000000000000000C"}] = Search.search("enqueue_charge").results
    assert [%{ref_id: "evt_01J0000000000000000000000C"}] = Search.search("pytest").results
    assert Search.search("ignored").results == []

    # entries follow time across sources
    assert Repo.all(from(e in Entry, order_by: e.id, select: e.ref_id)) == [
             "msg_01J0000000000000000000000A",
             "msg_01J0000000000000000000000B",
             "evt_01J0000000000000000000000C"
           ]

    # safe to run again
    backfill()
    assert count("message") == 2
    assert count("turn") == 1
    assert fts_count() == 3
  end

  test "the old message index is gone" do
    assert %{rows: []} =
             Repo.query!("SELECT name FROM sqlite_master WHERE name LIKE 'messages_fts%'")
  end
end
