defmodule Canopy.Repo.Migrations.AddPlaybookStarsAndRunKickoff do
  use Ecto.Migration

  # `playbooks.starred_at`: the user's star for the library's Starred section
  # (nil: not starred). `playbook_runs.kickoff_message_id`: the user's post
  # that carries the brief and its files when a run starts with files.
  def change do
    alter table(:playbooks) do
      add :starred_at, :utc_datetime_usec
    end

    alter table(:playbook_runs) do
      add :kickoff_message_id, references(:messages, type: :string, on_delete: :nilify_all)
    end
  end
end
