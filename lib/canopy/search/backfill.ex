defmodule Canopy.Search.Backfill do
  @moduledoc """
  Indexes, once at boot, the documents the search index does not know yet
  (those shared before it existed, or any gap). Messages and turns are
  backfilled by the migration; document text lives on disk, so it is read
  here, off the boot path. Idempotent. Off in tests
  (`config :canopy, :search_backfill, false`).
  """

  require Logger

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    if Application.get_env(:canopy, :search_backfill, true),
      do: Task.start_link(&run/0),
      else: :ignore
  end

  @doc "Indexes every document that has no search entry; returns how many."
  def run do
    Canopy.Search.index_missing_documents()
  rescue
    e ->
      Logger.warning("could not index documents for search: #{Exception.message(e)}")
      0
  end
end
