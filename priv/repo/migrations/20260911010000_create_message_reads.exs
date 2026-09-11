defmodule Canopy.Repo.Migrations.CreateMessageReads do
  use Ecto.Migration

  def change do
    create table(:message_reads, primary_key: false) do
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), primary_key: true

      add :channel_id, references(:channels, type: :string, on_delete: :delete_all),
        primary_key: true

      add :last_message_id, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
