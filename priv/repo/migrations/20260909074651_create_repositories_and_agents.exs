defmodule Canopy.Repo.Migrations.CreateRepositoriesAndAgents do
  use Ecto.Migration

  def change do
    create table(:repositories, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :path, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repositories, [:path])

    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :display_name, :string, null: false
      add :role, :string
      add :system_prompt, :text
      add :opencode_agent, :string, null: false, default: "build"
      add :model_provider, :string
      add :model_id, :string
      add :color, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:name])
  end
end
