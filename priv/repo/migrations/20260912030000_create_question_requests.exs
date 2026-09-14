defmodule Canopy.Repo.Migrations.CreateQuestionRequests do
  use Ecto.Migration

  def change do
    create table(:question_requests, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :agent_session_id,
          references(:agent_sessions, type: :string, on_delete: :delete_all),
          null: false

      add :opencode_question_id, :string, null: false
      add :questions, {:array, :map}, null: false, default: "[]"
      add :answers, {:array, {:array, :string}}, null: false, default: "[]"
      add :tool_call_id, :string
      add :status, :string, null: false, default: "pending"
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:question_requests, [:opencode_question_id])
    create index(:question_requests, [:channel_id, :status])
    create index(:question_requests, [:agent_session_id])
  end
end
