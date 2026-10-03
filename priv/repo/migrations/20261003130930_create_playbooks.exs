defmodule Canopy.Repo.Migrations.CreatePlaybooks do
  use Ecto.Migration

  def change do
    # The library: one Markdown text per playbook (frontmatter included), global
    # to Canopy. `name` and `description` are copied out of the text on save.
    create table(:playbooks, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :string, null: false
      add :body, :text, null: false
      add :enabled, :boolean, null: false, default: true
      # seed | user | agent (an agent's draft, disabled until the user enables it)
      add :source, :string, null: false, default: "user"
      add :created_by_agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      # bumped on every write: enabling approves the text the user saw, and an
      # agent replaces its draft only if nobody touched it since
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:playbooks, [:name])

    create table(:playbook_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :playbook_id, references(:playbooks, type: :string, on_delete: :nilify_all)
      add :playbook_name, :string, null: false
      # the playbook's text when the run started; editing the playbook never moves a run
      add :definition, :text, null: false
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false
      add :coordinator_agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      # nil: the user started it
      add :started_by_agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      add :brief, :text, null: false
      # role => agent id, resolved at start
      add :roster, :map, null: false, default: %{}
      add :status, :string, null: false
      add :current_step, :string
      # for watch-started runs: the schedule, the item key, its url
      add :trigger, :map
      add :outcome, :text
      add :finished_at, :utc_datetime_usec
      # stall nudges: the minutes a step may go quiet (nil: never nudged),
      # the last step change, delegation update, or coordinator turn, and
      # when the current stall was nudged (nil until it is)
      add :stall_after_minutes, :integer
      add :last_activity_at, :utc_datetime_usec
      add :nudged_at, :utc_datetime_usec
      # optimistic locking: a transition commits only against the state it read
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    # One active run per channel: the run is never ambiguous, and two
    # concurrent starts cannot both win.
    create unique_index(:playbook_runs, [:channel_id],
             where: "status IN ('active', 'awaiting_approval')"
           )

    create index(:playbook_runs, [:playbook_id])
    create index(:playbook_runs, [:coordinator_agent_id])

    create table(:playbook_steps, primary_key: false) do
      add :id, :string, primary_key: true

      add :run_id, references(:playbook_runs, type: :string, on_delete: :delete_all), null: false

      add :step_id, :string, null: false
      add :position, :integer, null: false
      add :title, :string, null: false
      # the step's owner roles as written, and the agents they resolved to
      add :owner_roles, {:array, :string}, null: false, default: []
      add :owner_ids, {:array, :string}, null: false, default: []
      add :approval, :boolean, null: false, default: false
      add :optional, :boolean, null: false, default: false
      add :status, :string, null: false, default: "pending"
      # incremented each time the step is entered again
      add :round, :integer, null: false, default: 0
      add :result, :text
      # an approval step: where the coordinator asked to go once it is approved
      add :approval_next, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :approved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:playbook_steps, [:run_id, :step_id])

    # A delegation made for a step of a run; the panel lists them under it.
    alter table(:delegations) do
      add :playbook_step_id, references(:playbook_steps, type: :string, on_delete: :nilify_all)
    end

    create index(:delegations, [:playbook_step_id])
  end
end
