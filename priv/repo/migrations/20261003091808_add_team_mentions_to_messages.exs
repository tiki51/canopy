defmodule Canopy.Repo.Migrations.AddTeamMentionsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :team_mentions, {:array, :map}, null: false, default: "[]"
    end
  end
end
