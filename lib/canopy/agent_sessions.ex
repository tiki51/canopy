defmodule Canopy.AgentSessions do
  @moduledoc """
  Engine sessions per (channel, agent). `get_by_engine_id/2` is the identity
  lookup every MCP tool call resolves through.
  """

  import Ecto.Query, warn: false

  alias Canopy.AgentSessions.AgentSession
  alias Canopy.Repo

  @identity_preloads [:agent, channel: [:repository]]

  @doc """
  Returns the agent's session in a channel (its primary root session), or
  nil. A fallback root (`get_fallback_root/2`) is not it.
  """
  def get_root(channel_id, agent_id) do
    Repo.one(
      from s in AgentSession,
        where:
          s.channel_id == ^channel_id and s.agent_id == ^agent_id and
            is_nil(s.parent_session_id) and is_nil(s.fallback_of)
    )
  end

  @doc """
  The agent's fallback root session in a channel: the one its turns run in
  while its own engine is paused (`Canopy.Fallback`), or nil.
  """
  def get_fallback_root(channel_id, agent_id) do
    Repo.one(
      from s in AgentSession,
        where:
          s.channel_id == ^channel_id and s.agent_id == ^agent_id and
            is_nil(s.parent_session_id) and not is_nil(s.fallback_of)
    )
  end

  @doc "The agent's root sessions in a channel: the primary and any fallback."
  def list_roots(channel_id, agent_id) do
    Repo.all(
      from s in AgentSession,
        where:
          s.channel_id == ^channel_id and s.agent_id == ^agent_id and
            is_nil(s.parent_session_id),
        order_by: [asc: s.inserted_at]
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

  @doc "The session with its identity preloads, or nil."
  def get(id) when is_binary(id) do
    case Repo.get(AgentSession, id) do
      nil -> nil
      session -> Repo.preload(session, @identity_preloads)
    end
  end

  def get(_id), do: nil

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

  @doc """
  Renames the session's engine id: Codex picks its thread id on the first
  turn, and the session was created under a placeholder (`Canopy.Engine.Codex`).
  The engine has the session from now on, so it is marked seen too.
  """
  def put_engine_session_id(session_id, engine_session_id)
      when is_binary(session_id) and is_binary(engine_session_id) do
    {n, _} =
      Repo.update_all(from(s in AgentSession, where: s.id == ^session_id),
        set: [engine_session_id: engine_session_id, last_seen_at: DateTime.utc_now()]
      )

    if n == 1, do: {:ok, engine_session_id}, else: {:error, :not_found}
  end

  def touch(%AgentSession{} = session) do
    session
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  Records the running cost total the engine last reported for the session
  (Claude Code: see `Canopy.ClaudeCode.Cost`).
  """
  def put_cost_total(session_id, total) when is_binary(session_id) and is_number(total) do
    Repo.update_all(from(s in AgentSession, where: s.id == ^session_id),
      set: [cost_total: total / 1]
    )

    :ok
  end

  @doc """
  Stamps the session as prompted with the channel's current brief. Returns
  the session with `brief_seen_at` set.
  """
  def mark_brief_seen(%AgentSession{id: id} = session) do
    now = DateTime.utc_now()
    Repo.update_all(from(s in AgentSession, where: s.id == ^id), set: [brief_seen_at: now])
    %{session | brief_seen_at: now}
  end

  @doc """
  Records the MCP servers the engine reported for the session at the start of
  a turn (`[%{name, status, tool_count}]`), for the repository page.
  """
  def record_mcp_servers(%AgentSession{id: id}, servers) when is_list(servers) do
    servers =
      Enum.map(servers, fn s ->
        %{"name" => s.name, "status" => s.status, "tool_count" => s[:tool_count]}
      end)

    Repo.update_all(from(s in AgentSession, where: s.id == ^id),
      set: [mcp_servers: %{"servers" => servers}, mcp_servers_seen_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  The newest MCP report from any session of the engine in the repository's
  channels: `%{servers: [%{"name", "status", "tool_count"}], seen_at}`, or nil.
  """
  def latest_mcp_servers(repository_id, engine) do
    Repo.one(
      from s in AgentSession,
        join: c in assoc(s, :channel),
        where:
          c.repository_id == ^repository_id and s.engine == ^engine and
            not is_nil(s.mcp_servers_seen_at),
        order_by: [desc: s.mcp_servers_seen_at],
        limit: 1,
        select: %{servers: s.mcp_servers, seen_at: s.mcp_servers_seen_at}
    )
    |> case do
      nil -> nil
      %{servers: %{"servers" => list}} = row -> %{row | servers: list}
      row -> %{row | servers: []}
    end
  end

  @doc """
  Deletes the session. Its lock claims go first, through `Canopy.Locks`, so a
  lock it held passes to the next in line rather than vanishing with the row.
  """
  def delete(%AgentSession{} = session) do
    Canopy.Locks.release_session(session.id, "reset", "session reset")
    Repo.delete(session)
  end
end
