defmodule Canopy.Schedules.Schedule do
  @moduledoc "Something an agent will be woken to do later, once or on a cron."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["sch"]}}
  @foreign_key_type :string

  @kinds ~w(once recurring)
  @statuses ~w(active paused done cancelled)

  schema "schedules" do
    field :instruction, :string
    field :kind, :string
    field :run_at, :utc_datetime_usec
    field :cron, :string
    field :next_run_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :run_count, :integer, default: 0
    field :status, :string, default: "active"
    field :status_reason, :string

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :created_by, Canopy.Agents.Agent, foreign_key: :created_by_agent_id

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :instruction,
      :kind,
      :run_at,
      :cron,
      :next_run_at,
      :last_run_at,
      :run_count,
      :status,
      :status_reason,
      :channel_id,
      :agent_id,
      :created_by_agent_id
    ])
    |> update_change(:instruction, &String.trim/1)
    |> validate_required([:instruction, :kind, :next_run_at, :status, :channel_id, :agent_id])
    |> validate_length(:instruction, min: 1, max: 4_000)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
  end
end
