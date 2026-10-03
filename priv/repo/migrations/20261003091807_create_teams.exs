defmodule Canopy.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  def change do
    create table(:teams, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :display_name, :string
      add :description, :string
      # required by the changeset; nilified only if the agent row is deleted
      add :lead_agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:teams, [:name])

    create table(:team_members, primary_key: false) do
      add :team_id, references(:teams, type: :string, on_delete: :delete_all), primary_key: true

      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), primary_key: true

      # what the member does on this team ("reviewer"); unused until playbooks
      add :role, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:team_members, [:agent_id])
  end
end
