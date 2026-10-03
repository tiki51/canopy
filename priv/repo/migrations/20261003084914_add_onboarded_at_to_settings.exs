defmodule Canopy.Repo.Migrations.AddOnboardedAtToSettings do
  use Ecto.Migration

  import Ecto.Query

  # nil means first-run setup has not been finished or skipped yet. An install
  # that already has its settings row when this runs is stamped, so only a fresh
  # database (whose row the seeds create after migrating) goes through setup.
  def change do
    alter table(:settings) do
      add :onboarded_at, :utc_datetime_usec
    end

    execute(fn -> stamp(repo(), DateTime.utc_now()) end, fn -> :ok end)
  end

  @doc false
  def stamp(repo, now) do
    repo.update_all(
      from(s in "settings",
        where: is_nil(s.onboarded_at),
        update: [set: [onboarded_at: type(^now, :utc_datetime_usec)]]
      ),
      []
    )
  end
end
