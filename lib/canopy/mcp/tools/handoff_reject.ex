defmodule Canopy.MCP.Tools.HandoffReject do
  @moduledoc "Reject a handoff addressed to you, with a reason. The previous owner keeps the task and is notified."

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Handoffs}
  alias Canopy.MCP.{Format, Tool}
  alias Canopy.MCP.Tools.{HandoffAccept, HandoffGet}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :handoff_id, {:required, :string}, description: "Handoff id (ho_…)."
    field :reason, {:required, :string}, description: "Why you are not taking the task."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, handoff} <- HandoffGet.fetch(Map.get(params, :handoff_id)),
           :ok <- HandoffAccept.check_target(ctx, handoff),
           {:ok, reason} <- reason(params),
           {:ok, handoff} <- reject(handoff, reason) do
        channel = Channels.get(handoff.channel_id)

        {:ok,
         "rejected handoff [#{handoff.id}]; #{Format.agent_ref(handoff.from_agent)} keeps ##{channel.name} " <>
           "and will see your reason."}
      end
    end)
  end

  defp reason(params) do
    case Tool.blank_to_nil(Map.get(params, :reason)) do
      nil -> {:error, "reason is empty"}
      reason -> {:ok, reason}
    end
  end

  defp reject(handoff, reason) do
    case Handoffs.reject(handoff, reason) do
      {:ok, handoff} -> {:ok, handoff}
      {:error, :not_pending} -> {:error, "handoff #{handoff.id} is already #{handoff.status}"}
      {:error, changeset} -> {:error, "could not reject: " <> Tool.changeset_reason(changeset)}
    end
  end
end
