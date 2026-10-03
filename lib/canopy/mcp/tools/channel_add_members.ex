defmodule Canopy.MCP.Tools.ChannelAddMembers do
  @moduledoc """
  Add agents or teams to a channel you are in. Any member may bring others
  in; only the owner can remove them. A team brings its active members, as
  they are now. Adding wakes nobody. A DM's members are fixed (open another
  with `canopy_dm_start` instead).
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Channels
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :agents, {:required, :string},
      description: "Agents or teams to add, comma separated (@name)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           :ok <- not_dm(channel),
           {:ok, agents, teams} <-
             Tool.resolve_members(Map.get(params, :agents), except: ctx.agent.id),
           :ok <- non_empty(agents, teams) do
        # teams first, so an agent named on its own after its team reads as already there
        team_results =
          Enum.map(teams, fn team ->
            {:ok, result} = Channels.add_team(channel, team, ctx.agent.id)
            {team, result}
          end)

        {added, already} =
          Enum.split_with(agents, fn agent ->
            match?({:ok, %Channels.ChannelAgent{}}, Channels.add_agent(channel, agent))
          end)

        {:ok, describe(channel, team_results, added, already)}
      end
    end)
  end

  defp not_dm(channel) do
    if Channels.dm?(channel),
      do: {:error, "##{channel.name} is a DM; open another with canopy_dm_start"},
      else: :ok
  end

  defp non_empty([], []), do: {:error, "no agents to add"}
  defp non_empty(_agents, _teams), do: :ok

  defp describe(channel, team_results, added, already) do
    names = fn agents -> Enum.map_join(agents, ", ", &("@" <> &1.name)) end

    already =
      Enum.flat_map(team_results, fn {_team, r} -> r.already end)
      |> Kernel.++(already)
      |> Enum.uniq_by(& &1.id)

    teams =
      Enum.map(team_results, fn
        {team, %{added: []}} -> "nobody new from @#{team.name}"
        {team, %{added: members}} -> "@#{team.name} (#{names.(members)})"
      end)

    added_part =
      case teams ++ if(added == [], do: [], else: [names.(added)]) do
        [] -> nil
        parts -> "added #{Enum.join(parts, ", ")} to ##{channel.name}"
      end

    mention =
      case team_results do
        [] ->
          "Mention them in a message when you need them."

        teams ->
          "Mention #{Enum.map_join(teams, " or ", fn {t, _} -> "@" <> t.name end)} when you need them."
      end

    [added_part, already != [] && "#{names.(already)} already there"]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
    |> Kernel.<>(". " <> mention)
  end
end
