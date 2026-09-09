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
end
