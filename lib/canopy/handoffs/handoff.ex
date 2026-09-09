defmodule Canopy.Handoffs.Handoff do
  @moduledoc "A transfer of task ownership from one agent to another, with a context packet."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["ho"]}}
  @foreign_key_type :string

  @statuses ~w(requested accepted rejected cancelled)

  schema "handoffs" do
    field :status, :string, default: "requested"
    field :summary, :string
    field :reason, :string
    field :suggested_next_step, :string
    field :rejection_reason, :string
    field :packet, :map, default: %{}
    field :accepted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :task, Canopy.Tasks.Task
    belongs_to :from_agent, Canopy.Agents.Agent
    belongs_to :to_agent, Canopy.Agents.Agent
    belongs_to :source_session, Canopy.AgentSessions.AgentSession
    belongs_to :target_session, Canopy.AgentSessions.AgentSession

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [
      :channel_id,
      :task_id,
      :from_agent_id,
      :to_agent_id,
      :source_session_id,
      :target_session_id,
      :status,
      :summary,
      :reason,
      :suggested_next_step,
      :rejection_reason,
      :packet,
      :accepted_at,
      :completed_at
    ])
    |> update_change(:summary, &String.trim/1)
    |> validate_required([:channel_id, :to_agent_id, :summary, :status])
    |> validate_length(:summary, min: 1, max: 20_000)
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self()
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:from_agent_id)
    |> foreign_key_constraint(:to_agent_id)
    |> foreign_key_constraint(:source_session_id)
    |> foreign_key_constraint(:target_session_id)
  end

  defp validate_not_self(changeset) do
    from = get_field(changeset, :from_agent_id)
    to = get_field(changeset, :to_agent_id)

    if from != nil and from == to do
      add_error(changeset, :to_agent_id, "cannot hand off to yourself")
    else
      changeset
    end
  end
end
