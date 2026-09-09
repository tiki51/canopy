defmodule Canopy.Runtime do
  @moduledoc """
  Facade over the per-channel runtime. LiveViews call this; MCP tools do not.
  """

  alias Canopy.{Messages, Users}
  alias Canopy.Runtime.{ChannelServer, Supervisor}

  @doc "Makes sure the channel's process is running and returns its pid."
  defdelegate ensure_channel(channel_id, opts \\ []), to: Supervisor
  defdelegate stop_channel(channel_id), to: Supervisor

  @doc "Posts a message from the local user; the channel process wakes the right agents."
  def post_user_message(channel_id, body, opts \\ []) do
    {:ok, _pid} = ensure_channel(channel_id)
    Messages.post_user_message(channel_id, Users.local().id, body, opts)
  end

  def respond_permission(channel_id, permission_request_id, reply) do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.respond_permission(pid, permission_request_id, reply)
  end

  def abort(channel_id, agent_id) do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.abort(pid, agent_id)
  end

  def telemetry(channel_id, agent_id) do
    case Supervisor.whereis(channel_id) do
      nil -> []
      pid -> ChannelServer.telemetry(pid, agent_id)
    end
  end

  def status(channel_id) do
    case Supervisor.whereis(channel_id) do
      nil -> %{}
      pid -> ChannelServer.status(pid)
    end
  end
end
