defmodule CanopyWeb.Attachments do
  @moduledoc """
  Uploads and library picks on their way into a message, shared by the
  channel's composers and the Start page's brief. The markup is in
  `CanopyWeb.AttachmentComponents`.
  """

  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]

  alias Canopy.Documents

  @doc """
  Turns every finished upload into a document, in the order the files were
  added. `attrs` go to `Documents.create/1` as given (`user_id`, and
  `origin_channel_id` from a channel). `{:error, stored_ids}` when any file
  couldn't be stored, with the ids of those that were.
  """
  def store_uploads(socket, upload, attrs) do
    results =
      consume_uploaded_entries(socket, upload, fn %{path: path}, entry ->
        result =
          attrs
          |> Map.merge(%{filename: entry.client_name, mime: entry.client_type})
          |> Map.put(:source, {:path, path})
          |> Documents.create()

        case result do
          {:ok, document} -> {:ok, document.id}
          {:error, _} -> {:ok, nil}
        end
      end)

    ids = Enum.reject(results, &is_nil/1)
    if length(ids) == length(results), do: {:ok, ids}, else: {:error, ids}
  end

  @doc "The library picker's files for a search, less the ones already picked."
  def library(q, exclude_ids) do
    Documents.list(search: q, limit: 30) |> Enum.reject(&(&1.id in exclude_ids))
  end
end
