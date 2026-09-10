defmodule Canopy.Repo.Migrations.AddKindToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :kind, :string, null: false, default: "channel"
    end

    create index(:channels, [:repository_id, :kind, :owner_agent_id])
  end
end
