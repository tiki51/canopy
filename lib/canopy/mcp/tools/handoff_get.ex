defmodule Canopy.MCP.Tools.HandoffGet do
  @moduledoc "Read a handoff in full: summary, reason, suggested next step, and the context packet."

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Handoffs}
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :handoff_id, {:required, :string}, description: "Handoff id (ho_…)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, handoff} <- fetch(Map.get(params, :handoff_id)),
           :ok <- check_member(ctx, handoff) do
        {:ok, Format.handoff_block(handoff)}
      end
    end)
  end

  @doc "Loads a handoff by id, returning a tool error for unknown ids."
  def fetch(id) do
    id = Tool.blank_to_nil(id)

    case id && Handoffs.get(id) do
      nil -> {:error, "unknown handoff #{id || "(missing)"}"}
      handoff -> {:ok, handoff}
    end
  end

  defp check_member(ctx, handoff) do
    if Channels.member?(handoff.channel_id, ctx.agent) do
      :ok
    else
      channel = Channels.get(handoff.channel_id)
      {:error, "not a member of ##{(channel && channel.name) || handoff.channel_id}"}
    end
  end
end
