defmodule Canopy.Repo.Migrations.AddDefaultModelsToSettings do
  use Ecto.Migration

  # One default per engine, in the shape of the agent fields; nil leaves the
  # choice to the engine. Agents with no model (or effort) of their own inherit.
  def change do
    alter table(:settings) do
      add :claude_default_model, :text
      add :claude_default_effort, :text
      add :opencode_default_provider, :text
      add :opencode_default_model, :text
    end
  end
end
