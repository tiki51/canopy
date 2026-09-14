defmodule Canopy.Repo.Migrations.AddCollaborationPrompt do
  use Ecto.Migration

  # NULL means "use the preamble Canopy ships"; a value overrides it.
  def change do
    alter table(:settings) do
      add :collaboration_prompt, :text
    end
  end
end
