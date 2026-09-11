defmodule Canopy.Repo.Migrations.AddSerializeTurnsSetting do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :serialize_turns, :boolean, null: false, default: true
    end
  end
end
