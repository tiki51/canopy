defmodule Canopy.TimelineTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Messages, Timeline}

  test "record/1 inserts, preloads, and broadcasts on the channel topic" do
    %{channel: channel, agent: agent} = scenario()
    other = channel_fixture()
    Timeline.subscribe(channel.id)

    assert {:ok, event} =
             Timeline.record(%{
               channel_id: channel.id,
               agent_id: agent.id,
               event_type: "agent_started",
               payload: %{"prompt" => "wake"}
             })

    assert event.agent.id == agent.id
    assert event.message == nil
    assert_receive {:timeline, %Timeline.Event{id: id}}
    assert id == event.id

    {:ok, _} = Timeline.record(%{channel_id: other.id, event_type: "agent_error", payload: %{}})
    refute_receive {:timeline, _}

    assert {:error, changeset} =
             Timeline.record(%{channel_id: channel.id, event_type: "not_a_type", payload: %{}})

    assert %{event_type: [_]} = errors_on(changeset)
  end

  test "list/2 returns events in id order with messages and senders preloaded" do
    %{channel: channel, agent: agent, user: user} = scenario()

    {:ok, m1} = Messages.post_user_message(channel.id, user.id, "first")

    {:ok, started} =
      Timeline.record(%{channel_id: channel.id, agent_id: agent.id, event_type: "agent_started"})

    {:ok, m2} = Messages.post_agent_reply(channel.id, agent.id, "second")
    {:ok, m3} = Messages.post_agent_message(channel.id, agent.id, "third")

    events = Timeline.list(channel.id)
    assert Enum.map(events, & &1.id) == Enum.sort(Enum.map(events, & &1.id))
    assert Enum.map(events, & &1.event_type) == ["message", "agent_started", "message", "message"]

    [e1, e2, e3, e4] = events
    assert e1.message.id == m1.id
    assert e1.message.user.id == user.id
    assert e1.agent == nil
    assert e2.id == started.id
    assert e2.message == nil
    assert e2.agent.id == agent.id
    assert e3.message.id == m2.id
    assert e3.message.agent.id == agent.id
    assert e3.agent.id == agent.id
    assert e4.message.id == m3.id

    assert Enum.map(Timeline.list(channel.id, limit: 2), & &1.id) == [e3.id, e4.id]
    assert Enum.map(Timeline.list(channel.id, before: e3.id), & &1.id) == [e1.id, e2.id]

    assert Enum.map(Timeline.list(channel.id, types: ["message"]), & &1.ref_id) ==
             [m1.id, m2.id, m3.id]

    assert Timeline.get!(e1.id).message.id == m1.id
  end

  test "the channel scope leaves out what only a thread shows; list_thread/2 is the thread" do
    %{channel: channel, agent: agent, user: user, session: session} = scenario()
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")
    {:ok, quiet} = Messages.thread_reply(root.id, {:agent, agent.id}, "quiet")
    {:ok, loud} = Messages.thread_reply(root.id, {:agent, agent.id}, "loud", to_channel: true)

    {:ok, turn} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        ref_id: session.id,
        thread_id: root.id,
        in_channel: false,
        payload: %{}
      })

    {:ok, after_root} = Messages.post_user_message(channel.id, user.id, "after")

    assert Enum.map(Timeline.list(channel.id, scope: :channel), & &1.ref_id) ==
             [root.id, loud.id, after_root.id]

    assert length(Timeline.list(channel.id)) == 5

    thread = Timeline.list_thread(root.id)
    assert Enum.map(thread, & &1.id) == Enum.map(thread, & &1.id) |> Enum.sort()
    assert [%{ref_id: root_id} | rest] = thread
    assert root_id == root.id
    assert Enum.map(rest, &(&1.ref_id || &1.id)) == [quiet.id, loud.id, session.id]
    assert List.last(rest).id == turn.id

    # the newest events of a long thread, after the root
    assert [%{ref_id: ^root_id}, %{id: last_id}] = Timeline.list_thread(root.id, limit: 1)
    assert last_id == turn.id
    assert Timeline.list_thread("msg_missing") == []
  end
end
