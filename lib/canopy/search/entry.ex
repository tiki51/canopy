defmodule Canopy.Search.Entry do
  @moduledoc """
  One searchable item: a message, a finished turn (its `agent_turn_completed`
  event), or a document. Its rowid is shared with the `search_fts` full-text
  table, which holds the text (`title`, `body`, `paths`). Triggers write the
  rows for messages and turns; `Canopy.Search.index_document/2` writes a
  document's. The columns are what the search filters need: the channel
  (a document's origin channel, may be nil), the sender, the thread root, and
  the source row's time.
  """

  use Ecto.Schema

  @sources ~w(message turn document)

  schema "search_entries" do
    field :source, :string
    field :ref_id, :string
    field :channel_id, :string
    field :agent_id, :string
    field :user_id, :string
    field :thread_id, :string
    field :inserted_at, :utc_datetime_usec
  end

  def sources, do: @sources
end
