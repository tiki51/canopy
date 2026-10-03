defmodule Canopy.Repo.Migrations.CreateTurnActivityDetails do
  use Ecto.Migration

  def change do
    # What each row of a finished turn's activity card shows when opened (the
    # input, an excerpt of the output, the error, an edit's patch), keyed by
    # row. Kept apart from the timeline payload so the feed stays light; read
    # only when a row or the activity panel opens.
    create table(:turn_activity_details, primary_key: false) do
      add :event_id,
          references(:timeline_events, type: :string, on_delete: :delete_all),
          primary_key: true

      # row key => %{"input", "output", "output_lines", "truncated", "stderr",
      # "error", "patch", "interrupted"}
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
