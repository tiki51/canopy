defmodule Canopy.EnginePauses.PauseAgent do
  @moduledoc """
  An agent a pause touches in one channel: `waiting` for the reset (with its
  Auto nudge schedule when the reset time is known), or on its `fallback`.
  `noted` says this state's timeline line is already written.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["epa"]}}
  @foreign_key_type :string

  @states ~w(waiting fallback)

  @type t :: %__MODULE__{}

  schema "engine_pause_agents" do
    field :state, :string
    field :noted, :boolean, default: false

    belongs_to :pause, Canopy.EnginePauses.Pause
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :schedule, Canopy.Schedules.Schedule

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
end
