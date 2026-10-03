defmodule Canopy.MCP.Tools.ReactTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{AgentSessions, Channels, Messages, Repo, Timeline}
  alias Canopy.MCP.Tools.React
  alias Canopy.Messages.Reaction

  setup do
    other = agent_fixture(name: "qa-" <> unique_suffix())
    ctx = scenario(members: [other])
    {:ok, theirs} = Messages.post_agent_message(ctx.channel.id, other.id, "Merged the fix.")
    {:ok, users} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "Ship it?")
    Map.merge(ctx, %{other: other, theirs: theirs, users: users})
  end

  test "adds and removes the caller's reaction, idempotently, waking nobody", ctx do
    Timeline.subscribe(ctx.channel.id)
    id = ctx.theirs.id

    assert {:ok, text} = call(React, %{message: id, emoji: "check"}, ctx)

    assert text ==
             "Reacted ✅ to @#{ctx.other.name}'s message #{id}; nobody was woken. " <>
               "If that was all this message needed, call canopy_pass and end your turn."

    assert [%Reaction{emoji: "check", agent_id: agent_id, user_id: nil}] = Repo.all(Reaction)
    assert agent_id == ctx.agent.id
    assert_receive {:reactions, %{message_id: ^id}}
    # no timeline event: nothing to route
    refute_receive {:timeline, _}, 50

    assert {:ok, again} = call(React, %{message: id, emoji: "check"}, ctx)
    assert again =~ "You had already reacted ✅"
    assert Repo.aggregate(Reaction, :count) == 1

    assert {:ok, removed} = call(React, %{message: id, emoji: "check", remove: true}, ctx)
    assert removed == "Removed your ✅ from @#{ctx.other.name}'s message #{id}; nobody was woken."
    assert Repo.all(Reaction) == []

    assert {:ok, absent} = call(React, %{message: id, emoji: "check", remove: true}, ctx)
    assert absent =~ "You had not reacted ✅"
  end

  test "the glyph works for the key, and the user's message is named by display name", ctx do
    assert {:ok, text} = call(React, %{message: ctx.users.id, emoji: "👍"}, ctx)
    assert text =~ "Reacted 👍 to #{ctx.user.display_name}'s message #{ctx.users.id}"
    assert [%Reaction{emoji: "thumbs_up"}] = Repo.all(Reaction)
  end

  test "refuses unknown emoji, own messages, system notes, and archived channels", ctx do
    assert {:error, reason} = call(React, %{message: ctx.theirs.id, emoji: "fire"}, ctx)
    assert reason =~ "unknown emoji"
    assert reason =~ "thumbs_up, check, eyes, tada, heart"

    {:ok, own} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "My report.")
    assert {:error, reason} = call(React, %{message: own.id, emoji: "check"}, ctx)
    assert reason =~ "your own message"

    {:ok, note} = Messages.post_user_note(ctx.channel.id, ctx.user.id, "handed off")
    assert {:error, reason} = call(React, %{message: note.id, emoji: "check"}, ctx)
    assert reason =~ "system note"

    {:ok, _} = Channels.archive(ctx.channel)
    assert {:error, reason} = call(React, %{message: ctx.theirs.id, emoji: "check"}, ctx)
    assert reason =~ "archived"

    assert Repo.all(Reaction) == []
  end

  test "refuses messages outside the caller's channels and repository", ctx do
    private =
      channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.other.id,
        name: "private-" <> unique_suffix()
      })

    {:ok, hidden} = Messages.post_agent_message(private.id, ctx.other.id, "not for you")
    assert {:error, reason} = call(React, %{message: hidden.id, emoji: "check"}, ctx)
    assert reason == "not a member of ##{private.name}"

    elsewhere = channel_fixture(%{owner_agent_id: ctx.other.id})
    {:ok, far} = Messages.post_agent_message(elsewhere.id, ctx.other.id, "other repo")
    assert {:error, "unknown message"} = call(React, %{message: far.id, emoji: "check"}, ctx)

    assert {:error, reason} = call(React, %{message: "msg_missing", emoji: "check"}, ctx)
    assert reason =~ "unknown message"

    assert Repo.all(Reaction) == []
  end

  test "the reactor is the session behind the token, whatever canopy_session_id says", ctx do
    coder = agent_fixture(%{engine: "claude_code"})
    {:ok, _} = Channels.add_agent(ctx.channel, coder)

    claude_session =
      session_fixture(%{
        channel: ctx.channel,
        agent_id: coder.id,
        engine: "claude_code",
        engine_session_id: Ecto.UUID.generate(),
        mcp_token: AgentSessions.generate_mcp_token()
      })

    # the params name the owner's OpenCode session; the frame's session wins
    assert {:ok, _} =
             call_as_session(
               React,
               %{
                 "message" => ctx.theirs.id,
                 "emoji" => "eyes",
                 "canopy_session_id" => ctx.session.engine_session_id
               },
               claude_session
             )

    assert [%Reaction{agent_id: agent_id}] = Repo.all(Reaction)
    assert agent_id == coder.id
  end
end
