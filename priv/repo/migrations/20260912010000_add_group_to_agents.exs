defmodule Canopy.Repo.Migrations.AddGroupToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :group, :string
    end

    create index(:agents, [:group])
  end
end
