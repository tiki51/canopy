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

  test "the palette is the fixed five, and a glyph resolves to its key" do
    assert Reactions.keys() == ~w(thumbs_up check eyes tada heart)
    assert Reactions.resolve_key("check") == "check"
    assert Reactions.resolve_key("✅") == "check"
    assert Reactions.resolve_key("❤️") == "heart"
    assert Reactions.resolve_key("❤") == "heart"
    assert Reactions.resolve_key(":eyes:") == "eyes"
    assert Reactions.resolve_key("🔥") == nil
    assert Reactions.resolve_key(nil) == nil
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
    assert {:error, :unknown_emoji} = Reactions.add(ctx.post.id, user, "fire")
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
    {:ok, _} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "eyes")
    {:ok, _} = Reactions.add(ctx.post.id, {:user, ctx.user.id}, "check")
    {:ok, _} = Reactions.add(ctx.post.id, {:agent, ctx.other.id}, "check")

    message = Messages.get!(ctx.post.id)

    assert [
             %{key: "check", glyph: "✅", count: 2, user?: true, agent_ids: [other_id]},
             %{key: "eyes", count: 1, user?: false}
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
end
