defmodule Canopy.Repo.Migrations.CreateAgentMemories do
  use Ecto.Migration

  def change do
    create table(:agent_memories, primary_key: false) do
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), primary_key: true

      add :body, :text, null: false, default: ""
      timestamps(type: :utc_datetime_usec)
    end
  end
end
