defmodule Canopy.MCP.Tools.MessageSend do
  @moduledoc """
  Post a message to a channel as yourself. Mention teammates with @name to
  wake them; a post with no mention wakes only the channel owner, and nobody
  if that is you. Post meaningful findings and decisions, not narration.
  Attach files (a report you wrote, a screenshot) with `attachments`, on the
  same message that asks about them; never announce a file in one post and
  send it in the next, because the second post wakes nobody.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Agents, Messages}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :text, :string,
      description:
        "Message body in GitHub-flavoured Markdown. @name mentions wake that agent; inside `code` they wake nobody. @here wakes every agent in this channel. It costs one chatter turn; use it only when everyone needs to act. It works only in canopy_message_send and canopy_thread_reply, not in your turn's final text. May be empty when attachments are given."

    field :attachments, :string,
      description:
        "Comma-separated document ids (doc_…) or repository-relative file paths to attach, e.g. \".canopy/out/report.md\". Paths are shared as new documents first."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, attachments} <-
             Tool.resolve_attachments(
               ctx,
               channel,
               Tool.blank_to_nil(Map.get(params, :attachments))
             ),
           {:ok, text} <- text(params, attachments),
           spent? = Messages.here?(text) and Canopy.Runtime.chatter_spent?(channel.id),
           {:ok, message} <- post(channel, ctx, text, attachments) do
        {:ok,
         "posted [#{message.id}] to ##{channel.name}#{attached(attachments)}#{mentions(message)}#{audience(ctx, channel, message)}#{Tool.here_note(message, spent?)}"}
      end
    end)
  end

  defp post(channel, ctx, text, attachments) do
    case Messages.post_agent_message(channel.id, ctx.agent.id, text,
           attachments: attachments,
           fallback: Canopy.Fallback.marker(ctx.session)
         ) do
      {:ok, message} ->
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "could not post message: " <> Tool.changeset_reason(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp text(params, attachments) do
    case {Tool.blank_to_nil(Map.get(params, :text)), attachments} do
      {nil, []} -> {:error, "text is empty"}
      {nil, _} -> {:ok, ""}
      {text, _} -> {:ok, text}
    end
  end

  # Says who this post reaches when nobody was mentioned, so an agent does not
  # wait for an answer that cannot come. An @here says that itself.
  defp audience(_ctx, _channel, %{mentions: [_ | _]}), do: ""

  defp audience(ctx, channel, message) do
    cond do
      Messages.here_mention(message) ->
        ""

      is_nil(channel.owner_agent_id) or channel.owner_agent_id == ctx.agent.id ->
        "; no @mention, so this wakes nobody: mention @name if you want a reply"

      true ->
        owner = Agents.get(channel.owner_agent_id)
        "; no @mention, so only the owner @#{owner.name} is woken"
    end
  end

  defp attached([]), do: ""
  defp attached(ids), do: " with #{length(ids)} attachment(s): #{Enum.join(ids, ", ")}"

  # The agents named directly or through a team; `here_note` lists @here's.
  defp mentions(message) do
    here_only = (Messages.here_mention(message) || %{})["agent_ids"] || []
    mentions(message.mentions -- here_only, :names)
  end

  defp mentions([], :names), do: ""

  defp mentions(ids, :names) do
    names =
      ids
      |> Enum.map(&Agents.get/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(", ", &("@" <> &1.name))

    "; mentioned " <> names
  end
end
