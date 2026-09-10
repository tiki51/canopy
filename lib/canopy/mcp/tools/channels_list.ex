defmodule Canopy.MCP.Tools.ChannelsList do
  @moduledoc "List the Canopy channels you belong to, with owner and task status. Your current channel is marked."

  use Anubis.Server.Component, type: :tool

  alias Canopy.Channels
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      lines =
        Channels.list()
        |> Enum.filter(fn channel -> Enum.any?(channel.agents, &(&1.id == ctx.agent.id)) end)
        |> Enum.map(&line(&1, ctx))

      case lines do
        [] -> {:ok, "You are not a member of any channel."}
        lines -> {:ok, Enum.join(lines, "\n")}
      end
    end)
  end

  defp line(channel, ctx) do
    markers =
      [
        channel.id == ctx.channel.id && "current",
        Channels.dm?(channel) && "dm with the user",
        channel.status == "archived" && "archived"
      ]
      |> Enum.filter(& &1)

    marker = if markers == [], do: "", else: " (" <> Enum.join(markers, ", ") <> ")"

    task =
      case channel.task do
        nil -> "none"
        task -> "#{task.status} — #{task.title}"
      end

    "##{channel.name} [#{channel.id}]#{marker} in #{channel.repository.name}: " <>
      "owner #{Format.agent_ref(channel.owner)}, task #{task}"
  end
end
