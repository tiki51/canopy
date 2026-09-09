defmodule Canopy.AgentSessions do
  @moduledoc """
  OpenCode sessions per (channel, agent). `get_by_opencode_id/1` is the identity
  lookup every MCP tool call resolves through.
  """

  import Ecto.Query, warn: false

  alias Canopy.AgentSessions.AgentSession
  alias Canopy.Repo

  @identity_preloads [:agent, channel: [:repository]]

  @doc "Returns the agent's root session in a channel, or nil."
  def get_root(channel_id, agent_id) do
    Repo.one(
      from s in AgentSession,
        where:
          s.channel_id == ^channel_id and s.agent_id == ^agent_id and
            is_nil(s.parent_session_id)
    )
  end

  @doc "Resolves an OpenCode session id to its session, agent, channel, and repository."
  def get_by_opencode_id(opencode_session_id) when is_binary(opencode_session_id) do
    AgentSession
    |> Repo.get_by(opencode_session_id: opencode_session_id)
    |> Repo.preload(@identity_preloads)
  end

  def get_by_opencode_id(_), do: nil

  def get!(id), do: AgentSession |> Repo.get!(id) |> Repo.preload(@identity_preloads)

  def list_for_channel(channel_id) do
    Repo.all(
      from s in AgentSession,
        where: s.channel_id == ^channel_id,
        order_by: [asc: s.id],
        preload: [:agent]
    )
  end

  def create(attrs) do
    %AgentSession{}
    |> AgentSession.changeset(attrs)
    |> Repo.insert()
  end

  def set_status(%AgentSession{} = session, status, error \\ nil) when is_binary(status) do
    session
    |> AgentSession.status_changeset(status, error)
    |> Repo.update()
  end

  def touch(%AgentSession{} = session) do
    session
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
    |> Repo.update()
  end

  def delete(%AgentSession{} = session), do: Repo.delete(session)
end
