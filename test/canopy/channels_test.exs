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

  describe "teams" do
    setup do
      lead = agent_fixture(name: "lead-" <> unique_suffix())
      helper = agent_fixture(name: "helper-" <> unique_suffix())
      idle = agent_fixture(name: "idle-" <> unique_suffix())
      %{lead: lead, helper: helper, idle: idle, team: team_fixture([lead, helper, idle])}
    end

    test "add_team/3 adds only missing active members and records one team_added", ctx do
      {:ok, _} = Canopy.Agents.deactivate(ctx.idle)
      channel = channel_fixture(owner_agent_id: ctx.lead.id)
      Timeline.subscribe(channel.id)

      assert {:ok, %{added: [added], already: [already], inactive: [inactive]}} =
               Channels.add_team(channel, ctx.team, "user")

      assert {added.id, already.id, inactive.id} == {ctx.helper.id, ctx.lead.id, ctx.idle.id}
      assert Channels.member?(channel, ctx.helper)
      refute Channels.member?(channel, ctx.idle)

      assert_receive {:timeline, %{event_type: "team_added", agent_id: nil, payload: payload}}
      assert payload["team_id"] == ctx.team.id
      assert payload["team_name"] == ctx.team.name
      assert payload["agent_ids"] == [ctx.helper.id]
      assert payload["by"] == "user"
      refute_received {:timeline, %{event_type: "member_added"}}

      # nothing new to add: nothing recorded; the owner never changes
      assert {:ok, %{added: []}} = Channels.add_team(channel, ctx.team, ctx.lead.id)
      refute_receive {:timeline, _}, 100
      assert Channels.get!(channel.id).owner_agent_id == ctx.lead.id
    end

    test "add_team/3 credits an adding agent and refuses DMs", ctx do
      channel = channel_fixture()
      Timeline.subscribe(channel.id)
      by = channel.owner_agent_id

      assert {:ok, %{added: added}} = Channels.add_team(channel, ctx.team, by)
      assert length(added) == 3
      assert_receive {:timeline, %{event_type: "team_added", agent_id: ^by}}

      {:ok, dm} = Channels.ensure_dm(channel.repository_id, ctx.lead)
      assert {:error, :dm} = Channels.add_team(dm, ctx.team, "user")
    end

    test "create/1 with team_ids adds the members and makes the lead owner", ctx do
      other = agent_fixture()

      {:ok, channel} =
        Channels.create(%{
          repository_id: repository_fixture().id,
          name: "bugfix",
          team_ids: [ctx.team.id],
          agent_ids: [other.id]
        })

      assert channel.owner_agent_id == ctx.lead.id

      assert Enum.map(channel.agents, & &1.id) |> Enum.sort() ==
               Enum.sort([ctx.lead.id, ctx.helper.id, ctx.idle.id, other.id])

      # no membership events at creation
      assert Timeline.list(channel.id) == []

      # an explicit owner wins; an inactive lead hands over to the first active member
      {:ok, _} = Canopy.Agents.deactivate(ctx.lead)

      {:ok, channel} =
        Channels.create(%{
          repository_id: channel.repository_id,
          name: "b2",
          team_ids: [ctx.team.id]
        })

      refute Channels.member?(channel, ctx.lead)
      assert channel.owner_agent_id in [ctx.helper.id, ctx.idle.id]
    end
  end

  describe "brief" do
    setup do
      %{channel: channel_fixture()}
    end

    test "set_brief/3 stores the trimmed text and records who, what, and the previous text",
         %{channel: channel} do
      Timeline.subscribe(channel.id)

      assert {:ok, updated} =
               Channels.set_brief(channel, "  Goal: stop double charges.\n", "user")

      assert updated.brief == "Goal: stop double charges."
      assert updated.brief_updated_by == "user"
      assert %DateTime{} = updated.brief_updated_at

      assert_receive {:timeline, %{event_type: "brief_updated", agent_id: nil, payload: p}}
      assert p == %{"by" => "user", "body" => "Goal: stop double charges.", "previous" => nil}

      owner = channel.owner_agent_id
      assert {:ok, again} = Channels.set_brief(updated, "Goal: refunds too.", owner)
      assert again.brief_updated_by == owner
      assert_receive {:timeline, %{event_type: "brief_updated", agent_id: ^owner, payload: p}}
      assert p["previous"] == "Goal: stop double charges."
      assert p["by"] == owner
    end

    test "an unchanged text records nothing", %{channel: channel} do
      {:ok, channel} = Channels.set_brief(channel, "Same.", "user")
      Timeline.subscribe(channel.id)

      assert {:ok, same} = Channels.set_brief(channel, " Same. ", "user")
      assert same.brief_updated_at == channel.brief_updated_at
      refute_receive {:timeline, %{event_type: "brief_updated"}}, 100
      assert length(Channels.brief_history(channel.id)) == 1
    end

    test "over the cap is an error and stores nothing", %{channel: channel} do
      assert {:error, changeset} =
               Channels.set_brief(channel, String.duplicate("x", 4_001), "user")

      assert %{brief: [_]} = errors_on(changeset)
      assert Channels.get!(channel.id).brief == nil
      assert Channels.brief_history(channel.id) == []

      assert {:ok, %{brief: brief}} =
               Channels.set_brief(channel, String.duplicate("x", 4_000), "user")

      assert String.length(brief) == 4_000
    end

    test "an empty text clears it and is recorded as a version", %{channel: channel} do
      {:ok, channel} = Channels.set_brief(channel, "Something.", "user")
      assert {:ok, cleared} = Channels.set_brief(channel, "", "user")
      assert cleared.brief == nil

      assert [%{payload: %{"body" => nil, "previous" => "Something."}}, _] =
               Channels.brief_history(channel.id)
    end

    test "compares with the stored row, not a stale struct", %{channel: channel} do
      {:ok, _} = Channels.set_brief(channel, "From an agent.", channel.owner_agent_id)
      # `channel` still has no brief; the edit made meanwhile is the previous text
      {:ok, _} = Channels.set_brief(channel, "From the user.", "user")

      assert [%{payload: %{"previous" => "From an agent."}} | _] =
               Channels.brief_history(channel.id)
    end

    test "update/2 ignores a brief", %{channel: channel} do
      assert {:ok, updated} = Channels.update(channel, %{brief: "sneaky", topic: "New topic"})
      assert updated.topic == "New topic"
      assert updated.brief == nil
      assert Channels.brief_history(channel.id) == []
    end

    test "create/1 with a brief stores it and records one event, credited to the creator" do
      repository = repository_fixture()
      owner = agent_fixture()

      assert {:ok, channel} =
               Channels.create(%{
                 repository_id: repository.id,
                 name: "briefed",
                 owner_agent_id: owner.id,
                 brief: "Goal: ship it.",
                 brief_by: owner.id
               })

      assert channel.brief == "Goal: ship it."
      assert channel.brief_updated_by == owner.id

      assert [%{agent_id: agent_id, payload: %{"body" => "Goal: ship it.", "previous" => nil}}] =
               Channels.brief_history(channel.id)

      assert agent_id == owner.id
      assert Timeline.list(channel.id) |> length() == 1

      # without a brief, creation records nothing
      {:ok, plain} =
        Channels.create(%{repository_id: repository.id, name: "plain", owner_agent_id: owner.id})

      assert Timeline.list(plain.id) == []
    end

    test "create/1 refuses a brief over the cap" do
      repository = repository_fixture()

      assert {:error, changeset} =
               Channels.create(%{
                 repository_id: repository.id,
                 name: "toolong",
                 brief: String.duplicate("x", 4_001)
               })

      assert %{brief: [_]} = errors_on(changeset)
    end

    test "brief_tokens/1 is a rough four-characters-a-token estimate" do
      assert Channels.brief_tokens(nil) == 0
      assert Channels.brief_tokens("abcd") == 1
      assert Channels.brief_tokens("abcde") == 2
      assert Channels.brief_tokens(String.duplicate("x", 4_000)) == 1_000
    end
  end
end
