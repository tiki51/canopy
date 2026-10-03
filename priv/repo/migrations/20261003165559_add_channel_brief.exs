defmodule Canopy.Repo.Migrations.AddChannelBrief do
  use Ecto.Migration

  def change do
    # Standing context for everyone in the channel, in every agent's system
    # text. Changed only through `Canopy.Channels.set_brief/3`, which records
    # `brief_updated`; the versions live in those events.
    alter table(:channels) do
      add :brief, :text
      add :brief_updated_at, :utc_datetime_usec
      # "user" or an agent id
      add :brief_updated_by, :string
    end

    # When the session was last prompted with the channel's brief as it stood
    # then, so a session that had turns before an edit is told it changed.
    alter table(:agent_sessions) do
      add :brief_seen_at, :utc_datetime_usec
    end
  end
end
