defmodule Canopy.Repo.Migrations.CreateChannelReads do
  use Ecto.Migration

  def change do
    create table(:channel_reads, primary_key: false) do
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :string, on_delete: :delete_all), primary_key: true
      add :last_read_at, :utc_datetime_usec, null: false
    end
  end
end
