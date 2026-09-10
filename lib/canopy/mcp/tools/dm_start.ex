defmodule Canopy.MCP.Tools.DmStart do
  @moduledoc """
  Open a direct message between the user and you, optionally with other agents,
  and post the first message. DMs always include the user: there is no way to
  talk to another agent without the user seeing it.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Messages, Runtime}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :agents, :string,
      description:
        "Other agents to include, comma separated (@name or name). You and the user are always in. Leave empty for a one-to-one DM."

    field :text, :string,
      description:
        "First message to post in the DM, in Markdown. @name mentions wake those agents; the user sees it in the sidebar."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, others} <- resolve_agents(Map.get(params, :agents), ctx),
           {:ok, dm} <- Channels.ensure_dm(ctx.channel.repository_id, [ctx.agent | others]),
           {:ok, message_id} <- maybe_post(dm, ctx, Tool.blank_to_nil(Map.get(params, :text))) do
        {:ok, describe(dm, message_id)}
      end
    end)
  end

  defp resolve_agents(nil, _ctx), do: {:ok, []}

  defp resolve_agents(value, ctx) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case Tool.resolve_agent(ref) do
        {:ok, %{id: id}} when id == ctx.agent.id -> {:cont, {:ok, acc}}
        {:ok, %{active: false}} -> {:halt, {:error, "#{ref} is deactivated"}}
        {:ok, agent} -> {:cont, {:ok, acc ++ [agent]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.uniq_by(agents, & &1.id)}
      error -> error
    end
  end

  defp maybe_post(_dm, _ctx, nil), do: {:ok, nil}

  defp maybe_post(dm, ctx, text) do
    # The DM's runtime must be up for mentions in the first message to wake anyone.
    {:ok, _} = Runtime.ensure_channel(dm.id)

    case Messages.post_agent_message(dm.id, ctx.agent.id, text) do
      {:ok, message} -> {:ok, message.id}
      {:error, changeset} -> {:error, "could not post: " <> Tool.changeset_reason(changeset)}
    end
  end

  defp describe(dm, message_id) do
    posted = if message_id, do: "; posted [#{message_id}]", else: ""

    "dm [#{dm.id}] ##{dm.name} with the user and #{Channels.dm_label(dm)}#{posted}. " <>
      "Use channel \"#{dm.name}\" with canopy_message_send to continue there."
  end
end
