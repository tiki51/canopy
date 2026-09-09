defmodule Canopy.Delegations.Delegation do
  @moduledoc "A bounded subtask handed to another agent. Ownership never changes."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["dl"]}}
  @foreign_key_type :string

  @statuses ~w(requested working completed failed cancelled)

  schema "delegations" do
    field :description, :string
    field :status, :string, default: "requested"
    field :result, :string
    field :completed_at, :utc_datetime_usec

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :task, Canopy.Tasks.Task
    belongs_to :from_agent, Canopy.Agents.Agent
    belongs_to :to_agent, Canopy.Agents.Agent
    belongs_to :parent_session, Canopy.AgentSessions.AgentSession
    belongs_to :child_session, Canopy.AgentSessions.AgentSession

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(delegation, attrs) do
    delegation
    |> cast(attrs, [
      :channel_id,
      :task_id,
      :from_agent_id,
      :to_agent_id,
      :parent_session_id,
      :child_session_id,
      :description,
      :status,
      :result,
      :completed_at
    ])
    |> update_change(:description, &String.trim/1)
    |> validate_required([:channel_id, :to_agent_id, :description, :status])
    |> validate_length(:description, min: 1, max: 20_000)
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self()
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:from_agent_id)
    |> foreign_key_constraint(:to_agent_id)
    |> foreign_key_constraint(:parent_session_id)
    |> foreign_key_constraint(:child_session_id)
  end

  defp validate_not_self(changeset) do
    from = get_field(changeset, :from_agent_id)
    to = get_field(changeset, :to_agent_id)

    if from != nil and from == to do
      add_error(changeset, :to_agent_id, "cannot delegate to yourself")
    else
      changeset
    end
  end
end
