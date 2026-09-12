defmodule Canopy.MCP.Tools.ThreadReply do
  @moduledoc """
  Reply in the thread of an existing message. The thread's author is woken if
  it is an agent. Attach files with `attachments`, as in canopy_message_send.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Messages}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :message_id, {:required, :string}, description: "Id of the message to reply to."

    field :text, :string,
      description:
        "Reply body in GitHub-flavoured Markdown. May be empty when attachments are given."

    field :attachments, :string,
      description:
        "Comma-separated document ids (doc_…) or repository-relative file paths to attach."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, parent} <- parent(params),
           {:ok, channel} <- channel_of(parent, ctx),
           {:ok, attachments} <-
             Tool.resolve_attachments(
               ctx,
               channel,
               Tool.blank_to_nil(Map.get(params, :attachments))
             ),
           {:ok, text} <- text(params, attachments),
           {:ok, reply} <- reply(parent, ctx, text, attachments) do
        {:ok,
         "replied [#{reply.id}] in thread [#{reply.thread_id}] in ##{channel.name}#{attached(attachments)}"}
      end
    end)
  end

  defp attached([]), do: ""
  defp attached(ids), do: " with #{length(ids)} attachment(s): #{Enum.join(ids, ", ")}"

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

  defp text(params, attachments) do
    case {Tool.blank_to_nil(Map.get(params, :text)), attachments} do
      {nil, []} -> {:error, "text is empty"}
      {nil, _} -> {:ok, ""}
      {text, _} -> {:ok, text}
    end
  end

  defp reply(parent, ctx, text, attachments) do
    case Messages.thread_reply(parent.id, {:agent, ctx.agent.id}, text, attachments: attachments) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "could not reply: " <> Tool.changeset_reason(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end
end
