defmodule Canopy.Watches.Item do
  @moduledoc "One item (`pr:12`, `run:9001`) a watch has seen; a key not here is new."

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["wi"]}}
  @foreign_key_type :string

  schema "watch_items" do
    field :key, :string
    belongs_to :schedule, Canopy.Schedules.Schedule

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
