defmodule Canopy.Messages.Attachment do
  @moduledoc """
  Links a document to a message. Sharing a document into another chat adds a
  row here; the bytes are never copied. `position` keeps the order the files
  were attached in.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  schema "message_attachments" do
    belongs_to :message, Canopy.Messages.Message, primary_key: true
    belongs_to :document, Canopy.Documents.Document, primary_key: true
    field :position, :integer, default: 0
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:message_id, :document_id, :position])
    |> validate_required([:message_id, :document_id])
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:document_id)
    |> unique_constraint([:message_id, :document_id],
      name: :message_attachments_message_id_document_id_index
    )
  end
end
