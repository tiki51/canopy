defmodule Canopy.Repo.Migrations.AddLockHoldSetting do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :lock_hold_minutes, :integer, null: false, default: 30
    end
  end
end
