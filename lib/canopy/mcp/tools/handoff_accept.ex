defmodule Canopy.MCP.Tools.HandoffAccept do
  @moduledoc """
  Accept a handoff addressed to you. You become the owner of the channel and
  its task; the previous owner is notified. Inspect the repository and the
  handoff packet (handoff_get) before accepting.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Handoffs}
  alias Canopy.MCP.Tool
  alias Canopy.MCP.Tools.HandoffGet

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :handoff_id, {:required, :string}, description: "Handoff id (ho_…)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, handoff} <- HandoffGet.fetch(Map.get(params, :handoff_id)),
           :ok <- check_target(ctx, handoff),
           {:ok, handoff} <- accept(handoff) do
        channel = Channels.get(handoff.channel_id)

        next_step =
          if handoff.suggested_next_step,
            do: " Suggested next step: #{handoff.suggested_next_step}",
            else: ""

        {:ok,
         "accepted handoff [#{handoff.id}]; you now own ##{channel.name} and its task.#{next_step}"}
      end
    end)
  end

  @doc "Only the handoff's target may act on it."
  def check_target(ctx, handoff) do
    if handoff.to_agent_id == ctx.agent.id do
      :ok
    else
      {:error, "handoff #{handoff.id} is not addressed to you"}
    end
  end

  defp accept(handoff) do
    case Handoffs.accept(handoff) do
      {:ok, handoff} -> {:ok, handoff}
      {:error, :not_pending} -> {:error, "handoff #{handoff.id} is already #{handoff.status}"}
      {:error, changeset} -> {:error, "could not accept: " <> Tool.changeset_reason(changeset)}
    end
  end
end
