defmodule Canopy.Repo.Migrations.CreateGlobalPermissions do
  use Ecto.Migration

  # Global permissions (`Canopy.GlobalPermissions`): a tool an agent may use in
  # every channel and repository without asking, until it is removed. Purely
  # additive: the table starts empty.

  def change do
    create table(:global_permissions, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), null: false
      # the match key: the tool name, trimmed and downcased
      add :tool, :string, null: false
      # the name the engine showed when it was granted, for display
      add :label, :string, null: false
      # where it was granted; the channel may be deleted later
      add :channel_id, references(:channels, type: :string, on_delete: :nilify_all)
      add :granted_at, :utc_datetime_usec, null: false
      add :use_count, :integer, null: false, default: 0
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:global_permissions, [:agent_id, :tool])
  end
end
