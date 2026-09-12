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

  # "system": a note the user's command left in the timeline; never wakes an agent
  @kinds ~w(post reply thread_reply system)

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

    has_many :attachments, Canopy.Messages.Attachment, preload_order: [asc: :position]
    has_many :documents, through: [:attachments, :document]

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  @doc """
  Builds a message. `attrs` must carry `:channel_id`, `:body`, and exactly one of
  `:agent_id` / `:user_id`; all values come from code, never from a form.
  With `attachments: true` the body may be blank: the files are the message.
  """
  def changeset(message, attrs, opts \\ []) do
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
    |> validate_required([:channel_id, :kind])
    |> validate_body(Keyword.get(opts, :attachments, false))
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

  # A message needs words unless it carries files.
  defp validate_body(changeset, true) do
    changeset
    |> update_change(:body, &(&1 || ""))
    |> put_change_if_missing(:body, "")
    |> validate_length(:body, max: 100_000)
  end

  defp validate_body(changeset, _no_attachments) do
    changeset
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: 100_000)
  end

  defp put_change_if_missing(changeset, field, value) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, value)
      _ -> changeset
    end
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
