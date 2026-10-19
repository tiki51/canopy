defmodule Canopy.MCP.SessionIdentityTest do
  @moduledoc "Claude Code sessions: a bearer token per session, resolved by the auth plug and the frame."
  use Canopy.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Canopy.{AgentSessions, Fixtures, MCPHelpers}
  alias Canopy.MCP.{AuthPlug, Identity}
  alias Canopy.MCP.Tools.ChannelsList

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

    {:ok, Map.merge(scenario, %{coder: coder, claude_session: session})}
  end

  defp call_plug(token) do
    :post
    |> conn("/mcp", "")
    |> put_req_header("authorization", "Bearer " <> token)
    |> AuthPlug.call(AuthPlug.init([]))
  end

  test "the settings token authenticates without naming a session" do
    conn = call_plug(Canopy.Settings.mcp_token())
    refute conn.halted
    assert conn.assigns.mcp_authenticated
    refute Map.has_key?(conn.assigns, :canopy_session)
  end

  test "a session token authenticates and assigns the session", ctx do
    conn = call_plug(ctx.claude_session.mcp_token)
    refute conn.halted

    assert conn.assigns.canopy_session == %{
             id: ctx.claude_session.id,
             engine: "claude_code",
             engine_session_id: ctx.claude_session.engine_session_id
           }
  end

  test "a Codex session token assigns the row id, which survives the thread-id rename", ctx do
    codex = Fixtures.agent_fixture(%{engine: "codex"})

    session =
      Fixtures.session_fixture(%{
        channel: ctx.channel,
        agent_id: codex.id,
        engine: "codex",
        engine_session_id: "cx-pending-" <> Ecto.UUID.generate(),
        mcp_token: AgentSessions.generate_mcp_token()
      })

    conn = call_plug(session.mcp_token)
    refute conn.halted
    assert %{id: id, engine: "codex"} = assign = conn.assigns.canopy_session
    assert id == session.id

    # the first turn renames the session to Codex's thread id after the MCP
    # connection was made; the assign it carries still resolves
    thread = Ecto.UUID.generate()
    assert {:ok, ^thread} = AgentSessions.put_engine_session_id(session.id, thread)

    assert {:ok, identity} = Identity.from_frame(%{assigns: %{canopy_session: assign}})
    assert identity.session.id == session.id
    assert identity.session.engine_session_id == thread
    assert identity.agent.id == codex.id
  end

  test "an unknown token is refused" do
    conn = call_plug("nope-" <> AgentSessions.generate_mcp_token())
    assert conn.halted and conn.status == 401
  end

  test "the frame's session wins over any canopy_session_id in the params", ctx do
    frame = %{
      canopy_session: %{
        engine: "claude_code",
        engine_session_id: ctx.claude_session.engine_session_id
      }
    }

    assert {:ok, identity} =
             Identity.resolve(%{canopy_session_id: ctx.session.engine_session_id}, %{
               assigns: frame
             })

    assert identity.agent.id == ctx.coder.id
    assert identity.session.id == ctx.claude_session.id

    # without the assign, the OpenCode path still applies
    assert {:ok, identity} =
             Identity.resolve(%{canopy_session_id: ctx.session.engine_session_id}, %{assigns: %{}})

    assert identity.agent.id == ctx.agent.id
  end

  test "tools run as the session behind the token", ctx do
    assert {:ok, text} = MCPHelpers.call_as_session(ChannelsList, %{}, ctx.claude_session)
    assert text =~ "##{ctx.channel.name}"
  end

  test "sessions without a token get one on demand, and tokens are unique", ctx do
    assert {:ok, %{mcp_token: token}} =
             AgentSessions.ensure_mcp_token(%{ctx.session | mcp_token: nil})

    assert is_binary(token) and byte_size(token) > 20

    assert {:ok, %{mcp_token: ^token}} =
             AgentSessions.ensure_mcp_token(AgentSessions.get!(ctx.session.id))

    assert {:error, changeset} =
             AgentSessions.create(%{
               channel_id: ctx.channel.id,
               agent_id: ctx.coder.id,
               engine: "claude_code",
               engine_session_id: Ecto.UUID.generate(),
               mcp_token: ctx.claude_session.mcp_token,
               parent_session_id: ctx.session.id
             })

    assert %{mcp_token: ["has already been taken"]} = errors_on(changeset)
  end
end
