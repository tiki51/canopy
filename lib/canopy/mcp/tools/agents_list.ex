defmodule Canopy.MCP.Tools.AgentsList do
  @moduledoc """
  List every Canopy agent with its role, then the teams. Members of your
  channel are marked; a team name stands for its active members wherever you
  name agents.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Agents, Channels, Teams}
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
        lines -> {:ok, Enum.join(lines ++ team_lines(ctx, member_ids), "\n")}
      end
    end)
  end

  # One line per team: what it is for, its lead, and its active members.
  defp team_lines(ctx, member_ids) do
    case Teams.list() do
      [] ->
        []

      teams ->
        lines =
          Enum.map(teams, fn team ->
            active = Teams.active_members(team)
            here? = active != [] and Enum.all?(active, &MapSet.member?(member_ids, &1.id))

            markers =
              [
                team.lead && "lead @#{team.lead.name}",
                here? && "in ##{ctx.channel.name}"
              ]
              |> Enum.filter(& &1)
              |> Enum.join(", ")

            members =
              if active == [],
                do: "no active members",
                else: Enum.map_join(active, ", ", &("@" <> &1.name))

            "@#{team.name} (#{markers}): #{team.description || team.display_name} — #{members}"
          end)

        ["", "Teams (a team name stands for its active members wherever you name agents):"] ++
          lines
    end
  end
end
