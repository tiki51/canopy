defmodule Canopy.Repo.Migrations.AddPlaybookSharingSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # owner/name; nil = sharing not set up
      add :playbook_repo, :string
      # nil = the repository's default branch
      add :playbook_branch, :string
      # "" = the repository root
      add :playbook_folder, :string, default: "playbooks"
    end
  end
end
