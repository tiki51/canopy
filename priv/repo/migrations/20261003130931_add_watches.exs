defmodule Canopy.Repo.Migrations.AddWatches do
  use Ecto.Migration

  def change do
    # A watch is a schedule (kind "watch") whose check Canopy runs itself with
    # the gh CLI, waking the agent only when something new appears.
    alter table(:schedules) do
      # %{"source", "repo", "branch", "label", "workflow_file"}
      add :check, :map
      # %{"etag", "last_checked_at", "last_error", "failures", "fired"}
      add :check_state, :map, null: false, default: %{}
      # start this playbook per new item instead of a plain wake
      add :playbook, :string
    end

    # Every item a watch has seen (or was shown as its baseline): a new key is
    # a new item. Written in the same transaction as the delivery note and the
    # ETag, so an item is never lost between a check and a wake.
    create table(:watch_items, primary_key: false) do
      add :id, :string, primary_key: true

      add :schedule_id, references(:schedules, type: :string, on_delete: :delete_all), null: false

      add :key, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:watch_items, [:schedule_id, :key])

    alter table(:settings) do
      add :gh_binary, :string, null: false, default: "gh"
    end
  end
end
