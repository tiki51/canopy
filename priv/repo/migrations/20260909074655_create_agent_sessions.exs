defmodule Canopy.Repo.Migrations.CreateAgentSessions do
  use Ecto.Migration

  def change do
    create table(:agent_sessions, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), null: false
      add :opencode_session_id, :string, null: false

      add :parent_session_id,
          references(:agent_sessions, type: :string, on_delete: :nilify_all)

      add :status, :string, null: false, default: "idle"
      add :last_error, :text
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_sessions, [:opencode_session_id])

    # SQLite reports unique violations by column list, so this index keeps the
    # default name (agent_sessions_channel_id_agent_id_index) for Ecto to match.
    create unique_index(:agent_sessions, [:channel_id, :agent_id],
             where: "parent_session_id IS NULL"
           )

    create index(:agent_sessions, [:agent_id])
    create index(:agent_sessions, [:parent_session_id])
  end
end
