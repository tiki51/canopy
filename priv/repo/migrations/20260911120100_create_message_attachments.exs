defmodule Canopy.Repo.Migrations.CreateMessageAttachments do
  use Ecto.Migration

  def change do
    create table(:message_attachments, primary_key: false) do
      add :message_id, references(:messages, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :document_id, references(:documents, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :position, :integer, null: false, default: 0
    end

    create unique_index(:message_attachments, [:message_id, :document_id])
    create index(:message_attachments, [:document_id])
  end
end
