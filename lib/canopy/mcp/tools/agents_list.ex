defmodule Canopy.MCP.Tools.AgentsList do
  @moduledoc "List every Canopy agent with its role. Members of your channel are marked."

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Agents, Channels}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      member_ids = ctx.channel |> Channels.members() |> MapSet.new(& &1.id)

      lines =
        Agents.list()
        |> Enum.map(fn agent ->
          markers =
            [
              agent.id == ctx.agent.id && "you",
              MapSet.member?(member_ids, agent.id) && "in ##{ctx.channel.name}",
              not agent.active && "inactive"
            ]
            |> Enum.filter(& &1)

          marker = if markers == [], do: "", else: " (" <> Enum.join(markers, ", ") <> ")"
          "@#{agent.name}#{marker}: #{agent.role || "no role"}"
        end)

      case lines do
        [] -> {:ok, "No agents are configured."}
        lines -> {:ok, Enum.join(lines, "\n")}
      end
    end)
  end
end
