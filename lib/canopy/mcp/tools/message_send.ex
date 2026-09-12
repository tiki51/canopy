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
        "Message body in GitHub-flavoured Markdown. @name mentions wake that agent. May be empty when attachments are given."

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
           {:ok, message} <- post(channel, ctx, text, attachments) do
        {:ok,
         "posted [#{message.id}] to ##{channel.name}#{attached(attachments)}#{mentions(message)}#{audience(ctx, channel, message)}"}
      end
    end)
  end

  defp post(channel, ctx, text, attachments) do
    case Messages.post_agent_message(channel.id, ctx.agent.id, text, attachments: attachments) do
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
  # wait for an answer that cannot come.
  defp audience(_ctx, _channel, %{mentions: [_ | _]}), do: ""

  defp audience(ctx, channel, _message) do
    cond do
      is_nil(channel.owner_agent_id) or channel.owner_agent_id == ctx.agent.id ->
        "; no @mention, so this wakes nobody: mention @name if you want a reply"

      true ->
        owner = Agents.get(channel.owner_agent_id)
        "; no @mention, so only the owner @#{owner.name} is woken"
    end
  end

  defp attached([]), do: ""
  defp attached(ids), do: " with #{length(ids)} attachment(s): #{Enum.join(ids, ", ")}"

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
