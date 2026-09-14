defmodule Canopy.Repo.Migrations.AddEngineColumns do
  use Ecto.Migration

  # A second execution engine (Claude Code) beside OpenCode: agents say which
  # engine runs them, sessions say which engine owns them, and the engine's
  # session id is unique per engine rather than globally.
  def change do
    alter table(:agents) do
      add :engine, :string, null: false, default: "opencode"
    end

    alter table(:agent_sessions) do
      add :engine, :string, null: false, default: "opencode"
    end

    drop unique_index(:agent_sessions, [:opencode_session_id])
    rename table(:agent_sessions), :opencode_session_id, to: :engine_session_id
    create unique_index(:agent_sessions, [:engine, :engine_session_id])
  end
end
