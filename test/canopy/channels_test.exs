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

  test "add_agent/2 and remove_agent/2 record membership events and protect the owner" do
    %{channel: channel, agent: owner} = scenario()
    other = agent_fixture()
    Timeline.subscribe(channel.id)

    refute Channels.member?(channel.id, other.id)
    assert {:ok, %Canopy.Channels.ChannelAgent{}} = Channels.add_agent(channel, other)
    assert_receive {:timeline, %Timeline.Event{event_type: "member_added", agent_id: agent_id}}
    assert agent_id == other.id

    # adding again is a no-op, with no second event
    assert {:ok, :already_member} = Channels.add_agent(channel.id, other.id)
    refute_receive {:timeline, %Timeline.Event{event_type: "member_added"}}, 100

    assert Enum.map(Channels.members(channel), & &1.id) |> Enum.sort() ==
             Enum.sort([owner.id, other.id])

    assert other.id in Enum.map(Channels.addable_agents(channel), & &1.id) == false
    assert {:error, :owner} = Channels.remove_agent(channel, owner)
    assert Channels.member?(channel, owner)

    assert {:ok, 1} = Channels.remove_agent(channel, other)
    refute Channels.member?(channel, other)
    assert_receive {:timeline, %Timeline.Event{event_type: "member_removed", agent_id: ^agent_id}}
    assert other.id in Enum.map(Channels.addable_agents(channel), & &1.id)

    assert {:ok, 0} = Channels.remove_agent(channel, other)
    refute_receive {:timeline, %Timeline.Event{event_type: "member_removed"}}, 100
  end

  test "set_spend_limit/3 validates, records the change, and reads back fresh" do
    %{channel: channel} = scenario()
    assert Channels.spend_limit(channel.id) == nil

    assert {:ok, channel} = Channels.set_spend_limit(channel, "$12.50")
    assert channel.spend_limit == 12.5
    assert Channels.spend_limit(channel.id) == 12.5

    assert [%{payload: %{"limit" => 12.5, "by" => "user"}}] =
             Timeline.list(channel.id, types: ["spend_limit_changed"])

    # the same value again records nothing
    assert {:ok, _} = Channels.set_spend_limit(channel, 12.5)
    assert [_] = Timeline.list(channel.id, types: ["spend_limit_changed"])

    assert {:error, changeset} = Channels.set_spend_limit(channel, -1)
    assert %{spend_limit: [_]} = errors_on(changeset)
    assert {:error, _} = Channels.set_spend_limit(channel, "lots")

    assert {:ok, channel} = Channels.set_spend_limit(channel, nil, "manager")
    assert channel.spend_limit == nil

    assert [_, %{payload: %{"limit" => nil, "by" => "manager"}}] =
             Timeline.list(channel.id, types: ["spend_limit_changed"])
  end

  test "archive/1 and reopen/1 flip the status and record events" do
    %{channel: channel} = scenario()
    Timeline.subscribe(channel.id)

    assert {:ok, channel} = Channels.archive(channel)
    assert channel.status == "archived"
    assert Channels.archived?(channel)
    assert_receive {:timeline, %Timeline.Event{event_type: "channel_archived"}}

    assert {:ok, ^channel} = Channels.archive(channel)
    refute_receive {:timeline, %Timeline.Event{event_type: "channel_archived"}}, 100

    assert {:error, "this channel is archived" <> _} =
             Canopy.Runtime.post_user_message(channel.id, "anyone there?")

    assert {:ok, channel} = Channels.reopen(channel)
    assert channel.status == "open"
    assert_receive {:timeline, %Timeline.Event{event_type: "channel_reopened"}}
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
  end

  test "ensure_dm/2 creates one DM channel per agent and repository, owned by the agent" do
    repository = repository_fixture()
    agent = agent_fixture(%{name: "helper" <> unique_suffix()})

    assert {:ok, dm} = Channels.ensure_dm(repository.id, agent)
    assert dm.kind == "dm"
    assert dm.name == "dm-" <> agent.name
    assert dm.owner_agent_id == agent.id
    assert Enum.map(dm.agents, & &1.id) == [agent.id]
    assert Channels.dm?(dm)
    assert Tasks.for_channel(dm.id).title == "Direct messages with @" <> agent.name

    assert {:ok, %{id: same_id}} = Channels.ensure_dm(repository.id, agent)
    assert same_id == dm.id

    # asking for the same agent in another repository moves the DM there
    other = repository_fixture()
    Timeline.subscribe(dm.id)
    assert {:ok, %{id: moved_id, repository_id: moved_repo}} = Channels.ensure_dm(other.id, agent)
    assert moved_id == dm.id
    assert moved_repo == other.id
    assert_receive {:timeline, %Timeline.Event{event_type: "repository_switched", payload: p}}
    assert p["to"] == other.name and p["from"] == repository.name
  end

  test "switch_repository/3 is for DMs only and resets sessions when no runtime is up" do
    %{channel: channel, agent: agent, repository: repository, session: session} = scenario()
    other = repository_fixture()

    assert {:error, :not_a_dm} = Channels.switch_repository(channel, other.id, "user")

    {:ok, dm} = Channels.ensure_dm(repository.id, agent)
    dm_session = Canopy.Fixtures.session_fixture(%{channel: dm, agent_id: agent.id})
    assert {:ok, ^dm} = Channels.switch_repository(dm, repository.id, "user")
    assert {:error, :unknown_repository} = Channels.switch_repository(dm, "repo_nope", "user")

    assert {:ok, moved} = Channels.switch_repository(dm, other.id, "@" <> agent.name)
    assert moved.repository_id == other.id
    refute Canopy.Repo.get(Canopy.AgentSessions.AgentSession, dm_session.id)
    # the channel's own sessions are untouched
    assert Canopy.Repo.get(Canopy.AgentSessions.AgentSession, session.id)
  end

  test "ensure_dm/2 with several agents is found by its exact set, owned by the first" do
    repository = repository_fixture()
    a = agent_fixture(%{name: "alpha" <> unique_suffix()})
    b = agent_fixture(%{name: "beta" <> unique_suffix()})
    c = agent_fixture(%{name: "gamma" <> unique_suffix()})

    assert {:ok, group} = Channels.ensure_dm(repository.id, [b, a])
    assert group.kind == "dm"
    assert group.owner_agent_id == b.id
    assert Enum.map(group.agents, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    assert Channels.dm_label(group) == "@#{a.name}, @#{b.name}"
    assert group.name == "dm-#{a.name}-#{b.name}"

    # order does not matter, duplicates collapse, a different set is a different DM
    assert {:ok, %{id: same}} = Channels.ensure_dm(repository.id, [a, b, a])
    assert same == group.id
    assert {:ok, %{id: solo}} = Channels.ensure_dm(repository.id, a)
    refute solo == group.id
    assert {:ok, %{id: trio}} = Channels.ensure_dm(repository.id, [a, b, c])
    refute trio in [group.id, solo]

    assert Channels.list_dms(repository.id) |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([group.id, solo, trio])
  end

  test "creating, archiving, and reopening a channel notify subscribers" do
    Channels.subscribe()
    %{channel: channel} = scenario()
    assert_receive {:channels, :changed}
    {:ok, channel} = Channels.archive(channel)
    assert_receive {:channels, :changed}
    {:ok, _} = Channels.reopen(channel)
    assert_receive {:channels, :changed}
  end

  test "ensure_dm/2 picks a free name when a channel already uses dm-<agent>" do
    repository = repository_fixture()
    agent = agent_fixture(%{name: "taken" <> unique_suffix()})
    channel_fixture(%{repository_id: repository.id, name: "dm-" <> agent.name})

    assert {:ok, dm} = Channels.ensure_dm(repository.id, agent)
    assert dm.kind == "dm"
    assert String.starts_with?(dm.name, "dm-" <> agent.name <> "-")
  end

  test "DMs are left out of the sidebar's channel lists" do
    repository = repository_fixture()
    agent = agent_fixture()
    channel = channel_fixture(%{repository_id: repository.id})
    {:ok, dm} = Channels.ensure_dm(repository.id, agent)

    [%{channels: channels}] =
      Enum.filter(Canopy.Repositories.list_with_channels(), &(&1.id == repository.id))

    assert Enum.map(channels, & &1.id) == [channel.id]
    refute dm.id in Enum.map(channels, & &1.id)
  end
end
