defmodule Canopy.GlobalPermissions.Grant do
  @moduledoc """
  One tool an agent may use anywhere without asking. `tool` is the match key
  (trimmed and downcased, so Claude Code's `Bash` and OpenCode's `bash` are
  one grant); `label` is the name as the engine showed it when granted.
  `channel_id` is where it was granted, nil once that channel is deleted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["gp"]}}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "global_permissions" do
    field :tool, :string
    field :label, :string
    field :granted_at, :utc_datetime_usec
    field :use_count, :integer, default: 0
    field :last_used_at, :utc_datetime_usec

    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :channel, Canopy.Channels.Channel

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :id,
      :agent_id,
      :tool,
      :label,
      :channel_id,
      :granted_at,
      :use_count,
      :last_used_at
    ])
    |> validate_required([:agent_id, :tool, :label, :granted_at])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:channel_id)
    |> unique_constraint([:agent_id, :tool])
  end
end
