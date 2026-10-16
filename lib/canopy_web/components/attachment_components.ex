defmodule CanopyWeb.AttachmentComponents do
  @moduledoc """
  Files on their way into a message: the chips for picked and uploading
  files, and the dialog that picks a file already shared in Canopy. The
  channel's composers and the Start page's brief share them; each page owns
  its upload config and handles the events (`unpick_document`,
  `cancel_upload`, `pick_document`, `search_library`, `close_library`).
  The upload helpers are in `CanopyWeb.Attachments`.
  """

  use CanopyWeb, :html

  alias Canopy.{Documents, Messages}

  @doc """
  The picked files (from the library, or kept after a failed start), then
  the uploads with their progress or errors, then the upload's own errors.
  Renders nothing until there is a file.
  """
  attr :id, :string, required: true, doc: "the container's id, used as given"
  attr :item, :string, default: "", doc: "prefix of each chip's id"
  attr :upload, :any, required: true
  attr :picked, :list, required: true
  attr :target, :string, default: nil, doc: "sent with `unpick_document`"

  def file_chips(assigns) do
    ~H"""
    <div
      :if={@upload.entries != [] or @picked != []}
      id={@id}
      class="mb-2 flex flex-wrap gap-2"
    >
      <div
        :for={doc <- @picked}
        id={"#{@item}picked-#{doc.id}"}
        class="flex max-w-xs items-center gap-2 rounded-lg border border-primary/40 bg-base-100 px-2 py-1 text-xs"
        title="From the files library"
      >
        <img
          :if={doc.kind == "image"}
          src={Documents.url_path(doc)}
          alt=""
          class="size-8 rounded object-cover"
        />
        <.icon
          :if={doc.kind != "image"}
          name="hero-document-mini"
          class="size-4 shrink-0 text-base-content/60"
        />
        <div class="min-w-0">
          <div class="truncate font-medium" title={doc.filename}>{doc.filename}</div>
          <div class="text-base-content/60">shared · {Documents.size_label(doc.byte_size)}</div>
        </div>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="unpick_document"
          phx-value-id={doc.id}
          phx-value-target={@target}
          title="Remove"
          aria-label={"Remove #{doc.filename}"}
        >
          <.icon name="hero-x-mark-mini" class="size-3.5" />
        </button>
      </div>
      <div
        :for={entry <- @upload.entries}
        id={"#{@item}upload-#{entry.ref}"}
        class="flex max-w-xs items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2 py-1 text-xs"
      >
        <.live_img_preview
          :if={String.starts_with?(entry.client_type || "", "image/")}
          entry={entry}
          class="size-8 rounded object-cover"
        />
        <.icon
          :if={!String.starts_with?(entry.client_type || "", "image/")}
          name="hero-document-mini"
          class="size-4 shrink-0 text-base-content/60"
        />
        <div class="min-w-0">
          <div class="truncate font-medium" title={entry.client_name}>{entry.client_name}</div>
          <div
            :if={!entry.done? and upload_errors(@upload, entry) == []}
            class="text-base-content/60"
          >
            {entry.progress}%
          </div>
          <div :for={err <- upload_errors(@upload, entry)} class="text-error">
            {upload_error(err)}
          </div>
        </div>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="cancel_upload"
          phx-value-ref={entry.ref}
          phx-value-upload={@upload.name}
          title="Remove"
          aria-label={"Remove #{entry.client_name}"}
        >
          <.icon name="hero-x-mark-mini" class="size-3.5" />
        </button>
      </div>
    </div>
    <div :for={err <- upload_errors(@upload)} class="mb-1 px-1 text-xs text-error">
      {upload_error(err)}
    </div>
    """
  end

  @doc "The dialog that attaches a file already shared in Canopy."
  attr :library, :map, required: true, doc: "`%{q, documents}`"
  attr :hint, :string, required: true, doc: "the line under the title: where a pick goes"

  def library_picker(assigns) do
    ~H"""
    <div
      id="library-picker"
      class="fixed inset-0 z-40 flex items-center justify-center bg-black/40 dark:bg-black/50 p-4"
      phx-window-keydown="close_library"
      phx-key="Escape"
    >
      <div
        id="library-dialog"
        class="flex max-h-[80vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-200 shadow-2xl"
        phx-click-away="close_library"
      >
        <div class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-3">
          <div>
            <h2 class="text-sm font-semibold">Attach a shared file</h2>
            <p class="mt-0.5 text-xs text-base-content/60">{@hint}</p>
          </div>
          <button
            type="button"
            id="close-library"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="close_library"
            aria-label="Close"
          >
            <.icon name="hero-x-mark-mini" class="size-4" />
          </button>
        </div>
        <form
          id="library-search"
          phx-change="search_library"
          phx-submit="search_library"
          class="px-5 py-3"
        >
          <input
            type="search"
            name="q"
            value={@library.q}
            placeholder="Search by name"
            class="input input-sm w-full"
            phx-debounce="200"
            autocomplete="off"
            autofocus
          />
        </form>
        <ul id="library-documents" class="min-h-0 flex-1 divide-y divide-base-300 overflow-y-auto">
          <li
            :if={@library.documents == []}
            class="px-5 py-6 text-center text-sm text-base-content/60"
          >
            Nothing shared yet.
          </li>
          <li :for={doc <- @library.documents}>
            <button
              type="button"
              id={"library-#{doc.id}"}
              class="flex w-full items-center gap-3 px-5 py-2 text-left text-sm hover:bg-base-300/50"
              phx-click="pick_document"
              phx-value-id={doc.id}
            >
              <span class="flex size-9 shrink-0 items-center justify-center overflow-hidden rounded bg-base-100">
                <img
                  :if={doc.kind == "image"}
                  src={Documents.url_path(doc)}
                  alt=""
                  loading="lazy"
                  class="size-9 object-cover"
                />
                <.icon
                  :if={doc.kind != "image"}
                  name="hero-document-text"
                  class="size-5 text-base-content/60"
                />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate font-medium">{doc.filename}</span>
                <span class="block text-xs text-base-content/60">
                  {doc.kind} · {Documents.size_label(doc.byte_size)} · {library_sharer(doc)}
                </span>
              </span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp library_sharer(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp library_sharer(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp library_sharer(_), do: "unknown"

  @doc "An upload error in words."
  def upload_error(:too_large),
    do: "Too large; the limit is #{Documents.size_label(Documents.max_bytes())}."

  def upload_error(:too_many_files),
    do: "At most #{Messages.max_attachments()} files at a time."

  def upload_error(:not_accepted), do: "That file type is not accepted."
  def upload_error(other), do: "Upload failed (#{other})."
end
