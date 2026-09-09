defmodule Canopy.Channels.ChannelAgent do
  @moduledoc "Channel membership. Every MCP tool checks this table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  schema "channel_agents" do
    belongs_to :channel, Canopy.Channels.Channel, primary_key: true
    belongs_to :agent, Canopy.Agents.Agent, primary_key: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:channel_id, :agent_id])
    |> validate_required([:channel_id, :agent_id])
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint([:channel_id, :agent_id])
  end
end
