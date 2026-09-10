defmodule Canopy.MCP.Tools.ChannelAddMembers do
  @moduledoc """
  Add agents to a channel you are in. Any member may bring others in; only
  the owner can remove them. A DM's members are fixed (open another with
  `canopy_dm_start` instead).
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Channels
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :agents, {:required, :string},
      description: "Agents to add, comma separated (@name or name)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           :ok <- not_dm(channel),
           {:ok, agents} <- Tool.resolve_agents(Map.get(params, :agents), except: ctx.agent.id),
           :ok <- non_empty(agents) do
        {added, already} =
          Enum.split_with(agents, fn agent ->
            match?({:ok, %Channels.ChannelAgent{}}, Channels.add_agent(channel, agent))
          end)

        {:ok, describe(channel, added, already)}
      end
    end)
  end

  defp not_dm(channel) do
    if Channels.dm?(channel),
      do: {:error, "##{channel.name} is a DM; open another with canopy_dm_start"},
      else: :ok
  end

  defp non_empty([]), do: {:error, "no agents to add"}
  defp non_empty(_), do: :ok

  defp describe(channel, added, already) do
    names = fn agents -> Enum.map_join(agents, ", ", &("@" <> &1.name)) end

    [
      added != [] && "added #{names.(added)} to ##{channel.name}",
      already != [] && "#{names.(already)} already there"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
    |> Kernel.<>(". Mention them in a message when you need them.")
  end
end
