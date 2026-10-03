defmodule Canopy.Runtime.UserCommandsTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{AgentSessions, Delegations, Fixtures, Handoffs, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
    outsider = Fixtures.agent_fixture(%{name: "outsider#{Fixtures.unique_suffix()}"})
    scenario = Fixtures.scenario(members: [reviewer])
    Timeline.subscribe(scenario.channel.id)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    {:ok, _} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{reviewer: reviewer, outsider: outsider})}
  end

  test "/handoff posts the user's note, requests a handoff from the current owner, and wakes the target",
       ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, body, _opts ->
      send(test_pid, {:prompted, body})
      {:ok, ""}
    end)

    assert {:ok, {:handoff, handoff}} =
             Runtime.post_user_message(
               ctx.channel.id,
               "/handoff @#{ctx.reviewer.name} needs review expertise"
             )

    assert handoff.from_agent_id == ctx.agent.id
    assert handoff.to_agent_id == ctx.reviewer.id
    assert handoff.summary == "needs review expertise"
    assert is_map(handoff.packet) and Map.has_key?(handoff.packet, "branch")

    assert_receive {:timeline,
                    %{
                      event_type: "message",
                      message: %{kind: "system", body: "Handing this task to @" <> _}
                    }},
                   1_000

    assert_receive {:timeline, %{event_type: "handoff_requested"}}, 1_000
    assert_receive {:prompted, %{parts: [%{text: text}]}}, 2_000
    assert text =~ "Handoff ID: #{handoff.id}"
    assert Handoffs.get!(handoff.id).status == "requested"
  end

  test "/handoff with no current owner still works and acceptance needs no previous owner", ctx do
    {:ok, _} = Canopy.Channels.update(ctx.channel, %{owner_agent_id: nil})

    assert {:ok, {:handoff, handoff}} =
             Runtime.post_user_message(ctx.channel.id, "/handoff @#{ctx.reviewer.name} take it")

    assert is_nil(handoff.from_agent_id)
    assert {:ok, accepted} = Handoffs.accept(Handoffs.get!(handoff.id))
    assert accepted.status == "accepted"
    assert Canopy.Channels.get!(ctx.channel.id).owner_agent_id == ctx.reviewer.id
  end

  test "/delegate posts a note, creates a delegation from the owner, and wakes the delegate's own session",
       ctx do
    test_pid = self()

    expect(OC, :create_session, fn _dir, body, _opts ->
      refute Map.has_key?(body, :parentID)
      {:ok, %{"id" => "ses_rev"}}
    end)

    expect(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    assert {:ok, {:delegation, delegation}} =
             Runtime.post_user_message(
               ctx.channel.id,
               "/delegate @#{ctx.reviewer.name} trace every enqueue path"
             )

    assert delegation.from_agent_id == ctx.agent.id
    assert delegation.description == "trace every enqueue path"
    assert_receive {:prompted, "ses_rev", %{parts: [%{text: text}]}}, 2_000
    assert text =~ "Delegation ID: #{delegation.id}"
    delegation = Delegations.get!(delegation.id)
    assert delegation.status == "working"

    assert delegation.child_session_id ==
             AgentSessions.get_root(ctx.channel.id, ctx.reviewer.id).id
  end

  test "/delegate with no owner comes from the user and runs in the delegate's session", ctx do
    {:ok, _} = Canopy.Channels.update(ctx.channel, %{owner_agent_id: nil})
    test_pid = self()

    expect(OC, :create_session, fn _dir, body, _opts ->
      refute Map.has_key?(body, :parentID)
      {:ok, %{"id" => "ses_root_rev"}}
    end)

    expect(OC, :prompt_async, fn _dir, sid, _body, _opts ->
      send(test_pid, {:prompted, sid})
      {:ok, ""}
    end)

    assert {:ok, {:delegation, _}} =
             Runtime.post_user_message(
               ctx.channel.id,
               "/delegate @#{ctx.reviewer.name} look into it"
             )

    assert_receive {:prompted, "ses_root_rev"}, 2_000
  end

  test "/i adds an agent to the channel, and with a message mentions it", ctx do
    outsider = Fixtures.agent_fixture(%{name: "outsider#{Fixtures.unique_suffix()}"})
    refute Canopy.Channels.member?(ctx.channel, outsider)

    assert {:ok, {:invite, %{id: id}}} =
             Runtime.post_user_message(ctx.channel.id, "/i @#{outsider.name}")

    assert id == outsider.id
    assert Canopy.Channels.member?(ctx.channel, outsider)
    assert_receive {:timeline, %{event_type: "member_added", agent_id: ^id}}, 2_000
    refute_receive {:timeline, %{event_type: "message"}}, 200

    assert {:error, "@#{outsider.name} is already in ##{ctx.channel.name}"} ==
             Runtime.post_user_message(ctx.channel.id, "/invite #{outsider.name}")

    second = Fixtures.agent_fixture(%{name: "second#{Fixtures.unique_suffix()}"})

    assert {:ok, %Canopy.Messages.Message{} = message} =
             Runtime.post_user_message(
               ctx.channel.id,
               "/i @#{second.name} please look at the header"
             )

    assert message.body == "@#{second.name} please look at the header"
    assert message.mentions == [second.id]
    assert Canopy.Channels.member?(ctx.channel, second)

    assert {:error, "no agent or team named @nobody"} =
             Runtime.post_user_message(ctx.channel.id, "/i @nobody")

    {:ok, _} = Canopy.Agents.deactivate(second)
    third = Fixtures.agent_fixture(%{name: "third#{Fixtures.unique_suffix()}"})
    {:ok, dm} = Canopy.Channels.ensure_dm(ctx.repository.id, ctx.agent)

    assert {:error, "a DM keeps its agents" <> _} =
             Runtime.post_user_message(dm.id, "/i @#{third.name}")
  end

  test "/i @team adds the team quietly; with a message it mentions the team, waking its members",
       ctx do
    one = Fixtures.agent_fixture(%{name: "one#{Fixtures.unique_suffix()}"})
    two = Fixtures.agent_fixture(%{name: "two#{Fixtures.unique_suffix()}"})
    team = Fixtures.team_fixture([one, ctx.reviewer], name: "crew#{Fixtures.unique_suffix()}")

    assert {:ok, {:invite_team, %{id: team_id}, [added]}} =
             Runtime.post_user_message(ctx.channel.id, "/i @#{team.name}")

    assert {team_id, added.id} == {team.id, one.id}
    assert Canopy.Channels.member?(ctx.channel, one)
    assert_receive {:timeline, %{event_type: "team_added", payload: %{"by" => "user"}}}, 2_000
    refute_receive {:timeline, %{event_type: "message"}}, 200

    # everyone already in: an error, and nothing written
    assert {:error, "everyone on @#{team.name} is already in ##{ctx.channel.name}"} ==
             Runtime.post_user_message(ctx.channel.id, "/i @#{team.name} hello")

    refute_receive {:timeline, _}, 200

    # with a message, the new members join, then the team is mentioned and they wake
    {:ok, _} = Canopy.Teams.update(team, %{agent_ids: [one.id, ctx.reviewer.id, two.id]})
    {:ok, _} = Canopy.Settings.update(%{serialize_turns: false})
    test_pid = self()

    stub(OC, :prompt_async, fn _dir, sid, _body, _opts ->
      send(test_pid, {:prompted, sid})
      {:ok, ""}
    end)

    assert {:ok, %Canopy.Messages.Message{} = message} =
             Runtime.post_user_message(ctx.channel.id, "/i @#{team.name} look at #42")

    assert message.body == "@#{team.name} look at #42"
    assert Enum.sort(message.mentions) == Enum.sort([one.id, ctx.reviewer.id, two.id])
    assert Canopy.Channels.member?(ctx.channel, two)

    for _ <- 1..3, do: assert_receive({:prompted, _}, 2_000)

    {:ok, dm} = Canopy.Channels.ensure_dm(ctx.repository.id, ctx.agent)

    assert {:error, "a DM keeps its agents" <> _} =
             Runtime.post_user_message(dm.id, "/i @#{team.name}")

    assert {:error, reason} =
             Runtime.post_user_message(ctx.channel.id, "/delegate @#{team.name} look")

    assert reason =~ "@#{team.name} is a team; name one member: "
  end

  test "bad commands return errors and write nothing", ctx do
    assert {:error, "usage: /handoff" <> _} =
             Runtime.post_user_message(ctx.channel.id, "/handoff")

    assert {:error, "no agent named @nobody"} =
             Runtime.post_user_message(ctx.channel.id, "/handoff @nobody because")

    assert {:error, msg} =
             Runtime.post_user_message(ctx.channel.id, "/handoff @#{ctx.outsider.name} because")

    assert msg =~ "not a member"

    assert {:error, msg} =
             Runtime.post_user_message(ctx.channel.id, "/handoff @#{ctx.agent.name} because")

    assert msg =~ "already owns"
    refute_receive {:timeline, _}, 200
    assert Handoffs.pending_for_channel(ctx.channel.id) == []
  end

  test "plain text still posts a message and wakes the owner", ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    assert {:ok, %Canopy.Messages.Message{body: "/lib/foo.ex looks wrong"}} =
             Runtime.post_user_message(ctx.channel.id, "/lib/foo.ex looks wrong")

    # wait for the wake so the server is idle before the Mox stubs go away
    assert_receive :prompted, 2_000
  end

  test "/playbook starts a run in the channel; the coordinator is the one named, else the playbook's, else the owner",
       ctx do
    {:ok, playbook} =
      Canopy.Playbooks.create(%{
        body:
          Canopy.PlaybookHelpers.playbook_text(
            "quick",
            [{"look", "Look", "coordinator"}],
            "coordinator: #{ctx.reviewer.name}\n"
          )
      })

    assert {:ok, {:playbook, run}} =
             Runtime.post_user_message(ctx.channel.id, "/playbook quick check the login")

    assert run.playbook_id == playbook.id
    assert run.coordinator_agent_id == ctx.reviewer.id
    assert run.started_by_agent_id == nil
    assert run.brief == "check the login"
    assert_receive {:timeline, %{event_type: "playbook_started"}}

    {:ok, _, :cancelled} = Canopy.Playbooks.Runs.cancel(run, :user, "again")

    assert {:ok, {:playbook, run}} =
             Runtime.post_user_message(ctx.channel.id, "/playbook quick @#{ctx.agent.name} again")

    assert run.coordinator_agent_id == ctx.agent.id
    assert run.brief == "again"

    assert {:error, "no playbook named nope" <> _} =
             Runtime.post_user_message(ctx.channel.id, "/playbook nope do it")

    assert {:error, reason} = Runtime.post_user_message(ctx.channel.id, "/playbook quick more")
    assert reason =~ "already has a playbook run in progress"
  end
end
