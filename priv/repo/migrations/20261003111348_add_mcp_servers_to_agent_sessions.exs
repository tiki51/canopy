defmodule Canopy.Repo.Migrations.AddMcpServersToAgentSessions do
  use Ecto.Migration

  # What the engine last reported about the session's MCP servers (Claude
  # Code's `system/init`), for the repository page.
  def change do
    alter table(:agent_sessions) do
      add :mcp_servers, :map
      add :mcp_servers_seen_at, :utc_datetime_usec
    end
  end
end
