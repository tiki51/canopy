defmodule Canopy.Repo.Migrations.CreateSearchIndex do
  use Ecto.Migration

  # One full-text index for everything the Search page and
  # `canopy_messages_search` look through: messages, finished turns
  # (`agent_turn_completed` events), and documents. `search_entries` holds one
  # row per searchable item with what the filters need; `search_fts` shares
  # its rowid and holds the text in three columns (a document's filename, the
  # body, a turn's changed files), weighted 6 / 1 / 3 so a filename hit
  # outranks a path hit, which outranks a body hit. The FTS table keeps its
  # own copy of the text: turn text is built from JSON and document text
  # lives on disk, so there is no column external content could point at, and
  # `snippet()` needs the text.
  #
  # Triggers keep messages and turns in sync, so every writer (and every
  # cascade) is covered. Documents are indexed from Elixir when they are
  # created (`Canopy.Search.index_document/2`), since their text is on disk;
  # existing ones are indexed at boot by `Canopy.Search.Backfill`. Deleting a
  # document removes its entry here.
  #
  # The index replaces `messages_fts`. The backfill is plain SQL, so later
  # schema changes cannot break it, and safe to run again. The triggers use
  # only functions the macOS sqlite3 CLI (3.43) has, so the e2e helpers that
  # write through it keep working.

  # A turn's text: its final text (when it posted through tools), its pass
  # note, and one line per tool call (the command, else the row's label: a
  # path, a pattern, a URL; then its error line). Narration and Canopy's own
  # tool calls stay out.
  @turn_body ~S"""
  coalesce((SELECT group_concat(line, char(10)) FROM (
    SELECT json_extract({payload}, '$.final_text') AS line
    UNION ALL SELECT json_extract({payload}, '$.note')
    UNION ALL SELECT trim(coalesce(json_extract(a.value, '$.command'), json_extract(a.value, '$.label'), '')
                          || ' ' || coalesce(json_extract(a.value, '$.detail'), ''))
      FROM json_each({payload}, '$.activity') AS a
      WHERE json_extract(a.value, '$.kind') = 'tool'
        AND coalesce(json_extract(a.value, '$.category'), '') <> 'canopy'
        AND json_extract(a.value, '$.label') NOT LIKE 'canopy\_%' ESCAPE '\'
        AND json_extract(a.value, '$.label') NOT LIKE 'mcp\_\_canopy\_\_%' ESCAPE '\'
  )), '')
  """

  # The files a turn changed, one per line.
  @turn_paths ~S"""
  coalesce((SELECT group_concat(value, char(10)) FROM json_each({payload}, '$.files')), '')
  """

  @doc false
  def turn_body(payload), do: String.replace(@turn_body, "{payload}", payload)

  @doc false
  def turn_paths(payload), do: String.replace(@turn_paths, "{payload}", payload)

  def up do
    execute """
    CREATE TABLE search_entries (
      id INTEGER PRIMARY KEY,
      source TEXT NOT NULL,
      ref_id TEXT NOT NULL,
      channel_id TEXT REFERENCES channels(id) ON DELETE SET NULL,
      agent_id TEXT,
      user_id TEXT,
      thread_id TEXT,
      inserted_at TEXT NOT NULL
    )
    """

    execute "CREATE UNIQUE INDEX search_entries_source_ref ON search_entries(source, ref_id)"
    execute "CREATE INDEX search_entries_channel_time ON search_entries(channel_id, inserted_at)"
    execute "CREATE INDEX search_entries_agent ON search_entries(agent_id)"

    execute """
    CREATE VIRTUAL TABLE search_fts USING fts5(
      title,
      body,
      paths,
      tokenize = "unicode61 remove_diacritics 2",
      prefix = '2 3'
    )
    """

    execute "INSERT INTO search_fts(search_fts, rank) VALUES('rank', 'bm25(6.0, 1.0, 3.0)')"

    execute """
    CREATE TRIGGER search_entries_ad AFTER DELETE ON search_entries BEGIN
      DELETE FROM search_fts WHERE rowid = old.id;
    END
    """

    # -- messages

    execute """
    CREATE TRIGGER search_messages_ai AFTER INSERT ON messages BEGIN
      INSERT INTO search_entries(source, ref_id, channel_id, agent_id, user_id, thread_id, inserted_at)
        VALUES ('message', new.id, new.channel_id, new.agent_id, new.user_id, new.thread_id, new.inserted_at);
      INSERT INTO search_fts(rowid, title, body, paths) VALUES (last_insert_rowid(), '', new.body, '');
    END
    """

    execute """
    CREATE TRIGGER search_messages_ad AFTER DELETE ON messages BEGIN
      DELETE FROM search_entries WHERE source = 'message' AND ref_id = old.id;
    END
    """

    execute """
    CREATE TRIGGER search_messages_au_body AFTER UPDATE OF body ON messages BEGIN
      DELETE FROM search_fts
        WHERE rowid = (SELECT id FROM search_entries WHERE source = 'message' AND ref_id = new.id);
      INSERT INTO search_fts(rowid, title, body, paths)
        SELECT id, '', new.body, '' FROM search_entries WHERE source = 'message' AND ref_id = new.id;
    END
    """

    # backdating (the e2e seeds do) and a sender nilified by a deleted agent
    execute """
    CREATE TRIGGER search_messages_au_meta
    AFTER UPDATE OF channel_id, agent_id, user_id, thread_id, inserted_at ON messages BEGIN
      UPDATE search_entries
        SET channel_id = new.channel_id, agent_id = new.agent_id, user_id = new.user_id,
            thread_id = new.thread_id, inserted_at = new.inserted_at
        WHERE source = 'message' AND ref_id = new.id;
    END
    """

    # -- finished turns

    execute """
    CREATE TRIGGER search_turns_ai AFTER INSERT ON timeline_events
    WHEN new.event_type = 'agent_turn_completed' BEGIN
      INSERT INTO search_entries(source, ref_id, channel_id, agent_id, user_id, thread_id, inserted_at)
        VALUES ('turn', new.id, new.channel_id, new.agent_id, NULL, new.thread_id, new.inserted_at);
      INSERT INTO search_fts(rowid, title, body, paths)
        VALUES (last_insert_rowid(), '', #{turn_body("new.payload")}, #{turn_paths("new.payload")});
    END
    """

    execute """
    CREATE TRIGGER search_turns_ad AFTER DELETE ON timeline_events
    WHEN old.event_type = 'agent_turn_completed' BEGIN
      DELETE FROM search_entries WHERE source = 'turn' AND ref_id = old.id;
    END
    """

    # the costs model backfill rewrites payloads
    execute """
    CREATE TRIGGER search_turns_au AFTER UPDATE OF payload ON timeline_events
    WHEN new.event_type = 'agent_turn_completed' BEGIN
      DELETE FROM search_fts
        WHERE rowid = (SELECT id FROM search_entries WHERE source = 'turn' AND ref_id = new.id);
      INSERT INTO search_fts(rowid, title, body, paths)
        SELECT id, '', #{turn_body("new.payload")}, #{turn_paths("new.payload")}
        FROM search_entries WHERE source = 'turn' AND ref_id = new.id;
    END
    """

    execute """
    CREATE TRIGGER search_turns_au_meta
    AFTER UPDATE OF channel_id, agent_id, thread_id, inserted_at ON timeline_events
    WHEN new.event_type = 'agent_turn_completed' BEGIN
      UPDATE search_entries
        SET channel_id = new.channel_id, agent_id = new.agent_id, thread_id = new.thread_id,
            inserted_at = new.inserted_at
        WHERE source = 'turn' AND ref_id = new.id;
    END
    """

    # -- documents (indexed from Elixir; removed here, whoever deletes them)

    execute """
    CREATE TRIGGER search_documents_ad AFTER DELETE ON documents BEGIN
      DELETE FROM search_entries WHERE source = 'document' AND ref_id = old.id;
    END
    """

    # -- the old message index

    execute "DROP TRIGGER IF EXISTS messages_fts_au"
    execute "DROP TRIGGER IF EXISTS messages_fts_ad"
    execute "DROP TRIGGER IF EXISTS messages_fts_ai"
    execute "DROP TABLE IF EXISTS messages_fts"

    flush()
    backfill(repo())
  end

  def down do
    for trigger <- ~w(search_documents_ad search_turns_au_meta search_turns_au search_turns_ad
                      search_turns_ai search_messages_au_meta search_messages_au_body
                      search_messages_ad search_messages_ai search_entries_ad) do
      execute "DROP TRIGGER IF EXISTS #{trigger}"
    end

    execute "DROP TABLE IF EXISTS search_fts"
    execute "DROP TABLE IF EXISTS search_entries"

    execute """
    CREATE VIRTUAL TABLE messages_fts USING fts5(
      body,
      content='messages',
      content_rowid='rowid'
    )
    """

    execute """
    CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
    END
    """

    execute """
    CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, body)
        VALUES ('delete', old.rowid, old.body);
    END
    """

    execute """
    CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, body)
        VALUES ('delete', old.rowid, old.body);
      INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
    END
    """

    execute "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')"
  end

  @doc """
  Indexes every message and finished turn that has no entry yet: entries in
  time order (ids are ULIDs after a four-character prefix), then their text.
  Idempotent.
  """
  def backfill(repo) do
    %{rows: [[floor]]} = repo.query!("SELECT coalesce(max(id), 0) FROM search_entries")

    repo.query!("""
    INSERT INTO search_entries(source, ref_id, channel_id, agent_id, user_id, thread_id, inserted_at)
    SELECT * FROM (
      SELECT 'message' AS source, m.id AS ref_id, m.channel_id, m.agent_id, m.user_id,
             m.thread_id, m.inserted_at
        FROM messages m
        WHERE NOT EXISTS (SELECT 1 FROM search_entries e WHERE e.source = 'message' AND e.ref_id = m.id)
      UNION ALL
      SELECT 'turn', t.id, t.channel_id, t.agent_id, NULL, t.thread_id, t.inserted_at
        FROM timeline_events t
        WHERE t.event_type = 'agent_turn_completed'
          AND NOT EXISTS (SELECT 1 FROM search_entries e WHERE e.source = 'turn' AND e.ref_id = t.id)
    )
    ORDER BY substr(ref_id, 5)
    """)

    repo.query!(
      """
      INSERT INTO search_fts(rowid, title, body, paths)
      SELECT e.id, '', m.body, ''
        FROM search_entries e JOIN messages m ON m.id = e.ref_id
        WHERE e.source = 'message' AND e.id > ?
      """,
      [floor]
    )

    repo.query!(
      """
      INSERT INTO search_fts(rowid, title, body, paths)
      SELECT e.id, '', #{turn_body("t.payload")}, #{turn_paths("t.payload")}
        FROM search_entries e JOIN timeline_events t ON t.id = e.ref_id
        WHERE e.source = 'turn' AND e.id > ?
      """,
      [floor]
    )

    repo.query!("INSERT INTO search_fts(search_fts) VALUES('optimize')")
    :ok
  end
end
