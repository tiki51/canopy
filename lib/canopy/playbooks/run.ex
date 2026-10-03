defmodule Canopy.Playbooks.Run do
  @moduledoc """
  One run of a playbook in a channel. It keeps the playbook's text as it was
  when the run started (`definition`), the roster resolved then, and where
  the run is (`current_step`). Steps are `Canopy.Playbooks.Step` rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["pbr"]}}
  @foreign_key_type :string

  @statuses ~w(active awaiting_approval completed cancelled)
  @live ~w(active awaiting_approval)

  schema "playbook_runs" do
    field :playbook_name, :string
    field :definition, :string
    field :brief, :string
    field :roster, :map, default: %{}
    field :status, :string, default: "active"
    field :current_step, :string
    field :trigger, :map
    field :outcome, :string
    field :finished_at, :utc_datetime_usec
    field :stall_after_minutes, :integer
    field :last_activity_at, :utc_datetime_usec
    field :nudged_at, :utc_datetime_usec
    # every transition bumps it; one that read an older version fails
    field :lock_version, :integer, default: 1

    belongs_to :playbook, Canopy.Playbooks.Playbook
    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :coordinator, Canopy.Agents.Agent, foreign_key: :coordinator_agent_id
    belongs_to :started_by, Canopy.Agents.Agent, foreign_key: :started_by_agent_id
    has_many :steps, Canopy.Playbooks.Step, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "The statuses of a run still in progress (one per channel at most)."
  def live_statuses, do: @live

  def live?(%__MODULE__{status: status}), do: status in @live

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :playbook_id,
      :playbook_name,
      :definition,
      :channel_id,
      :coordinator_agent_id,
      :started_by_agent_id,
      :brief,
      :roster,
      :status,
      :current_step,
      :trigger,
      :outcome,
      :finished_at,
      :stall_after_minutes,
      :last_activity_at,
      :nudged_at
    ])
    |> update_change(:brief, &String.trim/1)
    |> validate_required([:playbook_name, :definition, :channel_id, :brief, :status])
    |> validate_length(:brief, min: 1, max: 8_000)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:channel_id,
      message: "already has a playbook run in progress"
    )
    |> foreign_key_constraint(:channel_id)
  end
end
