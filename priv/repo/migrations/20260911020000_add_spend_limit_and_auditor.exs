defmodule Canopy.Repo.Migrations.AddSpendLimitAndAuditor do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      # total dollars the channel may spend, set by the user (or an agent at
      # creation); nil for no limit
      add :spend_limit, :float
    end

    alter table(:settings) do
      # the agent asked to review spend from the Costs page
      add :auditor_agent_id, :string
    end
  end
end
