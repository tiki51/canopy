defmodule Canopy.Repo.Migrations.AddModelRouting do
  use Ecto.Migration

  # Model routing (experimental, off until the Phase 0 spike): an agent may run
  # cheap wakes on a light model. Every agent starts with routing off; the light
  # model and effort inherit the engine's light default from Settings when nil.
  def change do
    alter table(:settings) do
      add :claude_light_model, :text
      add :claude_light_effort, :text
      add :opencode_light_provider, :text
      add :opencode_light_model, :text
    end

    alter table(:agents) do
      add :routing_enabled, :boolean, null: false, default: false
      add :light_model_provider, :text
      add :light_model_id, :text
      add :light_effort, :text
    end

    # A routing rule paused for one agent and wake kind ("*": every kind)
    # because its light turns escalated too often, or the light model failed.
    # Resuming keeps the row with `resumed_at`, so the escalation window
    # restarts from then.
    create table(:routing_pauses, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), null: false
      add :wake_kind, :string, null: false
      add :reason, :text
      add :paused_at, :utc_datetime_usec
      add :resumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:routing_pauses, [:agent_id, :wake_kind])
  end
end
