defmodule Canopy.MCP.Tools.PermissionGlobalEdgesTest do
  @moduledoc "Claude Code's permission prompt when the agent has a session Always and a grant."
  use Canopy.DataCase, async: false

  alias Canopy.{AgentSessions, Fixtures, GlobalPermissions, PermissionRequests, Runtime, Timeline}
  alias Canopy.ClaudeCode.Prompts
  alias Canopy.MCP.Tools.Permission
  alias Canopy.MCPHelpers

  setup do
    coder = Fixtures.agent_fixture(%{engine: "claude_code"})
    scenario = Fixtures.scenario(members: [coder])

    session =
      Fixtures.session_fixture(%{
        channel: scenario.channel,
        agent_id: coder.id,
        engine: "claude_code",
        engine_session_id: Ecto.UUID.generate(),
        mcp_token: AgentSessions.generate_mcp_token()
      })

    Timeline.subscribe(scenario.channel.id)
    {:ok, _} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{coder: coder, claude_session: session})}
  end

  test "a session Always answers first; the grant is not counted", ctx do
    {:ok, _} = GlobalPermissions.grant(ctx.coder.id, "Bash")
    :ok = Prompts.allow_always(ctx.claude_session.engine_session_id, "Bash")

    assert {:ok, text} =
             MCPHelpers.call_as_session(
               Permission,
               %{tool_name: "Bash", input: %{"command" => "ls"}, tool_use_id: "toolu_aw"},
               ctx.claude_session
             )

    assert %{"behavior" => "allow"} = JSON.decode!(text)
    refute_receive {:timeline, %{event_type: "permission_auto_approved"}}, 200
    assert GlobalPermissions.get(ctx.coder.id, "bash").use_count == 0
    assert PermissionRequests.pending_for_channel(ctx.channel.id) == []
  end
end
