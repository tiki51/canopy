defmodule Canopy.MCP.IdentityTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.MCP.Identity
  alias Canopy.MCP.Tools.ChannelsList

  setup do
    scenario()
  end

  test "resolves a stamped session id to session, agent, channel, and repository", ctx do
    assert {:ok, identity} =
             Identity.resolve(%{canopy_session_id: ctx.session.opencode_session_id})

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
    assert length(tools) == 14

    for tool <- tools do
      assert %{"properties" => %{"canopy_session_id" => field}} = tool.input_schema
      assert field["type"] == "string"
      assert field["description"] =~ "never fill this in"
      refute "canopy_session_id" in Map.get(tool.input_schema, "required", [])
    end
  end
end
