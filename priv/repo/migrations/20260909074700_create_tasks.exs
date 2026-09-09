defmodule Canopy.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :owner_agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "open"
      add :result, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:channel_id])
    create index(:tasks, [:owner_agent_id])
  end
end
