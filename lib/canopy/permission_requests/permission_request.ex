defmodule Canopy.PermissionRequests.PermissionRequest do
  @moduledoc "An OpenCode permission prompt, stored with the event payload as received."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["pr"]}}
  @foreign_key_type :string

  @statuses ~w(pending once always rejected)

  schema "permission_requests" do
    field :opencode_permission_id, :string
    field :permission, :string
    field :patterns, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :tool_call_id, :string
    field :status, :string, default: "pending"
    field :resolved_at, :utc_datetime_usec

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent_session, Canopy.AgentSessions.AgentSession

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :channel_id,
      :agent_session_id,
      :opencode_permission_id,
      :permission,
      :patterns,
      :metadata,
      :tool_call_id,
      :status,
      :resolved_at
    ])
    |> validate_required([
      :channel_id,
      :agent_session_id,
      :opencode_permission_id,
      :permission,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_session_id)
    |> unique_constraint(:opencode_permission_id)
  end
end
