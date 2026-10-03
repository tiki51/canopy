defmodule Canopy.TeamsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Agents, Channels, Teams}
  alias Canopy.Teams.TeamMember

  setup do
    backend = agent_fixture(name: "backend-" <> unique_suffix())
    frontend = agent_fixture(name: "frontend-" <> unique_suffix())
    tester = agent_fixture(name: "tester-" <> unique_suffix())
    %{backend: backend, frontend: frontend, tester: tester}
  end

  test "create/1 writes the team and its members; update/2 replaces them atomically", ctx do
    Teams.subscribe()

    assert {:ok, team} =
             Teams.create(%{
               "name" => "@Bugfix-Team",
               "description" => "Fixes bugs",
               "lead_agent_id" => ctx.backend.id,
               "agent_ids" => [ctx.backend.id, ctx.frontend.id]
             })

    assert_receive {:teams, :changed}
    assert team.name == "bugfix-team"
    assert team.display_name == "bugfix-team"
    assert team.lead.id == ctx.backend.id

    assert Enum.map(team.members, & &1.id) |> Enum.sort() ==
             Enum.sort([ctx.backend.id, ctx.frontend.id])

    assert Teams.get_by_name("@bugfix-team").id == team.id

    # a kept member keeps its row (and role); the dropped one goes, the new one joins
    Repo.update_all(TeamMember, set: [role: "builder"])

    assert {:ok, team} =
             Teams.update(team, %{agent_ids: [ctx.backend.id, ctx.tester.id]})

    assert Enum.map(team.members, & &1.id) |> Enum.sort() ==
             Enum.sort([ctx.backend.id, ctx.tester.id])

    assert Repo.get_by!(TeamMember, team_id: team.id, agent_id: ctx.backend.id).role == "builder"
    assert Repo.get_by!(TeamMember, team_id: team.id, agent_id: ctx.tester.id).role == nil

    # without agent_ids the members stay
    assert {:ok, team} = Teams.update(team, %{description: "Still fixes bugs"})
    assert length(team.members) == 2

    # a failed update changes nothing
    assert {:error, changeset} =
             Teams.update(team, %{name: "Has Space", agent_ids: [ctx.frontend.id]})

    assert %{name: [_]} = errors_on(changeset)

    assert Teams.get!(team.id).members |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([ctx.backend.id, ctx.tester.id])

    assert {:ok, _} = Teams.delete(team)
    assert Teams.get(team.id) == nil
    assert Repo.aggregate(TeamMember, :count) == 0
  end

  test "every team has a lead who is a member; removing the lead needs a new lead first", ctx do
    assert {:error, changeset} = Teams.create(%{name: "nolead", agent_ids: [ctx.backend.id]})
    assert %{lead_agent_id: ["pick a lead"]} = errors_on(changeset)

    assert {:error, changeset} =
             Teams.create(%{
               name: "outside",
               lead_agent_id: ctx.tester.id,
               agent_ids: [ctx.backend.id]
             })

    assert %{lead_agent_id: [_]} = errors_on(changeset)

    assert {:error, changeset} = Teams.create(%{name: "empty", lead_agent_id: ctx.backend.id})
    assert %{agent_ids: ["pick at least one member"]} = errors_on(changeset)

    team = team_fixture([ctx.backend, ctx.frontend])

    assert {:error, changeset} = Teams.update(team, %{agent_ids: [ctx.frontend.id]})

    assert %{lead_agent_id: ["choose a new lead before removing the current one"]} =
             errors_on(changeset)

    assert {:ok, team} =
             Teams.update(team, %{lead_agent_id: ctx.frontend.id, agent_ids: [ctx.frontend.id]})

    assert team.lead_agent_id == ctx.frontend.id
  end

  test "teams and agents share the @ namespace, checked both ways", ctx do
    assert {:error, changeset} =
             Teams.create(%{
               name: ctx.backend.name,
               lead_agent_id: ctx.backend.id,
               agent_ids: [ctx.backend.id]
             })

    assert %{name: ["is already an agent's name"]} = errors_on(changeset)

    team = team_fixture([ctx.backend], name: "crew-" <> unique_suffix())

    assert {:error, changeset} = Agents.update(ctx.frontend, %{name: team.name})
    assert %{name: ["is already a team's name"]} = errors_on(changeset)

    assert {:error, changeset} = Agents.create(%{name: team.name})
    assert %{name: ["is already a team's name"]} = errors_on(changeset)

    assert {:error, changeset} =
             Teams.create(%{
               name: team.name,
               lead_agent_id: ctx.backend.id,
               agent_ids: [ctx.backend.id]
             })

    assert %{name: ["has already been taken"]} = errors_on(changeset)
  end

  test "expand_names/1 and active_members/1 skip inactive agents", ctx do
    team = team_fixture([ctx.frontend, ctx.backend, ctx.tester], name: "qa-" <> unique_suffix())
    {:ok, _} = Agents.deactivate(ctx.tester)

    expected = Enum.sort_by([ctx.backend, ctx.frontend], & &1.name) |> Enum.map(& &1.id)

    assert Teams.expand_names([team.name, "nobody"]) == %{
             team.name => %{team_id: team.id, agent_ids: expected}
           }

    assert Enum.map(Teams.active_members(Teams.get!(team.id)), & &1.id) == expected
    assert [%{id: id}] = Teams.for_agent(ctx.tester.id)
    assert id == team.id
  end

  test "addable/1 and complete_in/1 look at active members not yet in the channel", ctx do
    team = team_fixture([ctx.backend, ctx.frontend])
    channel = channel_fixture(owner_agent_id: ctx.backend.id)

    assert Enum.map(Teams.addable(channel), & &1.id) == [team.id]
    assert Teams.complete_in(Enum.map(Channels.members(channel), & &1.id)) == []

    {:ok, _} = Channels.add_agent(channel, ctx.frontend)
    assert Teams.addable(channel) == []
    assert Teams.complete_in(Enum.map(Channels.members(channel), & &1.id)) == [team.name]
  end
end
