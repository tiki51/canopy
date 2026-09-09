defmodule Canopy.Repo.Migrations.CreatePermissionRequests do
  use Ecto.Migration

  def change do
    create table(:permission_requests, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :agent_session_id,
          references(:agent_sessions, type: :string, on_delete: :delete_all),
          null: false

      add :opencode_permission_id, :string, null: false
      add :permission, :string, null: false
      add :patterns, {:array, :string}, null: false, default: "[]"
      add :metadata, :map, null: false, default: "{}"
      add :tool_call_id, :string
      add :status, :string, null: false, default: "pending"
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:permission_requests, [:opencode_permission_id])
    create index(:permission_requests, [:channel_id, :status])
    create index(:permission_requests, [:agent_session_id])
  end
end
