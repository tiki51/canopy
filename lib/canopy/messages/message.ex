defmodule Canopy.Messages.Message do
  @moduledoc """
  A durable channel message. Exactly one of `agent_id` / `user_id` identifies
  the sender; the database enforces it with the `messages_sender_check`
  constraint and the changeset mirrors the rule.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["msg"]}}
  @foreign_key_type :string

  @kinds ~w(post reply thread_reply)

  schema "messages" do
    field :kind, :string, default: "post"
    field :body, :string
    field :mentions, {:array, :string}, default: []
    field :opencode_message_id, :string

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :user, Canopy.Users.User
    belongs_to :thread, __MODULE__
    has_many :replies, __MODULE__, foreign_key: :thread_id

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  @doc """
  Builds a message. `attrs` must carry `:channel_id`, `:body`, and exactly one of
  `:agent_id` / `:user_id`; all values come from code, never from a form.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :channel_id,
      :agent_id,
      :user_id,
      :thread_id,
      :kind,
      :body,
      :mentions,
      :opencode_message_id
    ])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:channel_id, :kind, :body])
    |> validate_length(:body, min: 1, max: 100_000)
    |> validate_inclusion(:kind, @kinds)
    |> validate_sender()
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:thread_id)
    |> check_constraint(:user_id,
      name: :messages_sender_check,
      message: "exactly one of agent_id or user_id must be set"
    )
  end

  defp validate_sender(changeset) do
    agent_id = get_field(changeset, :agent_id)
    user_id = get_field(changeset, :user_id)

    if is_nil(agent_id) == is_nil(user_id) do
      add_error(changeset, :user_id, "exactly one of agent_id or user_id must be set")
    else
      changeset
    end
  end
end
