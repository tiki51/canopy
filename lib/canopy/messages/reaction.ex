defmodule Canopy.Messages.Reaction do
  @moduledoc """
  One emoji reaction on a message, by the user or by an agent. Exactly one of
  `agent_id` / `user_id` identifies the reactor; the database enforces it with
  the `message_reactions_reactor_check` constraint and the changeset mirrors
  the rule. `emoji` is a palette key (`Canopy.Reactions.palette/0`), never the
  glyph. The id is time-ordered, so it doubles as the "since your last read"
  cursor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["rx"]}}
  @foreign_key_type :string

  schema "message_reactions" do
    field :emoji, :string

    belongs_to :message, Canopy.Messages.Message
    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :user, Canopy.Users.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds a reaction. `attrs` carry `:message_id`, `:channel_id`, `:emoji` and
  exactly one of `:agent_id` / `:user_id`; all values come from code.
  """
  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :channel_id, :emoji, :agent_id, :user_id])
    |> validate_required([:message_id, :channel_id, :emoji])
    |> validate_inclusion(:emoji, Canopy.Reactions.keys())
    |> validate_reactor()
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:user_id,
      name: :message_reactions_reactor_check,
      message: "exactly one of agent_id or user_id must be set"
    )
    # SQLite names a failed unique index by its columns
    |> unique_constraint([:message_id, :emoji, :agent_id])
    |> unique_constraint([:message_id, :emoji, :user_id])
  end

  defp validate_reactor(changeset) do
    agent_id = get_field(changeset, :agent_id)
    user_id = get_field(changeset, :user_id)

    if is_nil(agent_id) == is_nil(user_id) do
      add_error(changeset, :user_id, "exactly one of agent_id or user_id must be set")
    else
      changeset
    end
  end
end
