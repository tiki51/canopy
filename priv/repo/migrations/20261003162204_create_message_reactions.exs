defmodule Canopy.Repo.Migrations.CreateMessageReactions do
  use Ecto.Migration

  def change do
    # A reaction is row state on a message, never a timeline event: it wakes
    # nobody and never counts as unread (Reactions plan).
    create table(:message_reactions, primary_key: false) do
      add :id, :string, primary_key: true

      add :message_id, references(:messages, type: :string, on_delete: :delete_all), null: false

      # denormalised from the message, for "reactions since your last read"
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      # a palette key ("check"), not the glyph
      add :emoji, :string, null: false
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all)

      # SQLite cannot add constraints after the fact, so the reactor rule is
      # declared inline: exactly one of agent_id / user_id must be set.
      add :user_id, references(:users, type: :string, on_delete: :delete_all),
        check: %{
          name: "message_reactions_reactor_check",
          expr: "(agent_id IS NULL) <> (user_id IS NULL)"
        }

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # NULLs are distinct in a unique index, so each kind of reactor gets its own
    create unique_index(:message_reactions, [:message_id, :emoji, :agent_id],
             where: "agent_id IS NOT NULL"
           )

    create unique_index(:message_reactions, [:message_id, :emoji, :user_id],
             where: "user_id IS NOT NULL"
           )

    # the preload (the partial indexes above cannot serve a plain IN)
    create index(:message_reactions, [:message_id])
    create index(:message_reactions, [:channel_id, :id])
  end
end
