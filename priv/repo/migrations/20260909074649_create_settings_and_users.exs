defmodule Canopy.Repo.Migrations.CreateSettingsAndUsers do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :id, :string, primary_key: true
      add :opencode_url, :string, null: false, default: "http://127.0.0.1:4096"
      add :user_display_name, :string, null: false, default: "You"
      add :mcp_token, :string, null: false
      add :plugin_verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create table(:users, primary_key: false) do
      add :id, :string, primary_key: true
      add :display_name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
