defmodule Canopy.Documents.Document do
  @moduledoc """
  A file shared in Canopy: a screenshot the user pasted, a report an agent
  wrote. One row per upload; the bytes live in `Canopy.Documents.Store` under
  the document id. Messages point at documents through
  `Canopy.Messages.Attachment`, so one document can appear in many chats.

  `kind` is derived from the MIME type and decides how the file is rendered
  and what agents receive: `image` (shown inline, sent to models as an image),
  `text` (readable through tools, sent as `text/plain`), `pdf`, or `other`
  (download only).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["doc"]}}
  @foreign_key_type :string

  @kinds ~w(image text pdf other)

  schema "documents" do
    field :filename, :string
    field :mime, :string
    field :kind, :string
    field :byte_size, :integer
    field :sha256, :string
    field :caption, :string

    belongs_to :user, Canopy.Users.User
    belongs_to :agent, Canopy.Agents.Agent
    belongs_to :origin_channel, Canopy.Channels.Channel

    has_many :attachments, Canopy.Messages.Attachment
    has_many :messages, through: [:attachments, :message]

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  @doc "Builds a document. All values come from code, never straight from a form."
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :filename,
      :mime,
      :kind,
      :byte_size,
      :sha256,
      :caption,
      :user_id,
      :agent_id,
      :origin_channel_id
    ])
    |> validate_required([:filename, :mime, :kind, :byte_size, :sha256])
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_length(:caption, max: 500)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_uploader()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:origin_channel_id)
    |> check_constraint(:user_id,
      name: :documents_uploader_check,
      message: "exactly one of agent_id or user_id must be set"
    )
  end

  defp validate_uploader(changeset) do
    agent_id = get_field(changeset, :agent_id)
    user_id = get_field(changeset, :user_id)

    if is_nil(agent_id) == is_nil(user_id) do
      add_error(changeset, :user_id, "exactly one of agent_id or user_id must be set")
    else
      changeset
    end
  end
end
