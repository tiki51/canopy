defmodule Canopy.UnreadTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Messages, Unread}

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
end
