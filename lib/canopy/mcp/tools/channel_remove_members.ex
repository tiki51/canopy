defmodule Canopy.MCP.Tools.ChannelRemoveMembers do
  @moduledoc """
  Remove agents from a channel you own. Only the owner can remove members, and
  the owner cannot be removed (hand the task off first). DMs are fixed.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Channels
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :agents, {:required, :string},
      description: "Agents to remove, comma separated (@name or name)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           :ok <- owner_check(ctx, channel),
           {:ok, agents} <- Tool.resolve_agents(Map.get(params, :agents), []),
           :ok <- non_empty(agents) do
        {removed, skipped} =
          Enum.reduce(agents, {[], []}, fn agent, {removed, skipped} ->
            case Channels.remove_agent(channel, agent) do
              {:ok, 1} ->
                {removed ++ [agent], skipped}

              {:ok, 0} ->
                {removed, skipped ++ [{agent, "not a member"}]}

              {:error, :owner} ->
                {removed, skipped ++ [{agent, "is the owner; hand the task off first"}]}
            end
          end)

        {:ok, describe(channel, removed, skipped)}
      end
    end)
  end

  defp owner_check(ctx, channel) do
    cond do
      Channels.dm?(channel) ->
        {:error, "##{channel.name} is a DM; its members are fixed"}

      channel.owner_agent_id != ctx.agent.id ->
        {:error, "only the owner of ##{channel.name} can remove members"}

      true ->
        :ok
    end
  end

  defp non_empty([]), do: {:error, "no agents to remove"}
  defp non_empty(_), do: :ok

  defp describe(channel, removed, skipped) do
    [
      removed != [] &&
        "removed #{Enum.map_join(removed, ", ", &("@" <> &1.name))} from ##{channel.name}",
      skipped != [] && Enum.map_join(skipped, "; ", fn {a, why} -> "@#{a.name} #{why}" end)
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
    |> Kernel.<>(".")
  end
end
