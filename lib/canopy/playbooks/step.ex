defmodule Canopy.Playbooks.Step do
  @moduledoc """
  One step of a run: its owners (roles as written, and the agents they
  resolved to; empty for the coordinator's own steps), where it is, how many
  times it has been entered (`round`), and the coordinator's `result`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["pbs"]}}
  @foreign_key_type :string

  @statuses ~w(pending active awaiting_approval done skipped)

  schema "playbook_steps" do
    field :step_id, :string
    field :position, :integer
    field :title, :string
    field :owner_roles, {:array, :string}, default: []
    field :owner_ids, {:array, :string}, default: []
    field :approval, :boolean, default: false
    field :optional, :boolean, default: false
    field :status, :string, default: "pending"
    field :round, :integer, default: 0
    field :result, :string
    # an approval step: the step the coordinator asked for once it is approved
    field :approval_next, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec

    belongs_to :run, Canopy.Playbooks.Run
    has_many :delegations, Canopy.Delegations.Delegation, foreign_key: :playbook_step_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :run_id,
      :step_id,
      :position,
      :title,
      :owner_roles,
      :owner_ids,
      :approval,
      :optional,
      :status,
      :round,
      :result,
      :approval_next,
      :started_at,
      :completed_at,
      :approved_at
    ])
    |> validate_required([:step_id, :position, :title, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:result, max: 20_000)
    |> unique_constraint([:run_id, :step_id])
  end
end
