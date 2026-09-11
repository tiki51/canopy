defmodule Canopy.MCP.Tools.MessageGet do
  @moduledoc """
  One message in full. `messages_read` shortens long bodies; use this for the
  whole text of a message you actually need to work from.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Messages}
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :id, {:required, :string}, description: "The message id (msg_…)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, message} <- find(Map.get(params, :id)),
           :ok <- readable(ctx, message) do
        {:ok, Format.message_line(message, truncate: nil)}
      end
    end)
  end

  defp find(id) do
    case Tool.blank_to_nil(id) && Messages.get(id) do
      %Messages.Message{} = message -> {:ok, message}
      _ -> {:error, "unknown message #{inspect(id)}"}
    end
  end

  defp readable(ctx, message) do
    channel = Channels.get!(message.channel_id)

    cond do
      channel.repository_id != ctx.repository.id -> {:error, "unknown message"}
      not Channels.member?(channel, ctx.agent) -> {:error, "not a member of ##{channel.name}"}
      true -> :ok
    end
  end
end
