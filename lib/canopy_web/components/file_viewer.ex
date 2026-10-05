defmodule CanopyWeb.FileViewer do
  @moduledoc """
  The file viewer: a full-screen lightbox over a channel that shows one of a
  message's files (`?file=<doc id>&in=<message id>`, see `CanopyWeb.ChannelLive`).
  Images open at Fit with client-side zoom, Markdown renders as a document
  (Preview) or highlighted source (Source), code and text open with line
  numbers, PDFs in a frame, and anything else as a "no preview" card. ‹ › and
  a thumbnail strip move through the message's other files, in the order the
  message shows them (`ordered/1`: images first).

  `load/3` is pure apart from reading the file; `viewer/1` renders the
  `<dialog>`. The FileViewer hook (`assets/js/hooks/file_viewer.js`) opens it
  modally and owns what never needs the server: keys, focus, zoom, Wrap, the
  Markdown mode and Copy (which fetches the file's own bytes). That state
  lives inside `phx-update="ignore"` containers keyed by the document id, so
  an unrelated re-render keeps it and another file starts fresh.
  """

  use CanopyWeb, :html

  alias Canopy.Documents
  alias CanopyWeb.{Highlight, Markdown}

  @max_bytes 1_048_576
  @max_lines 5_000
  @markdown_exts ~w(md markdown mdx)
  @archive_exts ~w(zip tar gz tgz bz2 xz 7z rar)

  defstruct [
    :message,
    :documents,
    :index,
    :doc,
    :kind,
    :label,
    :origin,
    :language,
    :line_count,
    :shown_lines,
    :shown_bytes,
    :size,
    :preview_html,
    :source_html,
    truncated: false,
    preview_off: false,
    unreadable: false
  ]

  @type kind :: :image | :markdown | :code | :text | :pdf | :none

  # -- Loading -----------------------------------------------------------------

  @doc """
  The viewer for `doc_id` among `message`'s documents (preloaded), or
  `:error` when the message doesn't carry it. Options: `:channel` (where the
  message is, for the origin line) and `:user_name` (the local user's name).
  """
  def load(%{documents: docs} = message, doc_id, opts \\ []) when is_list(docs) do
    documents = ordered(docs)

    case Enum.find_index(documents, &(&1.id == doc_id)) do
      nil ->
        :error

      index ->
        doc = Enum.at(documents, index)

        viewer = %__MODULE__{
          message: message,
          documents: documents,
          index: index,
          doc: doc,
          kind: kind(doc),
          label: type_label(doc),
          origin: origin(message, Keyword.get(opts, :channel), Keyword.get(opts, :user_name))
        }

        {:ok, put_content(viewer)}
    end
  end

  @doc "A message's documents in display order: images first, then the rest, each in attachment order."
  def ordered(documents) do
    {images, files} = Enum.split_with(documents, &(&1.kind == "image"))
    images ++ files
  end

  # Markdown up to 1 MB is read whole: Preview renders all of it, Source
  # shows its first 5,000 lines. Past 1 MB Preview is off and the (cut)
  # source shows instead.
  defp put_content(%{kind: kind, doc: doc} = viewer) when kind in [:markdown, :code, :text] do
    preview? = kind == :markdown and doc.byte_size <= @max_bytes
    max_lines = if preview?, do: :infinity, else: @max_lines

    case Documents.preview_text(doc, max_bytes: @max_bytes, max_lines: max_lines) do
      {:ok, text, meta} ->
        {source, cut} = if preview?, do: source_lines(text, meta), else: {text, meta.truncated}
        lang = language(doc)

        viewer = %{
          viewer
          | line_count: meta.lines,
            size: meta.size,
            shown_lines: Documents.line_count(source),
            shown_bytes: if(cut == :bytes, do: meta.shown_bytes),
            truncated: cut,
            language: language_label(kind, doc),
            source_html: Highlight.code(source, lang && elem(lang, 0))
        }

        cond do
          kind != :markdown ->
            viewer

          preview? and meta.truncated == false ->
            %{viewer | preview_html: Markdown.document_html(text)}

          true ->
            %{viewer | preview_off: true}
        end

      # a file stored as another kind (`.ts` is `video/mp2t`) that isn't text after all
      {:error, :not_text} ->
        %{viewer | kind: :none, label: other_label(doc.filename)}

      {:error, _} ->
        %{viewer | kind: :none, unreadable: true}
    end
  end

  defp put_content(viewer), do: viewer

  defp source_lines(text, %{truncated: false}) do
    source = Documents.take_lines(text, @max_lines)
    {source, if(byte_size(source) < byte_size(text), do: :lines, else: false)}
  end

  defp source_lines(text, %{truncated: cut}), do: {text, cut}

  # -- What a file is ------------------------------------------------------------

  @doc "How the viewer shows a document."
  @spec kind(map) :: kind
  def kind(%{kind: "image"}), do: :image
  def kind(%{kind: "pdf"}), do: :pdf

  def kind(%{kind: "text", filename: name} = doc) do
    cond do
      ext(name) in @markdown_exts -> :markdown
      language(doc) -> :code
      true -> :text
    end
  end

  # an SVG can carry script, so it is shown as source, never drawn
  def kind(%{mime: "image/svg+xml", filename: name}) do
    if ext(name) == "svg", do: :code, else: :none
  end

  # source stored under another type (`retry.ts` is `video/mp2t`); `load/3`
  # falls back to no preview when its bytes aren't text
  def kind(%{kind: "other"} = doc), do: if(language(doc), do: :code, else: :none)

  def kind(_doc), do: :none

  defp language(%{filename: name}), do: Highlight.language(name)

  defp language_label(:markdown, _doc), do: "Markdown"
  defp language_label(:code, doc), do: doc |> language() |> elem(1)
  defp language_label(_kind, _doc), do: "Plain text"

  @doc "`PNG`, `Markdown`, `Python`, `Text`, `PDF`, `ZIP archive`…"
  def type_label(%{filename: name} = doc) do
    case kind(doc) do
      :image -> upcase_ext(name) || "Image"
      :pdf -> "PDF"
      :markdown -> "Markdown"
      :code -> doc |> language() |> elem(1)
      :text -> "Text"
      :none -> other_label(name)
    end
  end

  defp other_label(name) do
    case upcase_ext(name) do
      nil -> "File"
      ext -> if ext(name) in @archive_exts, do: "#{ext} archive", else: "#{ext} file"
    end
  end

  @doc "The strip's short label for a file that isn't an image: `MD`, `PY`, `LOG`."
  def short_label(%{filename: name}) do
    case upcase_ext(name) do
      nil -> "FILE"
      ext -> String.slice(ext, 0, 4)
    end
  end

  defp ext(name), do: name |> Path.extname() |> String.trim_leading(".") |> String.downcase()

  defp upcase_ext(name) do
    case ext(name) do
      "" -> nil
      ext -> String.upcase(ext)
    end
  end

  @doc "The icon for a viewer kind."
  def kind_icon(:markdown), do: "hero-document-text"
  def kind_icon(:code), do: "hero-code-bracket"
  def kind_icon(:text), do: "hero-command-line"
  def kind_icon(:pdf), do: "hero-document"
  def kind_icon(:image), do: "hero-photo"
  def kind_icon(:none), do: "hero-archive-box"

  @doc "The tint of a file card's type tile."
  def tint(:markdown), do: "bg-secondary/10 text-secondary"
  def tint(:code), do: "bg-warning/10 text-warning"
  def tint(:pdf), do: "bg-error/10 text-error"
  def tint(:image), do: "bg-primary/10 text-primary"
  def tint(_kind), do: "bg-base-content/10 text-base-content/70"

  @doc """
  Who shared the file, where and when: `@backend in #payment-retries, 14:42`;
  `in a DM` for a direct message, `in a thread` for a thread reply.
  """
  def origin(message, channel, user_name) do
    author = CanopyWeb.TimelineComponents.sender_name(message, user_name || "You")

    place =
      cond do
        match?(%{kind: "dm"}, channel) -> "in a DM"
        is_binary(Map.get(message, :thread_id)) -> "in a thread"
        match?(%{name: name} when is_binary(name), channel) -> "in #" <> channel.name
        true -> nil
      end

    time = CanopyWeb.TimelineComponents.short_time(message.inserted_at)
    Enum.join(Enum.reject([author, place], &is_nil/1), " ") <> ", " <> time
  end

  @doc "The file's own part of the meta line: `PNG · 212 KB` or `Python · 1 KB · 33 lines`."
  def file_meta(%__MODULE__{} = v) do
    lines = if v.line_count, do: [lines_label(v.line_count)], else: []
    Enum.join([v.label, Documents.size_label(v.doc.byte_size) | lines], " · ")
  end

  @doc "`1 line`, `48,120 lines`."
  def lines_label(1), do: "1 line"
  def lines_label(n), do: delimit(n) <> " lines"

  @doc false
  def delimit(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "The Download link of a document: always an attachment."
  def download_path(doc), do: Documents.url_path(doc) <> "?download=1"

  # -- The dialog ----------------------------------------------------------------

  @doc """
  The channel's URL with the viewer showing `doc` of `message`, or closed
  (no message): `base` is the rest of the current URL's params, which stay
  (all but `attach`, which would put a file in the composer again).
  """
  def viewer_path(channel_id, base, message \\ nil, doc \\ nil) do
    query =
      (base || %{})
      |> Map.drop(["id", "attach", "file", "in"])
      |> then(&if(message, do: Map.merge(&1, %{"file" => doc.id, "in" => message.id}), else: &1))

    if query == %{},
      do: ~p"/channels/#{channel_id}",
      else: ~p"/channels/#{channel_id}?#{query}"
  end

  # The path showing the file `step` away from the open one, or nil past either end.
  defp step_path(
         %__MODULE__{index: index, documents: docs, message: message},
         channel_id,
         base,
         step
       ) do
    case index + step do
      i when i >= 0 and i < length(docs) ->
        viewer_path(channel_id, base, message, Enum.at(docs, i))

      _ ->
        nil
    end
  end

  defp many?(%__MODULE__{documents: docs}), do: length(docs) > 1

  # Every value is read from @viewer (and the two URL attrs) in the template,
  # never assigned here: a re-render of the channel that leaves them alone
  # then sends nothing of the viewer again.
  attr :viewer, __MODULE__, required: true
  attr :channel_id, :string, required: true

  attr :base, :map,
    default: nil,
    doc: "the current URL's params, kept when the viewer moves or closes"

  def viewer(assigns) do
    ~H"""
    <dialog
      id="file-viewer"
      open
      phx-hook="FileViewer"
      aria-labelledby="file-viewer-name"
      tabindex="-1"
      data-doc={@viewer.doc.id}
      data-message={@viewer.message.id}
      data-kind={@viewer.kind}
      class="file-viewer fixed inset-0 z-50 m-0 hidden h-dvh max-h-none w-screen max-w-none flex-col border-0 bg-[#0A1730]/90 p-0 text-white backdrop-blur-[2px] open:flex outline-none backdrop:bg-transparent"
    >
      <header class="flex h-16 shrink-0 items-center gap-3 px-5 max-[760px]:px-3">
        <div class="flex size-9 shrink-0 items-center justify-center rounded-md bg-white/10">
          <.icon name={kind_icon(@viewer.kind)} class="size-5" />
        </div>
        <div
          id={"file-viewer-title-#{@viewer.doc.id}"}
          phx-update="ignore"
          class="min-w-0 flex-1 leading-tight"
        >
          <h2 id="file-viewer-name" class="truncate text-[14px] font-semibold">
            {@viewer.doc.filename}
          </h2>
          <p
            id="file-viewer-meta"
            class="truncate text-[12px] text-white/60 max-[760px]:hidden"
            title={"#{file_meta(@viewer)} · #{@viewer.origin}"}
          >
            {file_meta(@viewer)}<span id="file-viewer-dims" hidden></span> · {@viewer.origin}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-1.5">
          <div
            :if={@viewer.kind == :image}
            id={"file-viewer-zoom-#{@viewer.doc.id}"}
            phx-update="ignore"
            class="flex h-9 items-center rounded-lg bg-white/10 text-[13px] text-white/80 max-[760px]:hidden"
            role="group"
            aria-label="Zoom"
          >
            <button
              type="button"
              data-viewer-zoom="out"
              class="flex h-9 w-8 items-center justify-center rounded-l-lg transition hover:bg-white/10"
              aria-label="Zoom out"
              title="Zoom out (−)"
            >
              <.icon name="hero-minus-mini" class="size-4" />
            </button>
            <button
              type="button"
              id="file-viewer-zoom-label"
              data-viewer-zoom="toggle"
              class="h-9 min-w-12 px-1 tabular-nums transition hover:bg-white/10"
              aria-label="Fit or 100%"
              title="Fit / 100% (0)"
            >
              Fit
            </button>
            <button
              type="button"
              data-viewer-zoom="in"
              class="flex h-9 w-8 items-center justify-center rounded-r-lg transition hover:bg-white/10"
              aria-label="Zoom in"
              title="Zoom in (+)"
            >
              <.icon name="hero-plus-mini" class="size-4" />
            </button>
          </div>
          <a
            :if={@viewer.kind in [:image, :pdf]}
            id="file-viewer-open"
            href={Documents.url_path(@viewer.doc)}
            target="_blank"
            rel="noopener"
            class={icon_button()}
            aria-label="Open in new tab"
            title="Open in new tab"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-5" />
          </a>
          <a
            id="file-viewer-download"
            href={download_path(@viewer.doc)}
            download={@viewer.doc.filename}
            class="flex h-9 items-center gap-1.5 rounded-lg bg-white px-3 text-[13px] font-semibold text-[#0A1730] transition hover:bg-white/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"
            title={"Download #{@viewer.doc.filename}"}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
            <span class="max-[760px]:sr-only">Download</span>
          </a>
          <span class="mx-1 h-6 w-px bg-white/15" aria-hidden="true" />
          <.link
            id="file-viewer-close"
            patch={viewer_path(@channel_id, @base)}
            replace
            class={icon_button()}
            aria-label="Close"
            title="Close (Esc)"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>
      </header>

      <div class="relative flex min-h-0 flex-1 items-center justify-center px-28 max-[1100px]:px-16 max-[760px]:px-0">
        <.nav_arrow
          :if={many?(@viewer)}
          id="file-viewer-prev"
          to={step_path(@viewer, @channel_id, @base, -1)}
          dir="prev"
          class="left-6 max-[1100px]:left-3 max-[760px]:hidden"
        />
        <.stage v={@viewer} />
        <.nav_arrow
          :if={many?(@viewer)}
          id="file-viewer-next"
          to={step_path(@viewer, @channel_id, @base, 1)}
          dir="next"
          class="right-6 max-[1100px]:right-3 max-[760px]:hidden"
        />
      </div>

      <footer class={[
        "flex shrink-0 flex-col items-center justify-center gap-1.5",
        if(many?(@viewer), do: "h-[92px] max-[760px]:h-14", else: "h-10")
      ]}>
        <nav
          :if={many?(@viewer)}
          id="file-viewer-strip"
          aria-label="Files in this message"
          class="flex max-w-full gap-2 overflow-x-auto px-4 py-1 max-[760px]:hidden"
        >
          <.link
            :for={{doc, i} <- Enum.with_index(@viewer.documents)}
            id={"file-viewer-thumb-#{doc.id}"}
            patch={viewer_path(@channel_id, @base, @viewer.message, doc)}
            replace
            aria-label={"Open #{doc.filename} (#{i + 1} of #{length(@viewer.documents)})"}
            aria-current={i == @viewer.index && "true"}
            title={doc.filename}
            class={[
              "flex h-12 w-16 shrink-0 flex-col items-center justify-center gap-0.5 overflow-hidden rounded-md bg-white/10 text-[10px] font-semibold focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white/70",
              i == @viewer.index && "ring-2 ring-white ring-offset-2 ring-offset-[#0A1730]",
              i != @viewer.index && "opacity-60 hover:opacity-100"
            ]}
          >
            <img
              :if={doc.kind == "image"}
              src={Documents.url_path(doc)}
              alt=""
              loading="lazy"
              class="h-full w-full object-cover"
            />
            <%= if doc.kind != "image" do %>
              <.icon name={kind_icon(kind(doc))} class="size-4" />
              <span>{short_label(doc)}</span>
            <% end %>
          </.link>
        </nav>
        <div class="flex items-center gap-3">
          <.nav_arrow
            :if={many?(@viewer)}
            id="file-viewer-prev-sm"
            to={step_path(@viewer, @channel_id, @base, -1)}
            dir="prev"
            small
          />
          <p class="flex items-center gap-1 text-[11px] text-white/50">
            <%= if many?(@viewer) do %>
              <span id="file-viewer-position">{@viewer.index + 1} of {length(@viewer.documents)}</span>
              <span class="max-[760px]:hidden">·</span>
              <span class="flex items-center gap-1 max-[760px]:hidden">
                <kbd class={kbd()}>←</kbd> <kbd class={kbd()}>→</kbd> browse
              </span>
              <span class="max-[760px]:hidden">·</span>
            <% end %>
            <span class="flex items-center gap-1 max-[760px]:hidden">
              <kbd class={kbd()}>Esc</kbd> close
            </span>
          </p>
          <.nav_arrow
            :if={many?(@viewer)}
            id="file-viewer-next-sm"
            to={step_path(@viewer, @channel_id, @base, 1)}
            dir="next"
            small
          />
        </div>
        <span class="sr-only" aria-live="polite">
          {@viewer.doc.filename}{if(many?(@viewer),
            do: ", #{@viewer.index + 1} of #{length(@viewer.documents)}"
          )}
        </span>
      </footer>
    </dialog>
    """
  end

  defp icon_button,
    do:
      "flex size-9 items-center justify-center rounded-lg text-white/80 transition hover:bg-white/10 hover:text-white focus-visible:outline-2 focus-visible:outline-white/70"

  defp kbd,
    do:
      "rounded border border-white/20 bg-white/10 px-1 py-px font-sans text-[10px] leading-none text-white/70"

  attr :id, :string, required: true
  attr :to, :string, default: nil
  attr :dir, :string, required: true
  attr :class, :string, default: nil
  attr :small, :boolean, default: false

  defp nav_arrow(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@to || "#"}
      replace
      aria-label={if(@dir == "prev", do: "Previous file", else: "Next file")}
      title={if(@dir == "prev", do: "Previous (←)", else: "Next (→)")}
      aria-disabled={is_nil(@to) && "true"}
      tabindex={is_nil(@to) && "-1"}
      data-viewer-nav={@dir}
      class={[
        "z-10 flex items-center justify-center rounded-full bg-white/10 text-white transition hover:bg-white/20 focus-visible:outline-2 focus-visible:outline-white/70",
        @small && "size-9 min-[761px]:hidden",
        !@small && "absolute top-1/2 size-11 -translate-y-1/2 max-[1100px]:size-9",
        is_nil(@to) && "pointer-events-none opacity-30",
        @class
      ]}
    >
      <.icon
        name={if(@dir == "prev", do: "hero-chevron-left", else: "hero-chevron-right")}
        class="size-5"
      />
    </.link>
    """
  end

  attr :v, __MODULE__, required: true

  defp stage(%{v: %{kind: :image}} = assigns) do
    ~H"""
    <div
      id={"file-viewer-image-#{@v.doc.id}"}
      phx-update="ignore"
      data-viewer-stage
      class="flex h-full w-full overflow-hidden py-2"
    >
      <span
        data-viewer-loading
        class="loading loading-spinner loading-lg absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 text-white/60"
      />
      <img
        id="file-viewer-image"
        src={Documents.url_path(@v.doc)}
        alt={@v.doc.filename}
        draggable="false"
        class="m-auto max-h-full max-w-full rounded-md object-contain opacity-0 shadow-2xl transition-opacity"
      />
      <div data-viewer-error hidden class="m-auto">
        <.no_preview doc={@v.doc} message="This image couldn't be loaded." />
      </div>
    </div>
    """
  end

  # FileController serves a PDF's inline view without the sandbox CSP, which
  # browsers' PDF viewers refuse to render in
  defp stage(%{v: %{kind: :pdf}} = assigns) do
    ~H"""
    <div
      id={"file-viewer-pdf-#{@v.doc.id}"}
      class="h-full w-[940px] max-w-full overflow-hidden rounded-xl bg-base-200 shadow-2xl max-[760px]:rounded-none"
    >
      <iframe
        id="file-viewer-pdf"
        src={Documents.url_path(@v.doc)}
        title={@v.doc.filename}
        class="h-full w-full border-0"
      ></iframe>
    </div>
    """
  end

  defp stage(%{v: %{kind: kind}} = assigns) when kind in [:markdown, :code, :text] do
    ~H"""
    <%!-- LiveView still syncs the data-* of an ignored element, so the hook's
         data-mode and data-wrap live on the sheet inside it --%>
    <div
      id={"file-viewer-sheet-#{@v.doc.id}"}
      phx-update="ignore"
      class="h-full w-[940px] max-w-full"
    >
      <div
        data-viewer-sheet
        data-markdown={@v.kind == :markdown && !@v.preview_off && "true"}
        class="doc-sheet flex h-full w-full flex-col overflow-hidden rounded-xl bg-base-200 text-base-content shadow-2xl max-[760px]:rounded-none"
      >
        <div class="doc-toolbar flex h-11 shrink-0 items-center gap-3 border-b border-base-300 px-4 text-[12px]">
          <div
            :if={@v.kind == :markdown and not @v.preview_off}
            class="flex rounded-lg border border-base-300 bg-base-100 p-0.5"
            role="group"
            aria-label="View"
          >
            <button
              :for={{mode, label} <- [{"preview", "Preview"}, {"source", "Source"}]}
              type="button"
              id={"file-viewer-mode-#{mode}"}
              data-viewer-mode={mode}
              aria-pressed={to_string(mode == "preview")}
              class="doc-mode rounded-md px-2.5 py-1 font-medium text-base-content/60 hover:text-base-content"
            >
              {label}
            </button>
          </div>
          <span
            :if={@v.kind != :markdown or @v.preview_off}
            id="file-viewer-language"
            class="font-medium"
          >
            {@v.language}
          </span>
          <span class="text-base-content/60">
            {lines_label(@v.line_count)}
          </span>
          <span class="flex-1" />
          <button
            type="button"
            id="file-viewer-wrap"
            data-viewer-wrap
            aria-pressed="false"
            class="doc-wrap flex h-7 items-center gap-1.5 rounded-md px-2 text-base-content/70 hover:bg-base-300/50 hover:text-base-content"
            title="Wrap long lines"
          >
            <.icon name="hero-bars-3-bottom-left-mini" class="size-4" /> Wrap
          </button>
          <%!-- Copy fetches the file's own bytes; when Source is cut, only
               what it shows (its lines, or its bytes) --%>
          <button
            type="button"
            id="file-viewer-copy"
            data-viewer-copy
            data-copy-url={Documents.url_path(@v.doc)}
            data-copy-lines={@v.truncated == :lines && @v.shown_lines}
            data-copy-bytes={@v.truncated == :bytes && @v.shown_bytes}
            class="flex h-7 items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 text-base-content/80 transition hover:border-primary/50 hover:text-base-content"
            title={if(@v.truncated, do: "Copy what is shown", else: "Copy the file")}
          >
            <.icon name="hero-clipboard-document-mini" class="size-4" />
            <span data-copy-label>Copy</span>
          </button>
        </div>
        <div
          :if={@v.preview_off}
          id="file-viewer-too-big"
          class="border-b border-base-300 px-4 py-2 text-[12.5px] text-base-content/70"
        >
          This file is too big to preview. Showing the source.
        </div>
        <%!-- Source's banner: a Markdown Preview shows the whole file, and
             app.css hides this while it does --%>
        <div
          :if={@v.truncated}
          id="file-viewer-truncated"
          class="doc-truncated flex items-center gap-2 border-b border-warning/25 bg-warning/10 px-4 py-2 text-[12.5px]"
        >
          <span>
            <span class="font-semibold">{truncated_label(@v)}</span>
            <span class="text-base-content/70">Download the file to see all of it.</span>
          </span>
          <a
            href={download_path(@v.doc)}
            download={@v.doc.filename}
            class="ml-auto flex shrink-0 items-center gap-1 font-semibold text-primary hover:underline"
          >
            <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Download
          </a>
        </div>
        <div class="doc-body min-h-0 flex-1 overflow-auto overscroll-contain">
          <article
            :if={@v.preview_html}
            id="file-viewer-preview"
            class="doc-preview doc-markdown px-12 py-9 max-[760px]:px-5 max-[760px]:py-5"
          >
            {raw(@v.preview_html)}
          </article>
          <pre id="file-viewer-source" class="doc-source doc-code">{raw(@v.source_html)}</pre>
        </div>
      </div>
    </div>
    """
  end

  defp stage(assigns) do
    ~H"""
    <.no_preview
      doc={@v.doc}
      kind={@v.kind}
      label={@v.label}
      message={
        if(@v.unreadable,
          do: "This file couldn't be read.",
          else: "Canopy can't show a preview of this kind of file."
        )
      }
    />
    """
  end

  @doc """
  The cut Source's banner: `Showing the first 5,000 of 48,120 lines.`, or by
  size when one line ran past the byte limit (`the first 1.0 MB of 3.4 MB`).
  """
  def truncated_label(%__MODULE__{truncated: :lines} = v),
    do: "Showing the first #{delimit(v.shown_lines)} of #{delimit(v.line_count)} lines."

  def truncated_label(%__MODULE__{truncated: :bytes} = v),
    do:
      "Showing the first #{Documents.size_label(v.shown_bytes)} of #{Documents.size_label(v.size)}."

  attr :doc, :map, required: true
  attr :kind, :atom, default: nil, doc: "the viewer's kind when it differs from the file's"
  attr :label, :string, default: nil
  attr :message, :string, required: true

  defp no_preview(assigns) do
    ~H"""
    <div
      id={"file-viewer-none-#{@doc.id}"}
      class="flex w-[440px] max-w-[calc(100vw-2rem)] flex-col items-center rounded-2xl bg-base-200 px-10 py-10 text-center text-base-content shadow-2xl"
    >
      <div class="flex size-16 items-center justify-center rounded-xl bg-base-content/10 text-base-content/70">
        <.icon name={kind_icon(@kind || kind(@doc))} class="size-8" />
      </div>
      <p class="mt-5 max-w-full truncate text-[16px] font-semibold">{@doc.filename}</p>
      <p class="mt-0.5 text-[13px] text-base-content/60">
        {@label || type_label(@doc)} · {Documents.size_label(@doc.byte_size)}
      </p>
      <p class="mt-5 text-[14px]">{@message}</p>
      <a
        href={download_path(@doc)}
        download={@doc.filename}
        class="btn btn-primary mt-5"
        id="file-viewer-none-download"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" /> Download
      </a>
    </div>
    """
  end
end
