defmodule Canopy.AgentSessionsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.AgentSessions

  test "each agent has exactly one root session per channel" do
    %{channel: channel, agent: agent, session: root} = scenario()

    assert AgentSessions.get_root(channel.id, agent.id).id == root.id

    assert {:error, changeset} =
             AgentSessions.create(%{
               channel_id: channel.id,
               agent_id: agent.id,
               engine_session_id: "ses_other"
             })

    assert %{channel_id: ["already has a root session in this channel"]} = errors_on(changeset)

    # Child sessions are exempt from the partial unique index.
    assert {:ok, child} =
             AgentSessions.create(%{
               channel_id: channel.id,
               agent_id: agent.id,
               engine_session_id: "ses_child",
               parent_session_id: root.id
             })

    assert {:ok, _} =
             AgentSessions.create(%{
               channel_id: channel.id,
               agent_id: agent.id,
               engine_session_id: "ses_child2",
               parent_session_id: root.id
             })

    assert AgentSessions.get_root(channel.id, agent.id).id == root.id
    assert child.parent_session_id == root.id
  end

  test "engine_session_id is unique and resolves identity" do
    %{channel: channel, agent: agent, session: session, repository: repository} = scenario()
    other = channel_fixture()

    assert {:error, changeset} =
             AgentSessions.create(%{
               channel_id: other.id,
               agent_id: other.owner_agent_id,
               engine_session_id: session.engine_session_id
             })

    assert %{engine_session_id: ["has already been taken"]} = errors_on(changeset)

    resolved = AgentSessions.get_by_engine_id("opencode", session.engine_session_id)
    assert resolved.id == session.id
    assert resolved.agent.id == agent.id
    assert resolved.channel.id == channel.id
    assert resolved.channel.repository.path == repository.path
    assert AgentSessions.get_by_engine_id("opencode", "ses_unknown") == nil
  end

  test "set_status/3 and touch/1" do
    %{session: session} = scenario()

    assert {:ok, session} = AgentSessions.set_status(session, "busy")
    assert session.status == "busy"
    assert {:ok, session} = AgentSessions.set_status(session, "error", "boom")
    assert session.last_error == "boom"
    assert {:error, _} = AgentSessions.set_status(session, "weird")

    assert session.last_seen_at == nil
    assert {:ok, session} = AgentSessions.touch(session)
    assert %DateTime{} = session.last_seen_at
  end
end
