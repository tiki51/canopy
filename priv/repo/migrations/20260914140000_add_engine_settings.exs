defmodule Canopy.Repo.Migrations.AddEngineSettings do
  use Ecto.Migration

  # Per-agent Claude Code settings, and the Claude Code section of Settings.
  def change do
    alter table(:agents) do
      add :permission_mode, :string, null: false, default: "default"
      add :effort, :string
      add :allowed_tools, :text
    end

    alter table(:settings) do
      add :claude_binary, :string, null: false, default: "claude"
      add :claude_config_dir, :string
      add :claude_max_budget_usd, :float
    end
  end
end
