defmodule Canopy.GlobalPermissionsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{GlobalPermissions, Timeline}
  alias Canopy.GlobalPermissions.Grant

  setup do
    GlobalPermissions.subscribe()
    %{channel: channel, agent: agent} = scenario()
    {:ok, channel: channel, agent: agent}
  end

  test "grant is idempotent and keys on the downcased tool", %{channel: channel, agent: agent} do
    assert {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash", channel_id: channel.id)
    assert %Grant{tool: "bash", label: "Bash", use_count: 0, last_used_at: nil} = grant
    assert grant.channel_id == channel.id
    assert "gp_" <> _ = grant.id
    assert_receive {:global_permissions, :changed, agent_id}
    assert agent_id == agent.id

    assert {:ok, again} = GlobalPermissions.grant(agent.id, " bash ")
    assert again.id == grant.id
    assert again.granted_at == grant.granted_at
    assert again.label == "Bash"
    assert again.channel_id == channel.id

    assert GlobalPermissions.get(agent.id, "BASH").id == grant.id
    assert GlobalPermissions.get(agent.id, "BASH").channel.id == channel.id
    assert GlobalPermissions.match(agent.id, "bash").id == grant.id
    assert GlobalPermissions.get(agent.id, "Edit") == nil
    assert GlobalPermissions.match(agent_fixture().id, "Bash") == nil
  end

  test "list_for_agent orders by tool with the channel preloaded", %{
    channel: channel,
    agent: agent
  } do
    {:ok, _} = GlobalPermissions.grant(agent.id, "WebFetch", channel_id: channel.id)
    {:ok, _} = GlobalPermissions.grant(agent.id, "bash", channel_id: channel.id)
    {:ok, _} = GlobalPermissions.grant(agent.id, "Edit")
    {:ok, _} = GlobalPermissions.grant(agent_fixture().id, "Read")

    assert [
             %{label: "bash", channel: %{id: cid}},
             %{label: "Edit", channel: nil},
             %{label: "WebFetch"}
           ] = GlobalPermissions.list_for_agent(agent.id)

    assert cid == channel.id
  end

  test "a deleted channel leaves the grant with no channel", %{agent: agent} do
    other = channel_fixture()
    {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash", channel_id: other.id)
    Repo.delete!(other)

    assert %{id: id, channel_id: nil, channel: nil} = GlobalPermissions.get(agent.id, "Bash")
    assert id == grant.id
  end

  test "revoke returns the whole row, then :not_found", %{channel: channel, agent: agent} do
    {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash", channel_id: channel.id)
    assert_receive {:global_permissions, :changed, _}

    assert {:ok, %Grant{id: id, tool: "bash", channel_id: cid}} = GlobalPermissions.revoke(grant)
    assert id == grant.id
    assert cid == channel.id
    assert_receive {:global_permissions, :changed, _}
    assert GlobalPermissions.get(agent.id, "Bash") == nil

    assert {:error, :not_found} = GlobalPermissions.revoke(grant.id)
    assert {:error, :not_found} = GlobalPermissions.revoke(grant)
  end

  test "restore puts back the same row; a re-grant meanwhile wins", %{
    channel: channel,
    agent: agent
  } do
    {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash", channel_id: channel.id)
    {:ok, _} = record_use(grant, channel, agent)
    {:ok, _} = record_use(grant, channel, agent)
    used = GlobalPermissions.get(agent.id, "Bash")

    {:ok, removed} = GlobalPermissions.revoke(grant.id)
    flush()

    assert {:ok, restored} = GlobalPermissions.restore(removed)
    assert_receive {:global_permissions, :changed, _}
    assert restored.id == grant.id
    assert restored.granted_at == grant.granted_at
    assert restored.channel_id == channel.id
    assert restored.use_count == 2
    assert restored.last_used_at == used.last_used_at

    # restoring twice returns the same row
    assert {:ok, %{id: id}} = GlobalPermissions.restore(removed)
    assert id == grant.id

    # granted again after the removal: Undo keeps the new grant
    {:ok, _} = GlobalPermissions.revoke(grant.id)
    {:ok, regrant} = GlobalPermissions.grant(agent.id, "bash")
    assert regrant.id != grant.id
    assert {:ok, kept} = GlobalPermissions.restore(removed)
    assert kept.id == regrant.id
    assert kept.use_count == 0

    # and a grant on a restored row reuses it
    {:ok, _} = GlobalPermissions.revoke(regrant)
    {:ok, back} = GlobalPermissions.restore(removed)
    assert {:ok, %{id: ^id}} = GlobalPermissions.grant(agent.id, "Bash")
    assert back.id == id
  end

  test "restoring a grant whose channel was deleted gives it no channel", %{agent: agent} do
    other = channel_fixture()
    {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash", channel_id: other.id)
    {:ok, removed} = GlobalPermissions.revoke(grant)
    Repo.delete!(other)

    assert {:ok, %{id: id, channel_id: nil}} = GlobalPermissions.restore(removed)
    assert id == grant.id
  end

  test "match ignores tools that are not grantable, and a nil agent", %{agent: agent} do
    now = DateTime.utc_now()

    for tool <- ~w(doom_loop askuserquestion) do
      Repo.insert!(%Grant{agent_id: agent.id, tool: tool, label: tool, granted_at: now})
    end

    assert GlobalPermissions.match(agent.id, "doom_loop") == nil
    assert GlobalPermissions.match(agent.id, "AskUserQuestion") == nil
    assert GlobalPermissions.match(nil, "Bash") == nil
    assert GlobalPermissions.match(agent.id, nil) == nil
  end

  test "grantable?" do
    refute GlobalPermissions.grantable?("doom_loop")
    refute GlobalPermissions.grantable?("AskUserQuestion")
    refute GlobalPermissions.grantable?("question")
    refute GlobalPermissions.grantable?(" ")
    refute GlobalPermissions.grantable?(nil)
    assert GlobalPermissions.grantable?("Bash")
    assert GlobalPermissions.grantable?("external_directory")
    assert GlobalPermissions.grantable?("mcp__github__create_issue")
  end

  test "record_use counts the use and records the line", %{channel: channel, agent: agent} do
    Timeline.subscribe(channel.id)
    {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash", channel_id: channel.id)
    flush()

    assert {:ok, event} = record_use(grant, channel, agent)
    assert_receive {:global_permissions, :changed, _}
    assert_receive {:timeline, %Timeline.Event{event_type: "permission_auto_approved"}}

    assert %{
             event_type: "permission_auto_approved",
             agent_id: agent_id,
             ref_id: ref_id,
             thread_id: nil,
             in_channel: true,
             payload: payload
           } = event

    assert agent_id == agent.id
    assert ref_id == grant.id

    assert payload == %{
             "permission" => "Bash",
             "patterns" => ["npm run build"],
             "grant_id" => grant.id
           }

    used = GlobalPermissions.get(agent.id, "bash")
    assert used.use_count == 1
    assert %DateTime{} = used.last_used_at

    # a thread turn's line goes to the thread
    {:ok, root} = Canopy.Messages.post_agent_message(channel.id, agent.id, "root")

    assert {:ok, %{thread_id: thread_id, in_channel: false}} =
             GlobalPermissions.record_use(grant, %{
               channel_id: channel.id,
               agent_id: agent.id,
               permission: "Bash",
               patterns: [],
               thread_id: root.id,
               in_channel: false
             })

    assert thread_id == root.id
    assert GlobalPermissions.get(agent.id, "bash").use_count == 2
  end

  defp record_use(grant, channel, agent) do
    GlobalPermissions.record_use(grant, %{
      channel_id: channel.id,
      agent_id: agent.id,
      permission: "Bash",
      patterns: ["npm run build"]
    })
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
