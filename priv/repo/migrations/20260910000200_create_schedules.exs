defmodule Canopy.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), null: false
      add :created_by_agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      add :instruction, :text, null: false
      add :kind, :string, null: false
      add :run_at, :utc_datetime_usec
      add :cron, :string
      add :next_run_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :run_count, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :status_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:schedules, [:channel_id, :status])
    create index(:schedules, [:agent_id, :status])
  end
end
