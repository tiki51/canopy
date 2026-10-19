defmodule Canopy.MCP.IdentityTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.AgentSessions
  alias Canopy.MCP.Identity
  alias Canopy.MCP.Tools.ChannelsList

  setup do
    scenario()
  end

  test "resolves a stamped session id to session, agent, channel, and repository", ctx do
    assert {:ok, identity} =
             Identity.resolve(%{canopy_session_id: ctx.session.engine_session_id})

    assert identity.session.id == ctx.session.id
    assert identity.agent.id == ctx.agent.id
    assert identity.channel.id == ctx.channel.id
    assert identity.repository.id == ctx.repository.id
  end

  test "rejects unknown and missing session ids" do
    message = Identity.unknown_session_message()
    assert {:error, ^message} = Identity.resolve(%{canopy_session_id: "ses_nope"})
    assert {:error, ^message} = Identity.resolve(%{canopy_session_id: ""})
    assert {:error, ^message} = Identity.resolve(%{})
    assert {:error, ^message} = Identity.resolve_session_id(nil)
  end

  describe "a session-authenticated frame" do
    test "with the row id, resolves by id even after the engine session id changed", ctx do
      assign = %{
        id: ctx.session.id,
        engine: ctx.session.engine,
        engine_session_id: ctx.session.engine_session_id
      }

      renamed = "thread-" <> Ecto.UUID.generate()
      assert {:ok, ^renamed} = AgentSessions.put_engine_session_id(ctx.session.id, renamed)

      for resolve <- [
            &Identity.from_frame(%{assigns: %{canopy_session: &1}}),
            &Identity.resolve(%{canopy_session_id: "ses_forged"}, %{
              assigns: %{canopy_session: &1}
            })
          ] do
        assert {:ok, identity} = resolve.(assign)
        assert identity.session.id == ctx.session.id
        assert identity.session.engine_session_id == renamed
        assert identity.agent.id == ctx.agent.id
        assert identity.channel.id == ctx.channel.id
        assert identity.repository.id == ctx.repository.id
      end

      # the old engine id alone no longer resolves
      message = Identity.unknown_session_message()

      assert {:error, ^message} =
               Identity.from_frame(%{
                 assigns: %{
                   canopy_session: %{
                     engine: assign.engine,
                     engine_session_id: assign.engine_session_id
                   }
                 }
               })
    end

    test "without the row id, resolves by engine and engine session id as before", ctx do
      assign = %{engine: ctx.session.engine, engine_session_id: ctx.session.engine_session_id}

      assert {:ok, identity} = Identity.from_frame(%{assigns: %{canopy_session: assign}})
      assert identity.session.id == ctx.session.id
      assert identity.agent.id == ctx.agent.id
    end

    test "an unknown row id or an empty assign is refused" do
      message = Identity.unknown_session_message()

      assert {:error, ^message} =
               Identity.from_frame(%{assigns: %{canopy_session: %{id: Ecto.UUID.generate()}}})

      assert {:error, ^message} = Identity.from_frame(%{assigns: %{canopy_session: %{}}})
      assert {:error, ^message} = Identity.from_frame(%{assigns: %{}})
    end
  end

  test "tools refuse calls without a resolvable session before doing any work" do
    assert {:error, message} = execute(ChannelsList, %{})
    assert message =~ "unknown Canopy session"
    assert message =~ "plugin installed"

    assert {:error, message} = execute(ChannelsList, %{canopy_session_id: "ses_forged"})
    assert message =~ "unknown Canopy session"
  end

  test "every tool declares the optional canopy_session_id field" do
    tools = Canopy.MCP.Server.__components__(:tool)
    assert Enum.sort(Enum.map(tools, & &1.name)) == Enum.sort(Canopy.MCP.Server.tool_names())
    assert length(tools) == length(Canopy.MCP.Server.tool_names())

    # the permission tool is called by Claude Code itself and takes its
    # identity from the connection, never from a parameter
    for tool <- tools, tool.name != "permission" do
      assert %{"properties" => %{"canopy_session_id" => field}} = tool.input_schema
      assert field["type"] == "string"
      assert field["description"] =~ "never fill this in"
      refute "canopy_session_id" in Map.get(tool.input_schema, "required", [])
    end
  end
end
