defmodule Canopy.Repo.Migrations.CreateChannelSections do
  use Ecto.Migration

  # Sidebar sections (`Canopy.Channels.Sections`): named groups of a project's
  # channels, in the user's order. Purely additive: existing channels get no
  # section (the top of the project) and no dismissed archive offer.

  def change do
    create table(:channel_sections, primary_key: false) do
      add :id, :string, primary_key: true

      add :repository_id, references(:repositories, type: :string, on_delete: :delete_all),
        null: false

      # uniqueness and lookup ignore (ASCII) case
      add :name, :string, null: false, collate: :nocase
      # 0-based, contiguous per repository
      add :position, :integer, null: false, default: 0
      add :collapsed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channel_sections, [:repository_id, :name])
    # not unique: positions are renumbered in place
    create index(:channel_sections, [:repository_id, :position])

    alter table(:channels) do
      add :section_id, references(:channel_sections, type: :string, on_delete: :nilify_all)
      add :archive_offer_dismissed_at, :utc_datetime_usec
    end

    create index(:channels, [:section_id])
  end
end
