defmodule Canopy.MCP.Identity do
  @moduledoc """
  Resolves the plugin-stamped `canopy_session_id` to the calling agent.

  Every tool schema carries an optional `canopy_session_id`. The OpenCode
  plugin overwrites it with the real session id before the call reaches
  Canopy, so it is the only identity a tool trusts. Unknown or missing ids are
  rejected before any tool logic runs.
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
  Resolves the identity from validated tool params. Returns
  `{:ok, %{session, agent, channel, repository}}` or `{:error, reason}`.
  """
  @spec resolve(map()) :: {:ok, t()} | {:error, String.t()}
  def resolve(params) when is_map(params) do
    params
    |> session_id()
    |> resolve_session_id()
  end

  @doc "Resolves an OpenCode session id directly."
  @spec resolve_session_id(String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def resolve_session_id(session_id) when is_binary(session_id) and session_id != "" do
    case AgentSessions.get_by_opencode_id(session_id) do
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

  def resolve_session_id(_), do: {:error, @unknown}

  defp session_id(params) do
    Map.get(params, :canopy_session_id) || Map.get(params, "canopy_session_id")
  end
end
