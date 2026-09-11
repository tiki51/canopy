defmodule Canopy.Runtime.UserCommandsTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Delegations, Fixtures, Handoffs, Runtime, Timeline}
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

  test "/delegate posts a note, creates a delegation from the owner, and wakes the delegate in a child session",
       ctx do
    test_pid = self()

    expect(OC, :create_session, fn _dir, %{parentID: _}, _opts ->
      {:ok, %{"id" => "ses_child_x"}}
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
    assert_receive {:prompted, "ses_child_x", %{parts: [%{text: text}]}}, 2_000
    assert text =~ "Delegation ID: #{delegation.id}"
    assert Delegations.get!(delegation.id).status == "working"
  end

  test "/delegate with no owner runs in the delegate's root session", ctx do
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
end
