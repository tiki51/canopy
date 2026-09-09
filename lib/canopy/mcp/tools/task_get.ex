defmodule Canopy.MCP.Tools.TaskGet do
  @moduledoc "Get the current task of a channel: status, title, owner, description, and result."

  use Anubis.Server.Component, type: :tool

  alias Canopy.Tasks
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)) do
        task = Tasks.for_channel(channel.id)
        {:ok, "##{channel.name}\n" <> Format.task_block(task)}
      end
    end)
  end
end
