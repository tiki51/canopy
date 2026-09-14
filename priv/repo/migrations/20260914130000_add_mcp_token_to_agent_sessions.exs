defmodule Canopy.Repo.Migrations.AddMcpTokenToAgentSessions do
  use Ecto.Migration

  # Claude Code sessions authenticate to the MCP endpoint with their own bearer
  # token, which is how Canopy knows which agent is calling. OpenCode sessions
  # keep using the plugin-stamped session id and leave this null.
  def change do
    alter table(:agent_sessions) do
      add :mcp_token, :string
    end

    create unique_index(:agent_sessions, [:mcp_token])
  end
end
