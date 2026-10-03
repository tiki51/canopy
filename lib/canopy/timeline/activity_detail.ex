defmodule Canopy.Timeline.ActivityDetail do
  @moduledoc """
  The per-row details of a finished turn's activity card, one row per
  `agent_turn_completed` timeline event: `details` maps each card row's key
  to what opening it shows (see `Canopy.Runtime.Activity.details_payload/1`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:event_id, :string, autogenerate: false}

  schema "turn_activity_details" do
    field :details, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
