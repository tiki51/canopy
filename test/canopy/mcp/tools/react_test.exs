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

  test "an alias works for the key", ctx do
    assert {:ok, text} = call(React, %{message: ctx.theirs.id, emoji: "thanks"}, ctx)
    assert text =~ "Reacted 🙏 to @#{ctx.other.name}'s message #{ctx.theirs.id}"
    assert [%Reaction{emoji: "pray"}] = Repo.all(Reaction)
  end

  test "the description and the emoji field list the palette as it is" do
    expected = """
    React to someone else's message with an emoji, to acknowledge it without
    waking anyone. Work reactions answer someone: thumbs_up 👍 agree / sounds
    good, check ✅ done / approved, eyes 👀 looking at it, rocket 🚀 shipped /
    merged, hundred 💯 exactly right. Thanks & cheers set the tone: pray 🙏
    thank you, heart ❤️ love it, tada 🎉 celebrate, raised_hands 🙌 great work,
    fire 🔥 impressive, laughing 😂 that's funny, smile 😊 glad / happy.
    A reaction is never an instruction and starts no turn for anyone; use it
    instead of posting an acknowledgement. If that was all the message needed,
    call canopy_pass afterwards. `remove` takes your reaction back.
    """

    # the spec's wording, with its line wraps collapsed
    assert React.description() == expected |> String.replace(~r/\s+/, " ") |> String.trim()

    assert %{"properties" => %{"emoji" => %{"description" => emoji}}} = React.input_schema()

    assert emoji ==
             "A palette key: thumbs_up, check, eyes, rocket, hundred, pray, heart, tada, " <>
               "raised_hands, fire, laughing, smile (the emoji itself works too)."
  end

  test "refuses unknown emoji, own messages, system notes, and archived channels", ctx do
    assert {:error, reason} = call(React, %{message: ctx.theirs.id, emoji: "thumbs_down"}, ctx)
    assert reason =~ "unknown emoji"

    assert reason =~
             "thumbs_up, check, eyes, rocket, hundred, pray, heart, tada, raised_hands, fire, laughing, smile"

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

  describe "more emojis" do
    test "every input form of one key reacts once: key, alias, wrapped, glyph, any case", ctx do
      id = ctx.theirs.id
      assert {:ok, first} = call(React, %{message: id, emoji: "hundred"}, ctx)
      assert first =~ "Reacted 💯"

      for form <- ["100", ":100:", "💯", "Hundred"] do
        assert {:ok, again} = call(React, %{message: id, emoji: form}, ctx)
        assert again =~ "You had already reacted 💯", form
      end

      assert [%Reaction{emoji: "hundred"}] = Repo.all(Reaction)
    end

    test "remove takes an alias; ❤ without VS16 stores heart and replies with the palette glyph",
         ctx do
      id = ctx.theirs.id
      assert {:ok, _} = call(React, %{message: id, emoji: "laughing"}, ctx)
      assert {:ok, removed} = call(React, %{message: id, emoji: "lol", remove: true}, ctx)
      assert removed =~ "Removed your 😂"
      assert Repo.all(Reaction) == []

      assert {:ok, text} = call(React, %{message: id, emoji: "❤"}, ctx)
      assert text =~ "Reacted ❤️ to"
      assert [%Reaction{emoji: "heart"}] = Repo.all(Reaction)
    end

    test "the unknown-emoji error lists the 12 keys and no alias; group names are unknown", ctx do
      for value <- ["thumbs_down", "work", "cheer", "👍🏽"] do
        assert {:error, reason} = call(React, %{message: ctx.theirs.id, emoji: value}, ctx)

        assert reason ==
                 "unknown emoji #{inspect(value)}; use one of: thumbs_up, check, eyes, rocket, " <>
                   "hundred, pray, heart, tada, raised_hands, fire, laughing, smile"
      end
    end

    test "new keys get the same refusals on system notes and archived channels", ctx do
      {:ok, note} = Messages.post_user_note(ctx.channel.id, ctx.user.id, "handed off")
      assert {:error, reason} = call(React, %{message: note.id, emoji: "fire"}, ctx)
      assert reason =~ "system note"

      {:ok, _} = Channels.archive(ctx.channel)
      assert {:error, reason} = call(React, %{message: ctx.theirs.id, emoji: "thanks"}, ctx)
      assert reason =~ "archived"
      assert Repo.all(Reaction) == []
    end

    test "Anubis serves description/0, not the moduledoc" do
      assert Anubis.Server.Component.get_description(React) == React.description()
      assert React.description() =~ "Thanks & cheers set the tone: pray 🙏 thank you"
    end
  end
end
