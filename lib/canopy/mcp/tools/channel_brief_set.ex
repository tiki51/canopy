defmodule Canopy.MCP.Tools.ChannelBriefSet do
  @moduledoc """
  Set the channel brief: standing context for everyone in the channel (goal,
  constraints, links, what not to touch), in every member's instructions.
  Keep what the user wrote unless they asked you to change it. Current work
  belongs in the task (canopy_task_update). Only the channel's owner can set
  it, and only the user can clear it.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Channels
  alias Canopy.Channels.Channel
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :text, {:required, :string},
      description:
        "The whole brief, in Markdown; it replaces the current one. At most #{Channel.brief_max()} characters."

    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      text = Tool.blank_to_nil(Map.get(params, :text))

      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           :ok <- check(ctx, channel, text),
           {:ok, channel} <- set(channel, text, ctx.agent.id) do
        chars = String.length(channel.brief)

        {:ok,
         "brief updated (#{chars} chars, ≈#{Channels.brief_tokens(channel.brief)} tokens); " <>
           "every agent in ##{channel.name} gets it from their next prompt."}
      end
    end)
  end

  defp check(ctx, channel, text) do
    cond do
      channel.owner_agent_id != ctx.agent.id ->
        owner = if channel.owner, do: ", #{Format.agent_ref(channel.owner)}", else: ""

        {:error,
         "only the owner of ##{channel.name}#{owner}, can change the brief; ask them or the user"}

      Channels.archived?(channel) ->
        {:error, "##{channel.name} is archived; only the user can change its brief"}

      is_nil(text) ->
        {:error, "text is empty; only the user can clear a brief"}

      String.length(String.trim(text)) > Channel.brief_max() ->
        {:error,
         "the brief is #{String.length(String.trim(text))} characters; the limit is #{Channel.brief_max()}. " <>
           "Keep it to what every task here needs; put long reference material in the notes or a shared document and link it."}

      true ->
        :ok
    end
  end

  defp set(channel, text, agent_id) do
    case Channels.set_brief(channel, text, agent_id) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, changeset} ->
        {:error, "could not set the brief: " <> Tool.changeset_reason(changeset)}
    end
  end
end
