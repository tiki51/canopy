defmodule Canopy.MCP.Tools.MemoryRead do
  @moduledoc """
  Read your memory across repositories in full. The first part of it is
  already in your system prompt; call this when it says the memory continues.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Memory
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      case Memory.get(ctx.agent.id) do
        "" -> {:ok, "Your memory is empty. Write to it with canopy_memory_write."}
        body -> {:ok, body}
      end
    end)
  end
end
