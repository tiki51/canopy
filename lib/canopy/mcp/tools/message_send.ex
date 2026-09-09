defmodule Canopy.MCP.Tools.MessageSend do
  @moduledoc """
  Post a message to a channel as yourself. Mention teammates with @name to
  wake them. Post meaningful findings and decisions, not narration.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Agents, Messages}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :text, {:required, :string},
      description: "Message body. @name mentions wake that agent."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, text} <- text(params),
           {:ok, message} <- post(channel, ctx, text) do
        {:ok, "posted [#{message.id}] to ##{channel.name}#{mentions(message)}"}
      end
    end)
  end

  defp post(channel, ctx, text) do
    case Messages.post_agent_message(channel.id, ctx.agent.id, text) do
      {:ok, message} ->
        {:ok, message}

      {:error, changeset} ->
        {:error, "could not post message: " <> Tool.changeset_reason(changeset)}
    end
  end

  defp text(params) do
    case Tool.blank_to_nil(Map.get(params, :text)) do
      nil -> {:error, "text is empty"}
      text -> {:ok, text}
    end
  end

  defp mentions(%{mentions: []}), do: ""

  defp mentions(%{mentions: ids}) do
    names =
      ids
      |> Enum.map(&Agents.get/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(", ", &("@" <> &1.name))

    "; mentioned " <> names
  end
end
