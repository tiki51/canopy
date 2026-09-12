defmodule Canopy.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :string, primary_key: true
      add :filename, :string, null: false
      add :mime, :string, null: false
      add :kind, :string, null: false
      add :byte_size, :integer, null: false
      add :sha256, :string, null: false
      add :caption, :string

      add :user_id, references(:users, type: :string, on_delete: :nilify_all)

      # SQLite cannot add constraints after the fact, so the uploader rule is
      # declared inline: exactly one of agent_id / user_id must be set.
      add :agent_id, references(:agents, type: :string, on_delete: :nilify_all),
        check: %{
          name: "documents_uploader_check",
          expr: "(agent_id IS NULL) <> (user_id IS NULL)"
        }

      add :origin_channel_id, references(:channels, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:documents, [:inserted_at])
    create index(:documents, [:sha256])
    create index(:documents, [:origin_channel_id])
    create index(:documents, [:kind])
  end
end
