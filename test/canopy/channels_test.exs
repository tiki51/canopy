defmodule Canopy.ChannelsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Channels, Tasks, Timeline}

  test "create/1 writes the channel, its task, and memberships in one transaction" do
    repository = repository_fixture()
    owner = agent_fixture()
    member = agent_fixture()

    assert {:ok, channel} =
             Channels.create(%{
               repository_id: repository.id,
               name: "#Payment-Retries",
               topic: "Fix duplicate invoices",
               owner_agent_id: owner.id,
               agent_ids: [member.id, owner.id]
             })

    assert channel.name == "payment-retries"
    assert channel.owner.id == owner.id
    assert channel.task.title == "Fix duplicate invoices"
    assert channel.task.owner_agent_id == owner.id
    assert channel.task.status == "open"
    assert Enum.map(channel.agents, & &1.id) |> Enum.sort() == Enum.sort([owner.id, member.id])
    assert Channels.member?(channel, member)
    assert Tasks.for_channel(channel.id).id == channel.task.id

    assert {:error, changeset} =
             Channels.create(%{
               repository_id: repository.id,
               name: "payment-retries",
               owner_agent_id: owner.id
             })

    assert %{name: ["has already been taken"]} = errors_on(changeset)
    assert Channels.get_by_name(repository.id, "#payment-retries").id == channel.id
    assert [%{id: id}] = Channels.list_by_repository(repository.id)
    assert id == channel.id
  end

  test "a failed membership rolls back the channel and task" do
    repository = repository_fixture()

    assert {:error, _} =
             Channels.create(%{
               repository_id: repository.id,
               name: "broken",
               agent_ids: ["agt_does_not_exist"]
             })

    assert Channels.list_by_repository(repository.id) == []
    assert Repo.aggregate(Canopy.Tasks.Task, :count) == 0
  end

  test "add_agent/2, remove_agent/2, members/1" do
    %{channel: channel, agent: owner} = scenario()
    other = agent_fixture()

    refute Channels.member?(channel.id, other.id)
    assert {:ok, _} = Channels.add_agent(channel, other)
    assert {:ok, _} = Channels.add_agent(channel.id, other.id)

    assert Enum.map(Channels.members(channel), & &1.id) |> Enum.sort() ==
             Enum.sort([owner.id, other.id])

    assert {:ok, 1} = Channels.remove_agent(channel, other)
    refute Channels.member?(channel, other)
  end

  test "set_owner/2 changes the owner and records owner_changed" do
    %{channel: channel, agent: owner} = scenario()
    new_owner = agent_fixture()
    Timeline.subscribe(channel.id)

    assert {:ok, channel} = Channels.set_owner(channel, new_owner)
    assert channel.owner_agent_id == new_owner.id

    assert_receive {:timeline, %Timeline.Event{event_type: "owner_changed"} = event}
    assert event.payload["from_agent_id"] == owner.id
    assert event.payload["to_agent_id"] == new_owner.id
    assert event.agent.id == new_owner.id

    assert {:ok, channel} = Channels.archive(channel)
    assert channel.status == "archived"
  end
end
