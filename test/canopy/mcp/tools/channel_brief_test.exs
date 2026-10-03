defmodule Canopy.MCP.Tools.ChannelBriefTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Channels, Timeline}
  alias Canopy.MCP.Tools.ChannelBriefSet

  setup do
    member = agent_fixture(name: "member-" <> unique_suffix())
    ctx = scenario(members: [member])
    member_session = session_fixture(%{channel: ctx.channel, agent_id: member.id})
    Map.merge(ctx, %{member: member, member_session: member_session})
  end

  test "the owner sets the brief; the event is credited to the caller", ctx do
    Timeline.subscribe(ctx.channel.id)

    assert {:ok, text} = call(ChannelBriefSet, %{text: "Goal: stop double charges."}, ctx)

    assert text ==
             "brief updated (26 chars, ≈7 tokens); every agent in ##{ctx.channel.name} gets it from their next prompt."

    assert Channels.get!(ctx.channel.id).brief == "Goal: stop double charges."
    agent_id = ctx.agent.id

    assert_receive {:timeline,
                    %{
                      event_type: "brief_updated",
                      agent_id: ^agent_id,
                      payload: %{"by" => ^agent_id}
                    }}
  end

  test "the identity comes from the session, whatever the params say", ctx do
    # a member that claims nothing still is who its session says
    assert {:error, reason} =
             call(ChannelBriefSet, %{text: "Mine now."}, ctx.member_session)

    assert reason =~
             "only the owner of ##{ctx.channel.name}, @#{ctx.agent.name}, can change the brief"

    assert {:error, _} =
             call_as_session(ChannelBriefSet, %{"text" => "Mine now."}, ctx.member_session)

    assert Channels.get!(ctx.channel.id).brief == nil
  end

  test "blank text is refused: only the user clears a brief", ctx do
    {:ok, _} = Channels.set_brief(ctx.channel, "Keep me.", "user")
    assert {:error, reason} = call(ChannelBriefSet, %{text: "   "}, ctx)
    assert reason =~ "only the user can clear a brief"
    assert Channels.get!(ctx.channel.id).brief == "Keep me."
  end

  test "too long is refused with the cap and the length", ctx do
    assert {:error, reason} = call(ChannelBriefSet, %{text: String.duplicate("x", 4_001)}, ctx)
    assert reason =~ "the brief is 4001 characters; the limit is 4000"
    assert Channels.get!(ctx.channel.id).brief == nil
  end

  test "an archived channel is refused", ctx do
    {:ok, _} = Channels.archive(ctx.channel)
    assert {:error, reason} = call(ChannelBriefSet, %{text: "Late."}, ctx)
    assert reason =~ "is archived"
  end

  test "channel: targets another channel the caller owns, not one it only belongs to", ctx do
    owned =
      channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.agent.id,
        name: "owned-" <> unique_suffix()
      })

    assert {:ok, text} = call(ChannelBriefSet, %{text: "Over there.", channel: owned.name}, ctx)
    assert text =~ "##{owned.name}"
    assert Channels.get!(owned.id).brief == "Over there."
    assert Channels.get!(ctx.channel.id).brief == nil

    theirs =
      channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.member.id,
        agent_ids: [ctx.agent.id],
        name: "theirs-" <> unique_suffix()
      })

    assert {:error, reason} = call(ChannelBriefSet, %{text: "No.", channel: theirs.id}, ctx)
    assert reason =~ "only the owner of ##{theirs.name}, @#{ctx.member.name}"
  end

  test "is registered as canopy_channel_brief_set" do
    assert "channel_brief_set" in Canopy.MCP.Server.tool_names()
  end
end
