defmodule Canopy.Repo.Migrations.AddSharingToPlaybooks do
  use Ecto.Migration

  def change do
    alter table(:playbooks) do
      # the number users see; lock_version stays the edit guard
      add :version, :integer, null: false, default: 1
      # the GitHub copy this playbook follows, as of the last import or merged export
      add :origin_repo, :string
      add :origin_path, :string
      add :origin_version, :integer
      add :origin_sha, :string
      add :origin_body, :text
      add :synced_at, :utc_datetime_usec
      # the open export PR, if any (cleared when it merges or closes)
      add :pr_number, :integer
      add :pr_url, :string
      add :pr_path, :string
      add :pr_version, :integer
      add :pr_sha, :string
      add :pr_body, :text
    end

    create index(:playbooks, [:origin_repo, :origin_path])
  end
end
