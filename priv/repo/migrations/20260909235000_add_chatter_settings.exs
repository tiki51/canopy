defmodule Canopy.Repo.Migrations.AddChatterSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :chatter_pause, :boolean, null: false, default: true
      add :chatter_limit, :integer, null: false, default: 6
    end
  end
end
