defmodule Canopy.Repo.Migrations.AddLastReactionIdToMessageReads do
  use Ecto.Migration

  def change do
    # The newest reaction an agent has seen in a channel through
    # `messages_read`; reactions on older messages are listed after it.
    alter table(:message_reads) do
      add :last_reaction_id, :string
    end
  end
end
