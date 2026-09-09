defmodule Canopy.MCP.Tools.ChannelGet do
  @moduledoc "Get the state of a channel in one call: owner, task, members, branch, last handoff, and the most recent messages."

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Handoffs, Messages, Repositories, Timeline}
  alias Canopy.MCP.{Format, Tool}

  @handoff_events ~w(handoff_requested handoff_accepted handoff_rejected)

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)) do
        {:ok, render(channel)}
      end
    end)
  end

  defp render(channel) do
    repository = channel.repository

    branch =
      case Repositories.current_branch(repository) do
        {:ok, branch} -> branch
        {:error, _} -> "unknown"
      end

    members = channel |> Channels.members() |> Enum.map_join(", ", &Format.agent_ref/1)
    task = Canopy.Tasks.for_channel(channel.id)
    recent = Messages.list(channel.id, limit: 5)

    [
      "##{channel.name} [#{channel.id}] #{channel.status} in #{repository.name} (#{repository.path}), branch #{branch}",
      Format.optional_line("Topic: ", channel.topic),
      "Owner: #{Format.agent_ref(channel.owner)}",
      Format.task_block(task),
      "Members: #{members}",
      handoff_line(channel),
      "Recent messages (oldest first):",
      recent |> Enum.map(&Format.message_line(&1, bodies: false)) |> preview(recent)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp preview([], _), do: "(no messages yet)"

  defp preview(lines, messages) do
    lines
    |> Enum.zip(messages)
    |> Enum.map_join("\n", fn {line, message} ->
      "#{line}: #{message.body |> Format.single_line() |> Format.truncate(80)}"
    end)
  end

  defp handoff_line(channel) do
    case Handoffs.pending_for_channel(channel.id) do
      [handoff | _] ->
        "Pending handoff: [#{handoff.id}] #{Format.agent_ref(handoff.from_agent)} → " <>
          "#{Format.agent_ref(handoff.to_agent)}: #{Format.truncate(Format.single_line(handoff.summary), 120)}"

      [] ->
        last_handoff_line(channel)
    end
  end

  defp last_handoff_line(channel) do
    with [event] <- Timeline.list(channel.id, types: @handoff_events, limit: 1),
         %{} = handoff <- Handoffs.get(event.ref_id) do
      "Last handoff: [#{handoff.id}] #{handoff.status}, " <>
        "#{Format.agent_ref(handoff.from_agent)} → #{Format.agent_ref(handoff.to_agent)}"
    else
      _ -> "Last handoff: none"
    end
  end
end
