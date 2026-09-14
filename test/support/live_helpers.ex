defmodule CanopyWeb.LiveHelpers do
  @moduledoc """
  Helpers for LiveView tests that drive the channel screen: broadcasting the
  runtime's ephemeral messages (telemetry, status) on a channel topic exactly as
  `Canopy.Runtime.ChannelServer` does.
  """

  alias Canopy.Engine.Event
  alias Canopy.Timeline

  @doc "Builds a normalized OpenCode event."
  def oc_event(type, data, session_id \\ "ses_test") do
    %Event{type: type, session_id: session_id, data: data, raw_type: "test"}
  end

  @doc "Broadcasts `{:telemetry, agent_id, event}` on the channel topic."
  def broadcast_telemetry(channel_id, agent_id, type, data) do
    broadcast(channel_id, {:telemetry, agent_id, oc_event(type, data)})
  end

  @doc "Broadcasts `{:agent_status, agent_id, status}` on the channel topic."
  def broadcast_status(channel_id, agent_id, status) do
    broadcast(channel_id, {:agent_status, agent_id, status})
  end

  defp broadcast(channel_id, message) do
    :ok = Phoenix.PubSub.broadcast(Canopy.PubSub, Timeline.topic(channel_id), message)
  end
end
