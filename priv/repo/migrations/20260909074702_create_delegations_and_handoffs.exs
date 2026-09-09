defmodule Canopy.Repo.Migrations.CreateDelegationsAndHandoffs do
  use Ecto.Migration

  def change do
    create table(:delegations, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :task_id, references(:tasks, type: :string, on_delete: :nilify_all)
      add :from_agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      add :to_agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      add :parent_session_id,
          references(:agent_sessions, type: :string, on_delete: :nilify_all)

      add :child_session_id,
          references(:agent_sessions, type: :string, on_delete: :nilify_all)

      add :description, :text, null: false
      add :status, :string, null: false, default: "requested"
      add :result, :text
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:delegations, [:channel_id, :status])
    create index(:delegations, [:to_agent_id, :status])
    create index(:delegations, [:child_session_id])

    create table(:handoffs, primary_key: false) do
      add :id, :string, primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false

      add :task_id, references(:tasks, type: :string, on_delete: :nilify_all)
      add :from_agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      add :to_agent_id, references(:agents, type: :string, on_delete: :nilify_all)

      add :source_session_id,
          references(:agent_sessions, type: :string, on_delete: :nilify_all)

      add :target_session_id,
          references(:agent_sessions, type: :string, on_delete: :nilify_all)

      add :status, :string, null: false, default: "requested"
      add :summary, :text, null: false
      add :reason, :text
      add :suggested_next_step, :text
      add :rejection_reason, :text
      add :packet, :map, null: false, default: "{}"
      add :accepted_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:handoffs, [:channel_id, :status])
    create index(:handoffs, [:to_agent_id, :status])
  end
end
