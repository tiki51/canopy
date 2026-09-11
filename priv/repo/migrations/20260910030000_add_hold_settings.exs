defmodule Canopy.Repo.Migrations.AddHoldSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :hold_reason, :string
      add :hold_at, :utc_datetime_usec
    end
  end
end
