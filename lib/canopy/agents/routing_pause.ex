defmodule Canopy.Agents.RoutingPause do
  @moduledoc """
  A model routing rule paused for one agent: wakes of `wake_kind` (or every
  kind, `"*"`) run on the main model until the user resumes it. Paused when
  too many of its light turns escalated, or when the light model failed.
  A resumed rule keeps its row with `resumed_at` set: the escalation window
  that decides the next pause starts there.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["rtp"]}}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "routing_pauses" do
    belongs_to :agent, Canopy.Agents.Agent
    field :wake_kind, :string
    field :reason, :string
    # nil once resumed (the row then only remembers when the window restarted)
    field :paused_at, :utc_datetime_usec
    field :resumed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "True while the rule is paused."
  def paused?(%__MODULE__{paused_at: at}), do: not is_nil(at)
end
