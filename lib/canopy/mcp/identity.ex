defmodule Canopy.MCP.Identity do
  @moduledoc """
  Resolves the calling agent from the two trusted sources.

  A Claude Code process authenticates with its session's own bearer token, so
  `Canopy.MCP.AuthPlug` assigns `:canopy_session` on the connection and Anubis
  carries it into the tool's frame; that wins whenever present. Otherwise the
  caller is OpenCode: every tool schema carries an optional `canopy_session_id`
  that the OpenCode plugin overwrites with the real session id before the call
  reaches Canopy. Model-supplied values are never trusted, and unknown or
  missing ids are rejected before any tool logic runs.
  """

  alias Canopy.{AgentSessions, Channels}

  @unknown "unknown Canopy session; is the Canopy OpenCode plugin installed?"

  @type t :: %{
          session: Canopy.AgentSessions.AgentSession.t(),
          agent: Canopy.Agents.Agent.t(),
          channel: Canopy.Channels.Channel.t(),
          repository: Canopy.Repositories.Repository.t()
        }

  @doc "The message returned when the session id cannot be resolved."
  def unknown_session_message, do: @unknown

  @doc """
  Resolves the identity from the frame's session assign when the connection
  authenticated as a session, else from the validated tool params. Returns
  `{:ok, %{session, agent, channel, repository}}` or `{:error, reason}`.
  """
  @spec resolve(map(), map() | nil) :: {:ok, t()} | {:error, String.t()}
  def resolve(params, frame \\ nil)

  def resolve(_params, %{assigns: %{canopy_session: %{engine: engine, engine_session_id: id}}}),
    do: resolve_engine_session(engine, id)

  def resolve(params, _frame) when is_map(params) do
    params
    |> session_id()
    |> resolve_session_id()
  end

  @doc "The identity a session-authenticated connection carries; `{:error, _}` for the OpenCode path."
  @spec from_frame(map()) :: {:ok, t()} | {:error, String.t()}
  def from_frame(%{assigns: %{canopy_session: %{engine: engine, engine_session_id: id}}}),
    do: resolve_engine_session(engine, id)

  def from_frame(_frame), do: {:error, @unknown}

  @doc "Resolves an OpenCode session id directly."
  @spec resolve_session_id(String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def resolve_session_id(session_id) when is_binary(session_id) and session_id != "",
    do: resolve_engine_session("opencode", session_id)

  def resolve_session_id(_), do: {:error, @unknown}

  defp resolve_engine_session(engine, session_id) do
    case AgentSessions.get_by_engine_id(engine, session_id) do
      %{agent: agent, channel: %{repository: repository} = channel} = session
      when not is_nil(agent) and not is_nil(channel) ->
        # Reload the channel with the full preload set (owner, task, members)
        # so tools never touch an unloaded association.
        channel = Channels.get!(channel.id)
        {:ok, %{session: session, agent: agent, channel: channel, repository: repository}}

      _ ->
        {:error, @unknown}
    end
  end

  defp session_id(params) do
    Map.get(params, :canopy_session_id) || Map.get(params, "canopy_session_id")
  end
end
