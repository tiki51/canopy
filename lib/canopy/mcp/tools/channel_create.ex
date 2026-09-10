defmodule Canopy.MCP.Tools.ChannelCreate do
  @moduledoc """
  Create a channel in your repository. You become its owner and first member,
  and you may add other agents at creation or later with
  `canopy_channel_add_members`. Use a channel for a piece of work that
  deserves its own history; use a DM for a conversation.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Messages, Runtime}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :name, {:required, :string},
      description:
        "Channel name: lowercase letters, digits, dashes. Other characters are converted."

    field :topic, :string, description: "One line on what the channel is for."

    field :task, :string,
      description:
        "The channel's task, if it has one beyond the topic. Becomes the task description."

    field :agents, :string,
      description:
        "Other agents to add as members, comma separated (@name or name). You are always a member."

    field :text, :string,
      description: "A first message to post, in Markdown. @name mentions wake those agents."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, name} <- slug(Map.get(params, :name)),
           {:ok, others} <- Tool.resolve_agents(Map.get(params, :agents), except: ctx.agent.id),
           {:ok, channel} <- create(ctx, name, params, others),
           {:ok, message_id} <-
             maybe_post(channel, ctx, Tool.blank_to_nil(Map.get(params, :text))) do
        members = Enum.map_join(channel.agents, ", ", &("@" <> &1.name))
        posted = if message_id, do: "; posted [#{message_id}]", else: ""

        {:ok,
         "created ##{channel.name} [#{channel.id}] in #{channel.repository.name}; you own it; members #{members}#{posted}. " <>
           "Post there with canopy_message_send channel: \"#{channel.name}\"."}
      end
    end)
  end

  defp create(ctx, name, params, others) do
    topic = Tool.blank_to_nil(Map.get(params, :topic))

    attrs = %{
      repository_id: ctx.repository.id,
      name: name,
      topic: topic,
      owner_agent_id: ctx.agent.id,
      agent_ids: Enum.map(others, & &1.id),
      task_title: topic || name,
      task_description: Tool.blank_to_nil(Map.get(params, :task))
    }

    case Channels.create(attrs) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, changeset} ->
        {:error, "could not create channel: " <> Tool.changeset_reason(changeset)}
    end
  end

  defp maybe_post(_channel, _ctx, nil), do: {:ok, nil}

  defp maybe_post(channel, ctx, text) do
    {:ok, _} = Runtime.ensure_channel(channel.id)

    case Messages.post_agent_message(channel.id, ctx.agent.id, text) do
      {:ok, message} -> {:ok, message.id}
      {:error, changeset} -> {:error, "could not post: " <> Tool.changeset_reason(changeset)}
    end
  end

  @doc false
  def slug(value) when is_binary(value) do
    slug =
      value
      |> String.trim()
      |> String.trim_leading("#")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    if slug == "", do: {:error, "name is empty"}, else: {:ok, slug}
  end

  def slug(_), do: {:error, "name is empty"}
end
