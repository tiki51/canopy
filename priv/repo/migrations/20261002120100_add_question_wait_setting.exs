defmodule Canopy.Repo.Migrations.AddQuestionWaitSetting do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :question_wait_minutes, :integer, null: false, default: 10
    end
  end
end
