defmodule Canopy.Repo.Migrations.CreateTimelineEvents do
  use Ecto.Migration

  def change do
    create table(:timeline_events, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :ref_id, :string
      add :payload, :map, null: false, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:timeline_events, [:channel_id, :id])
    create index(:timeline_events, [:ref_id])
  end
end
