defmodule Canopy.AgentSessions.AgentSession do
  @moduledoc """
  One engine session owned by an agent inside a channel.

  Each agent has exactly one root session (no parent) per channel; delegations
  create child sessions that point at the delegator's session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["as"]}}
  @foreign_key_type :string

  @statuses ~w(idle busy error)

  @type t :: %__MODULE__{}

  schema "agent_sessions" do
    # the engine that owns the session and its id there (see `Canopy.Engine`)
    field :engine, :string, default: "opencode"
    field :engine_session_id, :string
    # Claude Code sessions: the bearer token their MCP connection presents
    field :mcp_token, :string, redact: true
    field :status, :string, default: "idle"
    field :last_error, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :parent_session, __MODULE__
    has_many :child_sessions, __MODULE__, foreign_key: :parent_session_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :channel_id,
      :agent_id,
      :engine,
      :engine_session_id,
      :mcp_token,
      :parent_session_id,
      :status,
      :last_error,
      :last_seen_at
    ])
    |> validate_required([:channel_id, :agent_id, :engine, :engine_session_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:parent_session_id)
    |> unique_constraint([:engine, :engine_session_id], error_key: :engine_session_id)
    |> unique_constraint(:mcp_token)
    |> unique_constraint([:channel_id, :agent_id],
      message: "already has a root session in this channel"
    )
  end

  def status_changeset(session, status, error) do
    session
    |> change(status: status, last_error: error)
    |> validate_inclusion(:status, @statuses)
  end
end
