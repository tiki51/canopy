defmodule Canopy.EnginePauses.Pause do
  @moduledoc """
  An engine paused at a usage or billing limit. One active row per engine
  (`lifted_at` nil); lifted rows are kept as history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["ep"]}}
  @foreign_key_type :string

  @kinds ~w(usage billing)

  @type t :: %__MODULE__{}

  schema "engine_pauses" do
    field :engine, :string
    # usage: a window that resets; billing: a balance, credits or a spend cap
    field :kind, :string
    # short and human: "usage limit", "weekly usage limit", "insufficient balance"
    field :reason, :string
    # the engine's full error text
    field :detail, :string
    # nil: unknown, the pause lasts until Release
    field :resets_at, :utc_datetime_usec
    # the status_reason it gave the schedules it paused, so resuming finds exactly those
    field :schedule_reason, :string
    field :paused_at, :utc_datetime_usec
    field :lifted_at, :utc_datetime_usec
    # "reset" | "user"
    field :lifted_by, :string

    has_many :agents, Canopy.EnginePauses.PauseAgent

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(pause, attrs) do
    pause
    |> cast(attrs, [:engine, :kind, :reason, :detail, :resets_at, :schedule_reason, :paused_at])
    |> validate_required([:engine, :kind, :reason, :schedule_reason, :paused_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:engine, name: :engine_pauses_active_engine_index)
  end
end
