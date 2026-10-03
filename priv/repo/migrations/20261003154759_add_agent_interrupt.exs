defmodule Canopy.Repo.Migrations.AddAgentInterrupt do
  use Ecto.Migration

  def change do
    # A user message sent to interrupt: when it mentions an agent that is
    # working, it reaches that turn at its next step instead of after it.
    # Decided at send time (the setting below, flipped by Alt+Enter).
    alter table(:messages) do
      add :interrupt, :boolean, null: false, default: false
    end

    # Off until the engines' behaviour is verified live (Agent Interrupt plan,
    # Phase 0); with it off, a mention of a working agent waits for its turn.
    alter table(:settings) do
      add :interrupt_on_mention, :boolean, null: false, default: false
    end
  end
end
