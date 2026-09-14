defmodule Canopy.AgentSessions do
  @moduledoc """
  Engine sessions per (channel, agent). `get_by_engine_id/2` is the identity
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

  @doc "Resolves an engine's session id to its session, agent, channel, and repository."
  def get_by_engine_id(engine, engine_session_id)
      when is_binary(engine) and is_binary(engine_session_id) do
    AgentSession
    |> Repo.get_by(engine: engine, engine_session_id: engine_session_id)
    |> Repo.preload(@identity_preloads)
  end

  def get_by_engine_id(_, _), do: nil

  @doc "The session whose MCP bearer token this is, with identity preloads; nil for unknown tokens."
  def get_by_mcp_token(token) when is_binary(token) and token != "" do
    AgentSession
    |> Repo.get_by(mcp_token: token)
    |> Repo.preload(@identity_preloads)
  end

  def get_by_mcp_token(_), do: nil

  @doc "Gives the session an MCP token if it has none (sessions created before tokens existed)."
  def ensure_mcp_token(%AgentSession{mcp_token: token} = session) when is_binary(token),
    do: {:ok, session}

  def ensure_mcp_token(%AgentSession{} = session) do
    session
    |> AgentSession.changeset(%{mcp_token: generate_mcp_token()})
    |> Repo.update()
  end

  def generate_mcp_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

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
