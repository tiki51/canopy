defmodule Canopy.MCP.Tools.ThreadReply do
  @moduledoc "Reply in the thread of an existing message. The thread's author is woken if it is an agent."

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Messages}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :message_id, {:required, :string}, description: "Id of the message to reply to."
    field :text, {:required, :string}, description: "Reply body in GitHub-flavoured Markdown."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, parent} <- parent(params),
           {:ok, channel} <- channel_of(parent, ctx),
           {:ok, text} <- text(params),
           {:ok, reply} <- reply(parent, ctx, text) do
        {:ok, "replied [#{reply.id}] in thread [#{reply.thread_id}] in ##{channel.name}"}
      end
    end)
  end

  defp parent(params) do
    id = Tool.blank_to_nil(Map.get(params, :message_id))

    case id && Messages.get(id) do
      nil -> {:error, "unknown message #{id || "(missing)"}"}
      message -> {:ok, message}
    end
  end

  defp channel_of(parent, ctx) do
    channel = Channels.get(parent.channel_id)

    cond do
      is_nil(channel) -> {:error, "unknown channel for message #{parent.id}"}
      not Channels.member?(channel, ctx.agent) -> {:error, "not a member of ##{channel.name}"}
      true -> {:ok, channel}
    end
  end

  defp text(params) do
    case Tool.blank_to_nil(Map.get(params, :text)) do
      nil -> {:error, "text is empty"}
      text -> {:ok, text}
    end
  end

  defp reply(parent, ctx, text) do
    case Messages.thread_reply(parent.id, {:agent, ctx.agent.id}, text) do
      {:ok, reply} -> {:ok, reply}
      {:error, changeset} -> {:error, "could not reply: " <> Tool.changeset_reason(changeset)}
    end
  end
end
