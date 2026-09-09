defmodule Canopy.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def up do
    create table(:messages, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      # SQLite cannot add constraints after the fact, so the sender rule is
      # declared inline: exactly one of agent_id / user_id must be set.
      add :user_id, references(:users, type: :string, on_delete: :nilify_all),
        check: %{
          name: "messages_sender_check",
          expr: "(agent_id IS NULL) <> (user_id IS NULL)"
        }

      add :thread_id, references(:messages, type: :string, on_delete: :delete_all)
      add :kind, :string, null: false, default: "post"
      add :body, :text, null: false
      add :mentions, {:array, :string}, null: false, default: "[]"
      add :opencode_message_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:channel_id, :id])
    create index(:messages, [:thread_id])
    create index(:messages, [:agent_id])
    create index(:messages, [:user_id])

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
  end

  def down do
    execute "DROP TRIGGER IF EXISTS messages_fts_au"
    execute "DROP TRIGGER IF EXISTS messages_fts_ad"
    execute "DROP TRIGGER IF EXISTS messages_fts_ai"
    execute "DROP TABLE IF EXISTS messages_fts"
    drop table(:messages)
  end
end
