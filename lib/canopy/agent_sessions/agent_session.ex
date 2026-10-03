defmodule Canopy.AgentSessions.AgentSession do
  @moduledoc """
  One engine session owned by an agent inside a channel.

  Each agent has exactly one root session (no parent) per channel, and does
  all its work there, delegations included. Child sessions (with a parent)
  are left from when an agent's delegations ran in sessions of their own;
  they are kept for history and costs but never woken.
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
    # the MCP servers the engine last reported for the session, as
    # `%{"servers" => [%{"name", "status", "tool_count"}]}`, and when
    field :mcp_servers, :map
    field :mcp_servers_seen_at, :utc_datetime_usec
    # when the session was last prompted with the channel's brief as it
    # stood; nil until its first prompt (see `AgentSessions.mark_brief_seen/1`)
    field :brief_seen_at, :utc_datetime_usec
    # Claude Code sessions: the running cost total the engine reported last
    # (its results are cumulative per session; see `Canopy.ClaudeCode.Cost`)
    field :cost_total, :float

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
