defmodule Canopy.ReactionsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Channels, Messages, Reactions, Repo, Timeline}
  alias Canopy.Messages.Reaction

  setup do
    other = agent_fixture(name: "qa-" <> unique_suffix())
    ctx = scenario(members: [other])
    {:ok, post} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "Ship it after CI?")
    Map.merge(ctx, %{other: other, post: post})
  end

  test "the palette is the fixed twelve, and a key, alias or glyph resolves to its key" do
    assert Reactions.keys() ==
             ~w(thumbs_up check eyes rocket hundred pray heart tada raised_hands fire laughing smile)

    assert Reactions.resolve_key("check") == "check"
    assert Reactions.resolve_key("✅") == "check"
    assert Reactions.resolve_key("❤️") == "heart"
    assert Reactions.resolve_key("❤") == "heart"
    assert Reactions.resolve_key(":eyes:") == "eyes"
    assert Reactions.resolve_key("🔥") == "fire"
    assert Reactions.resolve_key("💯") == "hundred"

    # aliases are input only; keys and aliases match in any case
    assert Reactions.resolve_key("thanks") == "pray"
    assert Reactions.resolve_key("+1") == "thumbs_up"
    assert Reactions.resolve_key("100") == "hundred"
    assert Reactions.resolve_key("joy") == "laughing"
    assert Reactions.resolve_key("love") == "heart"
    assert Reactions.resolve_key(" :LOL: ") == "laughing"
    assert Reactions.resolve_key("Check") == "check"

    assert Reactions.resolve_key("👎") == nil
    assert Reactions.resolve_key("thumbs_down") == nil
    assert Reactions.resolve_key(nil) == nil
  end

  test "aliases never shadow a key, always name a real one, and are lowercase" do
    aliases = Reactions.aliases()
    keys = Reactions.keys()

    assert MapSet.disjoint?(MapSet.new(Map.keys(aliases)), MapSet.new(keys))
    assert Enum.all?(Map.values(aliases), &(&1 in keys))
    assert Enum.all?(Map.keys(aliases) ++ keys, &(&1 == String.downcase(&1)))
  end

  test "groups/0 splits the palette into work, then thanks & cheers" do
    assert [{:work, "Work", work}, {:cheer, "Thanks & cheers", cheer}] = Reactions.groups()
    assert Enum.map(work, & &1.key) == ~w(thumbs_up check eyes rocket hundred)
    assert Enum.map(cheer, & &1.key) == ~w(pray heart tada raised_hands fire laughing smile)
    assert work ++ cheer == Reactions.palette()

    for {group, _name, entries} <- Reactions.groups(), entry <- entries do
      assert entry.group == group
    end

    # the picker's heading ids (`<picker>-work`) share the per-key button ids' prefix
    group_names = for {group, _name, _entries} <- Reactions.groups(), do: Atom.to_string(group)
    assert MapSet.disjoint?(MapSet.new(group_names), MapSet.new(Reactions.keys()))
  end

  test "toggle adds, then removes, broadcasting each change with the thread", ctx do
    Timeline.subscribe(ctx.channel.id)
    user = {:user, ctx.user.id}
    post_id = ctx.post.id
    channel_id = ctx.channel.id

    assert {:ok, :added} = Reactions.toggle(post_id, user, "check")

    assert_receive {:reactions, %{channel_id: ^channel_id, message_id: ^post_id, thread_id: nil}}

    assert [%Reaction{emoji: "check", user_id: user_id}] = Repo.all(Reaction)
    assert user_id == ctx.user.id

    assert {:ok, :removed} = Reactions.toggle(post_id, user, "check")
    assert_receive {:reactions, %{message_id: ^post_id}}
    assert Repo.all(Reaction) == []
  end

  test "add and remove are idempotent and broadcast only on change", ctx do
    Timeline.subscribe(ctx.channel.id)
    agent = {:agent, ctx.other.id}

    assert {:ok, :added} = Reactions.add(ctx.post.id, agent, "eyes")
    assert_receive {:reactions, _}
    assert {:ok, :exists} = Reactions.add(ctx.post.id, agent, "eyes")
    refute_receive {:reactions, _}, 50

    assert {:ok, :removed} = Reactions.remove(ctx.post.id, agent, "eyes")
    assert_receive {:reactions, _}
    assert {:ok, :absent} = Reactions.remove(ctx.post.id, agent, "eyes")
    refute_receive {:reactions, _}, 50
  end

  test "the user and an agent can both react with the same emoji; each only once", ctx do
    assert {:ok, :added} = Reactions.add(ctx.post.id, {:user, ctx.user.id}, "check")
    assert {:ok, :added} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "check")
    assert Repo.aggregate(Reaction, :count) == 2

    # each partial unique index rejects a duplicate row written past the context
    for reactor <- [%{user_id: ctx.user.id}, %{agent_id: ctx.other.id}] do
      attrs =
        Map.merge(reactor, %{message_id: ctx.post.id, channel_id: ctx.channel.id, emoji: "check"})

      assert {:error, changeset} = Repo.insert(Reaction.changeset(%Reaction{}, attrs))
      assert changeset.errors != []
    end

    assert Repo.aggregate(Reaction, :count) == 2
  end

  test "a reaction needs exactly one reactor", ctx do
    attrs = %{message_id: ctx.post.id, channel_id: ctx.channel.id, emoji: "check"}
    refute Reaction.changeset(%Reaction{}, attrs).valid?

    refute Reaction.changeset(
             %Reaction{},
             Map.merge(attrs, %{user_id: ctx.user.id, agent_id: ctx.other.id})
           ).valid?
  end

  test "unknown emoji, system notes, archived channels and missing messages are refused", ctx do
    user = {:user, ctx.user.id}
    assert {:error, :unknown_emoji} = Reactions.add(ctx.post.id, user, "thumbs_down")
    assert {:error, :not_found} = Reactions.add("msg_missing", user, "check")

    {:ok, note} = Messages.post_user_note(ctx.channel.id, ctx.user.id, "handed off")
    assert {:error, :system_message} = Reactions.toggle(note.id, user, "check")

    {:ok, _} = Channels.archive(ctx.channel)
    assert {:error, :archived} = Reactions.toggle(ctx.post.id, user, "check")
    assert Repo.all(Reaction) == []
  end

  test "a reaction on a thread reply broadcasts the thread's root", ctx do
    Timeline.subscribe(ctx.channel.id)
    {:ok, reply} = Messages.thread_reply(ctx.post.id, {:agent, ctx.other.id}, "On it.")
    root_id = ctx.post.id
    reply_id = reply.id

    assert {:ok, :added} = Reactions.add(reply.id, {:user, ctx.user.id}, "thumbs_up")
    assert_receive {:reactions, %{message_id: ^reply_id, thread_id: ^root_id}}
  end

  test "group/1 follows palette order, counts, and marks the user's own", ctx do
    {:ok, _} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "fire")
    {:ok, _} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "eyes")
    {:ok, _} = Reactions.add(ctx.post.id, {:user, ctx.user.id}, "check")
    {:ok, _} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "check")

    message = Messages.get!(ctx.post.id)

    assert [
             %{key: "check", glyph: "✅", count: 2, user?: true, agent_ids: [other_id]},
             %{key: "eyes", count: 1, user?: false},
             %{key: "fire", glyph: "🔥", group: :cheer, count: 1}
           ] = Reactions.group(message.reactions)

    assert other_id == ctx.other.id
    assert Reactions.group([]) == []
    assert Reactions.group(%Ecto.Association.NotLoaded{}) == []
  end

  test "since/3 respects the cursor, exclude_agent, except_messages and limit", ctx do
    {:ok, older} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "older")
    {:ok, _} = Reactions.add(ctx.post.id, {:user, ctx.user.id}, "check")
    cursor = Reactions.newest_id(ctx.channel.id)

    {:ok, _} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "eyes")
    {:ok, _} = Reactions.add(older.id, {:agent, ctx.agent.id}, "thumbs_up")
    {:ok, _} = Reactions.add(older.id, {:agent, ctx.other.id}, "tada")

    assert ctx.channel.id |> Reactions.since(nil) |> length() == 4

    assert ["eyes", "thumbs_up", "tada"] =
             ctx.channel.id |> Reactions.since(cursor) |> Enum.map(& &1.emoji)

    assert ["eyes", "tada"] =
             ctx.channel.id
             |> Reactions.since(cursor, exclude_agent: ctx.agent.id)
             |> Enum.map(& &1.emoji)

    assert ["eyes"] =
             ctx.channel.id
             |> Reactions.since(cursor, except_messages: [older.id])
             |> Enum.map(& &1.emoji)

    # the newest ones are kept, oldest first
    assert [%{emoji: "thumbs_up"}, %{emoji: "tada", message: %{body: "older"}}] =
             Reactions.since(ctx.channel.id, cursor, limit: 2)
  end

  test "deleting a message deletes its reactions", ctx do
    {:ok, _} = Reactions.add(ctx.post.id, {:user, ctx.user.id}, "check")
    Repo.delete!(Repo.get!(Messages.Message, ctx.post.id))
    assert Repo.all(Reaction) == []
    assert Reactions.newest_id(ctx.channel.id) == nil
  end

  describe "more emojis: palette, aliases and edge cases" do
    @palette [
      {"thumbs_up", "👍", "agree / sounds good", :work},
      {"check", "✅", "done / approved", :work},
      {"eyes", "👀", "looking at it", :work},
      {"rocket", "🚀", "shipped / merged", :work},
      {"hundred", "💯", "exactly right", :work},
      {"pray", "🙏", "thank you", :cheer},
      {"heart", "❤️", "love it", :cheer},
      {"tada", "🎉", "celebrate", :cheer},
      {"raised_hands", "🙌", "great work", :cheer},
      {"fire", "🔥", "impressive", :cheer},
      {"laughing", "😂", "that's funny", :cheer},
      {"smile", "😊", "glad / happy", :cheer}
    ]

    @aliases %{
      "+1" => "thumbs_up",
      "thumbsup" => "thumbs_up",
      "like" => "thumbs_up",
      "white_check_mark" => "check",
      "done" => "check",
      "ship" => "rocket",
      "shipped" => "rocket",
      "100" => "hundred",
      "thanks" => "pray",
      "thank_you" => "pray",
      "folded_hands" => "pray",
      "prayer" => "pray",
      "love" => "heart",
      "celebrate" => "tada",
      "party" => "tada",
      "joy" => "laughing",
      "laugh" => "laughing",
      "lol" => "laughing",
      "blush" => "smile",
      "smiley" => "smile"
    }

    test "every entry has the spec's glyph, label and group" do
      assert for(e <- Reactions.palette(), do: {e.key, e.glyph, e.label, e.group}) == @palette
    end

    test "every key and glyph resolves; every spec alias resolves, wrapped or in any case" do
      for {key, glyph, _label, _group} <- @palette do
        assert Reactions.resolve_key(key) == key
        assert Reactions.resolve_key(glyph) == key
      end

      for {name, key} <- @aliases do
        assert Reactions.resolve_key(name) == key, name
        assert Reactions.resolve_key("  :#{name}:  ") == key, name
        assert Reactions.resolve_key(String.upcase(name)) == key, name
      end

      assert Reactions.aliases() == @aliases
      # thanks is 🙏 now, not ❤️
      assert Reactions.resolve_key("thanks") == "pray"
      assert Reactions.resolve_key("HEART") == "heart"
      assert Reactions.resolve_key("Hundred") == "hundred"
    end

    test "aliases are ASCII words, never glyphs; group names and labels are not input" do
      for name <- Map.keys(Reactions.aliases()), do: assert(name =~ ~r/^[\x21-\x7e]+$/, name)
      assert Reactions.entry("raised_hands").glyph == "🙌"
      assert Reactions.entry(" pray") == nil
      assert Reactions.entry("🙏") == nil

      for value <- ["work", "cheer", "love it", "thank you", "exactly right"] do
        assert Reactions.resolve_key(value) == nil, value
      end
    end

    test "VS16, skin tones and unknown input" do
      assert Reactions.resolve_key("❤") == "heart"
      assert Reactions.resolve_key("❤️") == "heart"
      # a stray VS16 on a glyph that has none
      assert Reactions.resolve_key("👍\u{FE0F}") == "thumbs_up"
      assert Reactions.resolve_key("🔥\u{FE0F}") == "fire"
      # pinned (agreed in #feature-build-more-emojis): a key plus VS16 and skin tones are unknown
      assert Reactions.resolve_key("heart\u{FE0F}") == nil
      assert Reactions.resolve_key("👍🏽") == nil

      for value <- ["👎", "thumbs_down", "", "::", "   ", nil, 100, %{}] do
        assert Reactions.resolve_key(value) == nil, inspect(value)
      end

      # downcasing never changes a glyph, so case-folding can't break glyph lookup
      for {_key, glyph, _label, _group} <- @palette, do: assert(String.downcase(glyph) == glyph)
    end

    test "add/3 stores keys only: aliases and glyphs are refused, every new key is stored", ctx do
      user = {:user, ctx.user.id}
      assert {:error, :unknown_emoji} = Reactions.add(ctx.post.id, user, "thanks")
      assert {:error, :unknown_emoji} = Reactions.add(ctx.post.id, user, "🙏")
      assert {:error, :unknown_emoji} = Reactions.add(ctx.post.id, user, "work")

      attrs = %{message_id: ctx.post.id, channel_id: ctx.channel.id, user_id: ctx.user.id}
      refute Reaction.changeset(%Reaction{}, Map.put(attrs, :emoji, "thanks")).valid?
      assert Repo.all(Reaction) == []

      new = ~w(rocket hundred pray raised_hands fire laughing smile)
      for key <- new, do: assert({:ok, :added} = Reactions.add(ctx.post.id, user, key))
      assert Reaction |> Repo.all() |> Enum.map(& &1.emoji) |> Enum.sort() == Enum.sort(new)
    end

    test "group/1 orders by palette, not insertion: work before cheers", ctx do
      for key <- ~w(fire check pray eyes),
          do: {:ok, :added} = Reactions.add(ctx.post.id, {:user, ctx.user.id}, key)

      assert ctx.post.id
             |> Messages.get!()
             |> Map.get(:reactions)
             |> Reactions.group()
             |> Enum.map(& &1.key) ==
               ~w(check eyes pray fire)
    end

    test "rows stored before the change read with the new labels", ctx do
      for {who, key} <- [{%{user_id: ctx.user.id}, "heart"}, {%{agent_id: ctx.other.id}, "tada"}] do
        Repo.insert!(
          struct(
            Reaction,
            Map.merge(who, %{message_id: ctx.post.id, channel_id: ctx.channel.id, emoji: key})
          )
        )
      end

      assert [%{key: "heart", glyph: "❤️", label: "love it"}, %{key: "tada", label: "celebrate"}] =
               ctx.post.id |> Messages.get!() |> Map.get(:reactions) |> Reactions.group()
    end

    test "new keys are refused on system notes and in archived channels", ctx do
      user = {:user, ctx.user.id}
      {:ok, note} = Messages.post_user_note(ctx.channel.id, ctx.user.id, "handed off")
      assert {:error, :system_message} = Reactions.add(note.id, user, "fire")
      {:ok, _} = Channels.archive(ctx.channel)
      assert {:error, :archived} = Reactions.add(ctx.post.id, user, "pray")
      assert Repo.all(Reaction) == []
    end
  end
end
