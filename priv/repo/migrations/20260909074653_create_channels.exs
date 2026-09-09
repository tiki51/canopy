defmodule Canopy.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels, primary_key: false) do
      add :id, :string, primary_key: true

      add :repository_id, references(:repositories, type: :string, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :topic, :string
      add :status, :string, null: false, default: "open"
      add :owner_agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channels, [:repository_id, :name])
    create index(:channels, [:owner_agent_id])

    create table(:channel_agents, primary_key: false) do
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all),
        primary_key: true

      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), primary_key: true

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:channel_agents, [:agent_id])
  end
end
