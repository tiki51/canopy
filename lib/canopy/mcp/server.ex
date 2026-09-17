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
  component(Tools.Permission, name: "permission")
  component(Tools.ChannelGet, name: "channel_get")
  component(Tools.MessagesRead, name: "messages_read")
  component(Tools.MessageGet, name: "message_get")
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
  component(Tools.DmStart, name: "dm_start")
  component(Tools.DmSwitchRepository, name: "dm_switch_repository")
  component(Tools.Pass, name: "pass")
  component(Tools.ChannelCreate, name: "channel_create")
  component(Tools.ChannelAddMembers, name: "channel_add_members")
  component(Tools.ChannelRemoveMembers, name: "channel_remove_members")
  component(Tools.ScheduleCreate, name: "schedule_create")
  component(Tools.SchedulesList, name: "schedules_list")
  component(Tools.ScheduleCancel, name: "schedule_cancel")
  component(Tools.MemoryRead, name: "memory_read")
  component(Tools.MemoryWrite, name: "memory_write")
  component(Tools.NotesRead, name: "notes_read")
  component(Tools.NotesWrite, name: "notes_write")
  component(Tools.CostsReport, name: "costs_report")
  component(Tools.DocumentsList, name: "documents_list")
  component(Tools.DocumentGet, name: "document_get")
  component(Tools.DocumentShare, name: "document_share")

  @tool_names ~w(
    channels_list channel_get messages_read message_get messages_search message_send thread_reply
    task_get task_update agents_list delegate_task handoff_task handoff_get
    handoff_accept handoff_reject dm_start pass channel_create channel_add_members
    channel_remove_members schedule_create schedules_list schedule_cancel memory_read memory_write
    notes_read notes_write
    dm_switch_repository costs_report documents_list document_get document_share permission
  )

  @doc "The names of every tool this server exposes, in registration order."
  def tool_names, do: @tool_names

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
