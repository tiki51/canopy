defmodule Canopy.MCP.Tools.MessageGet do
  @moduledoc """
  One message in full. `messages_read` shortens long bodies; use this for the
  whole text of a message you actually need to work from.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :id, {:required, :string}, description: "The message id (msg_…)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, message} <- Tool.readable_message(ctx, Map.get(params, :id)) do
        {:ok, Format.message_line(message, truncate: nil)}
      end
    end)
  end
end
