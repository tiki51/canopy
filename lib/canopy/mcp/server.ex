defmodule Canopy.MCP.Server do
  @moduledoc """
  The Canopy MCP server. One component per tool; identity for every call comes
  from the plugin-stamped `canopy_session_id` (see `Canopy.MCP.Identity`).

  Started from the application supervisor as
  `{Canopy.MCP.Server, transport: :streamable_http}` and reached through the
  `/mcp` scope in `CanopyWeb.Router`.
  """

  use Anubis.Server,
    name: "Canopy",
    version: Mix.Project.config()[:version],
    capabilities: [:tools]

  alias Canopy.MCP.Tools

  component(Tools.ChannelsList, name: "channels_list")
  component(Tools.ChannelGet, name: "channel_get")
  component(Tools.MessagesRead, name: "messages_read")
  component(Tools.MessagesSearch, name: "messages_search")
  component(Tools.MessageSend, name: "message_send")
  component(Tools.ThreadReply, name: "thread_reply")
  component(Tools.TaskGet, name: "task_get")
  component(Tools.TaskUpdate, name: "task_update")
  component(Tools.AgentsList, name: "agents_list")
  component(Tools.DelegateTask, name: "delegate_task")
  component(Tools.HandoffTask, name: "handoff_task")
  component(Tools.HandoffGet, name: "handoff_get")
  component(Tools.HandoffAccept, name: "handoff_accept")
  component(Tools.HandoffReject, name: "handoff_reject")

  @tool_names ~w(
    channels_list channel_get messages_read messages_search message_send thread_reply
    task_get task_update agents_list delegate_task handoff_task handoff_get
    handoff_accept handoff_reject
  )

  @doc "The names of every tool this server exposes, in registration order."
  def tool_names, do: @tool_names

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
