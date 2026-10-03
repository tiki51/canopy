defmodule Canopy.Locks.Claim do
  @moduledoc """
  One place in a lock's line: the holder (`status: "held"`) or a waiter
  (`"waiting"`, ordered by `inserted_at`). The holder is an agent's session,
  never an agent name, or the user for a lock taken by hand. A lock with no
  claims does not exist.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["lk"]}}
  @foreign_key_type :string

  @statuses ~w(held waiting)

  schema "lock_claims" do
    field :name, :string
    field :reason, :string
    field :status, :string
    field :hold_across_turns, :boolean, default: false
    field :turn_ref, :string
    field :granted_at, :utc_datetime_usec

    belongs_to :repository, Canopy.Repositories.Repository
    belongs_to :session, Canopy.AgentSessions.AgentSession
    belongs_to :user, Canopy.Users.User
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :channel, Canopy.Channels.Channel

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :repository_id,
      :name,
      :session_id,
      :user_id,
      :agent_id,
      :channel_id,
      :reason,
      :status,
      :hold_across_turns,
      :turn_ref,
      :granted_at
    ])
    |> validate_required([:repository_id, :name, :channel_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:reason, max: 500)
    |> validate_holder()
    |> unique_constraint([:repository_id, :name])
    |> unique_constraint([:repository_id, :name, :session_id])
    |> unique_constraint([:repository_id, :name, :user_id])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:channel_id)
  end

  # exactly one of the session and the user
  defp validate_holder(changeset) do
    case {get_field(changeset, :session_id), get_field(changeset, :user_id)} do
      {nil, nil} -> add_error(changeset, :session_id, "a claim needs a session or the user")
      {s, u} when is_binary(s) and is_binary(u) -> add_error(changeset, :user_id, "must be empty")
      _ -> changeset
    end
  end
end
