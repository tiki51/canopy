defmodule Canopy.UnreadTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Messages, Threads, Unread}

  test "counts agent messages since the last read, and those that mention the user by name" do
    %{channel: channel, agent: agent, user: user} = scenario()
    other = channel_fixture(%{repository_id: channel.repository_id})

    assert Unread.summary(user) == %{}

    {:ok, _} = Messages.post_agent_message(channel.id, agent.id, "Found the index problem.")

    {:ok, _} =
      Messages.post_agent_message(channel.id, agent.id, "@#{user.display_name} can you confirm?")

    {:ok, _} =
      Messages.post_agent_reply(
        channel.id,
        agent.id,
        "Summary for @#{String.upcase(user.display_name)}."
      )

    {:ok, _} = Messages.post_user_message(channel.id, user.id, "my own words do not count")
    {:ok, _} = Messages.post_user_note(channel.id, user.id, "system notes do not count")
    {:ok, _} = Messages.post_agent_message(other.id, agent.id, "quiet finding elsewhere")

    assert %{count: 3, mentions: 2} = Unread.summary(user)[channel.id]
    assert %{count: 1, mentions: 0} = Unread.summary(user)[other.id]

    :ok = Unread.mark_read(channel.id, user)
    refute Map.has_key?(Unread.summary(user), channel.id)
    assert Map.has_key?(Unread.summary(user), other.id)

    {:ok, _} = Messages.post_agent_message(channel.id, agent.id, "one more")
    assert %{count: 1, mentions: 0} = Unread.summary(user)[channel.id]
  end

  test "thread-only replies do not make the channel unread, unless they mention the user" do
    %{channel: channel, agent: agent, user: user} = scenario()
    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
    :ok = Unread.mark_read(channel.id, user)

    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "side conversation")
    refute Map.has_key?(Unread.summary(user), channel.id)

    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "for all", to_channel: true)
    assert %{count: 1, mentions: 0} = Unread.summary(user)[channel.id]

    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "@#{user.display_name} look")
    assert %{count: 2, mentions: 1} = Unread.summary(user)[channel.id]
  end

  test "thread_summary/1 counts unread agent replies in followed threads only" do
    %{channel: channel, agent: agent, user: user} = scenario()
    {:ok, mine} = Messages.post_user_message(channel.id, user.id, "my question")
    {:ok, theirs} = Messages.post_agent_message(channel.id, agent.id, "a finding")

    # replies in a thread the user started follow it; the other is not followed
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "answer one")
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "answer two")
    {:ok, _} = Messages.thread_reply(theirs.id, {:agent, agent.id}, "more detail")

    mine_id = mine.id

    assert %{^mine_id => %{count: 2, channel_id: channel_id}} =
             summary = Unread.thread_summary(user)

    assert channel_id == channel.id
    refute Map.has_key?(summary, theirs.id)

    :ok = Threads.mark_read(mine.id, user)
    assert Unread.thread_summary(user) == %{}

    # the user's own reply never counts, and replying marks the thread read
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "answer three")
    {:ok, _} = Messages.thread_reply(mine.id, {:user, user.id}, "thanks")
    assert Unread.thread_summary(user) == %{}

    :ok = Threads.follow(mine.id, user, false)
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "answer four")
    assert Unread.thread_summary(user) == %{}
  end

  test "a thread reply mentioning a non-ASCII display name counts, in any case" do
    %{channel: channel, agent: agent, user: user} = scenario()
    user = user |> Ecto.Changeset.change(display_name: "Zoë") |> Repo.update!()
    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
    :ok = Unread.mark_read(channel.id, user)

    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "@ZOË can you check?")
    assert %{count: 1, mentions: 1} = Unread.summary(user)[channel.id]
    # the same test made the user follow the thread
    assert Threads.following?(root.id, user)
  end
end
