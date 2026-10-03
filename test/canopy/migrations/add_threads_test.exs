defmodule Canopy.Migrations.AddThreadsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Canopy.{Messages, Repo, Threads, Timeline, Unread}
  alias Canopy.Messages.Message
  alias Canopy.Threads.ThreadRead

  @migration Canopy.Repo.Migrations.AddThreads
  @path "priv/repo/migrations/20261003114833_add_threads.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    scenario()
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp backfill, do: apply(@migration, :backfill, [Repo])

  # Events as they were written before threads had a place of their own.
  defp forget_threads do
    Repo.update_all(Timeline.Event, set: [thread_id: nil, in_channel: true])
  end

  test "thread replies move out of the feed; everything else stays", ctx do
    %{channel: channel, agent: agent, user: user, session: session} = ctx
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")
    {:ok, reply} = Messages.thread_reply(root.id, {:agent, agent.id}, "in the thread")
    {:ok, loud} = Messages.thread_reply(root.id, {:agent, agent.id}, "also", to_channel: true)

    {:ok, turn} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        ref_id: session.id,
        payload: %{}
      })

    forget_threads()
    backfill()

    assert %{thread_id: nil, in_channel: true} = Timeline.for_message(root.id)
    assert %{thread_id: thread_id, in_channel: false} = Timeline.for_message(reply.id)
    assert thread_id == root.id
    assert %{thread_id: ^thread_id, in_channel: true} = Timeline.for_message(loud.id)
    # an old turn line cannot be traced to a thread: it stays in the channel
    assert %{thread_id: nil, in_channel: true} = Repo.get!(Timeline.Event, turn.id)

    # safe to run again
    backfill()
    assert %{in_channel: false} = Timeline.for_message(reply.id)

    assert Repo.aggregate(from(e in Timeline.Event, where: e.in_channel == false), :count) == 1
  end

  defp backfill_following, do: apply(@migration, :backfill_following, [Repo, DateTime.utc_now()])
  defp backfill_mentions, do: apply(@migration, :backfill_mentions, [Repo])

  test "the threads the user took part in are followed and read on upgrade", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    other = agent_fixture()
    {:ok, dm} = Canopy.Channels.ensure_dm(ctx.repository.id, agent)

    {:ok, started} = Messages.post_user_message(channel.id, user.id, "my question")
    {:ok, _} = Messages.thread_reply(started.id, {:agent, agent.id}, "an answer")
    {:ok, newest} = Messages.thread_reply(started.id, {:agent, other.id}, "another")

    {:ok, joined} = Messages.post_agent_message(channel.id, agent.id, "a finding")
    {:ok, _} = Messages.thread_reply(joined.id, {:user, user.id}, "I replied")

    {:ok, mentioned} = Messages.post_agent_message(channel.id, agent.id, "a note")

    {:ok, _} =
      Messages.thread_reply(mentioned.id, {:agent, other.id}, "@#{user.display_name} fyi")

    {:ok, in_dm} = Messages.post_agent_message(dm.id, agent.id, "in the dm")
    {:ok, _} = Messages.thread_reply(in_dm.id, {:agent, agent.id}, "more")

    {:ok, unrelated} = Messages.post_agent_message(channel.id, agent.id, "not mine")
    {:ok, _} = Messages.thread_reply(unrelated.id, {:agent, other.id}, "between agents")

    {:ok, dropped} = Messages.post_user_message(channel.id, user.id, "I unfollowed this")
    {:ok, _} = Messages.thread_reply(dropped.id, {:agent, agent.id}, "reply")

    # as before the upgrade: no read state, no mention flags; one explicit unfollow
    Repo.delete_all(ThreadRead)
    Repo.update_all(Message, set: [mentions_user: false])
    :ok = Threads.follow(dropped.id, user, false)

    backfill_mentions()
    backfill_following()
    backfill_following()

    for root <- [started, joined, mentioned, in_dm], do: assert(Threads.following?(root.id, user))
    refute Threads.following?(unrelated.id, user)
    refute Threads.following?(dropped.id, user)

    # read up to the newest reply: the upgrade does not flood the badge
    assert Threads.get_read(started.id, user).last_read_at == newest.inserted_at
    assert Unread.thread_summary(user) == %{}

    # a later agent reply in a followed thread counts as new
    {:ok, _} = Messages.thread_reply(started.id, {:agent, agent.id}, "after the upgrade")
    assert %{count: 1} = Unread.thread_summary(user)[started.id]
  end

  test "mention flags use the same Unicode-aware test as the app", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    user = user |> Ecto.Changeset.change(display_name: "Zoë") |> Repo.update!()

    {:ok, upper} = Messages.post_agent_message(channel.id, agent.id, "@ZOË please look")
    {:ok, plain} = Messages.post_agent_message(channel.id, agent.id, "@zoe is someone else")
    assert upper.mentions_user and Unread.mentions?(upper.body, user)
    refute plain.mentions_user or Unread.mentions?(plain.body, user)

    Repo.update_all(Message, set: [mentions_user: false])
    backfill_mentions()

    assert Repo.get!(Message, upper.id).mentions_user
    refute Repo.get!(Message, plain.id).mentions_user
  end
end
