defmodule Canopy.Documents do
  @moduledoc """
  Files shared in Canopy. A document is workspace-wide: uploaded once, attached
  to any number of messages in any chat (see `Canopy.Messages.Attachment`).
  Rows live here, bytes in `Canopy.Documents.Store`.
  """

  import Ecto.Query, warn: false

  alias Canopy.Documents.{Document, Store}
  alias Canopy.Messages.Attachment
  alias Canopy.Repo

  @default_limit 50
  @max_limit 500
  @preloads [:user, :agent]

  @image_mimes ~w(image/png image/jpeg image/gif image/webp)
  @text_mimes ~w(application/json application/x-ndjson application/xml application/toml application/x-yaml application/yaml application/x-sh application/javascript application/typescript)

  # ------------------------------------------------------------------ limits

  @doc "The largest file accepted, in bytes (`CANOPY_MAX_UPLOAD_MB`, default 25)."
  def max_bytes, do: Application.get_env(:canopy, :max_upload_bytes, 25 * 1024 * 1024)

  # ------------------------------------------------------------------ create

  @doc """
  Stores a new document. `attrs`:

    * `:filename` (required) — sanitised to a safe basename
    * `:source` (required) — `{:binary, bytes}` or `{:path, file}`
    * `:mime` — the client's type; missing or generic types are sniffed
    * `:user_id` | `:agent_id` — exactly one
    * `:origin_channel_id`, `:caption` — optional

  Returns `{:ok, %Document{}}`, `{:error, :too_large}`, `{:error, :unreadable}`,
  or `{:error, %Ecto.Changeset{}}`. The bytes are written inside the insert
  transaction and removed again if it fails.
  """
  def create(attrs) when is_map(attrs) do
    source = Map.fetch!(attrs, :source)
    filename = attrs |> Map.get(:filename) |> safe_filename()

    with {:ok, size} <- source_size(source),
         :ok <- check_size(size),
         {:ok, head} <- head(source),
         {:ok, sha} <- sha256(source) do
      mime = detect_mime(Map.get(attrs, :mime), head, filename)

      row = %{
        filename: filename,
        mime: mime,
        kind: kind_for(mime, filename),
        byte_size: size,
        sha256: sha,
        caption: Map.get(attrs, :caption),
        user_id: Map.get(attrs, :user_id),
        agent_id: Map.get(attrs, :agent_id),
        origin_channel_id: Map.get(attrs, :origin_channel_id)
      }

      Repo.transaction(fn ->
        with {:ok, document} <- Repo.insert(Document.changeset(%Document{}, row)),
             :ok <- Store.put(document.id, source) do
          Repo.preload(document, @preloads)
        else
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
          {:error, reason} -> Repo.rollback({:store, reason})
        end
      end)
    end
  end

  @doc """
  Shares a file that lives inside a repository, as an agent does after writing
  a report. `path` is relative to the repository (or absolute inside it); paths
  that escape the repository, symlinks pointing out of it, directories, and
  missing files are refused with a one-line reason.
  """
  def create_from_repository(repository_path, path, attrs)
      when is_binary(repository_path) and is_binary(path) and is_map(attrs) do
    root = Path.expand(repository_path)
    full = Path.expand(String.trim(path), root)

    with :ok <- inside(full, root, path),
         :ok <- not_symlinked_out(full, root, path),
         :ok <- regular(full, path) do
      attrs
      |> Map.put(:filename, Map.get(attrs, :filename) || Path.basename(full))
      |> Map.put(:source, {:path, full})
      |> create()
      |> case do
        {:ok, document} -> {:ok, document}
        {:error, :too_large} -> {:error, "#{path} is larger than #{size_label(max_bytes())}"}
        {:error, :unreadable} -> {:error, "#{path} cannot be read"}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    end
  end

  defp inside(full, root, path) do
    if full == root or String.starts_with?(full, root <> "/"),
      do: :ok,
      else: {:error, "#{path} is outside the repository"}
  end

  defp not_symlinked_out(full, root, path) do
    case File.read_link(full) do
      {:ok, target} ->
        resolved = Path.expand(target, Path.dirname(full))
        inside(resolved, root, path)

      {:error, _} ->
        :ok
    end
  end

  defp regular(full, path) do
    cond do
      File.dir?(full) -> {:error, "#{path} is a directory"}
      File.regular?(full) -> :ok
      true -> {:error, "#{path} does not exist"}
    end
  end

  defp check_size(size) do
    if size > max_bytes(), do: {:error, :too_large}, else: :ok
  end

  defp source_size({:binary, bytes}), do: {:ok, byte_size(bytes)}

  defp source_size({:path, path}) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} -> {:ok, size}
      _ -> {:error, :unreadable}
    end
  end

  @head_bytes 512

  defp head({:binary, bytes}),
    do: {:ok, binary_part(bytes, 0, min(byte_size(bytes), @head_bytes))}

  defp head({:path, path}) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @head_bytes)) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, data} when is_binary(data) -> {:ok, data}
      _ -> {:error, :unreadable}
    end
  end

  defp sha256({:binary, bytes}), do: {:ok, hex(:crypto.hash(:sha256, bytes))}

  defp sha256({:path, path}) do
    digest =
      path
      |> File.stream!(64 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, hex(digest)}
  rescue
    File.Error -> {:error, :unreadable}
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # ------------------------------------------------------------------ naming and types

  @doc """
  A safe basename: directories stripped, control characters and path
  separators removed, capped at 255 bytes, `file` when nothing is left.
  """
  def safe_filename(nil), do: "file"

  def safe_filename(name) when is_binary(name) do
    base =
      name
      |> String.replace(["\\", ":"], "/")
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.trim()
      |> String.trim_leading(".")

    base = if String.valid?(base), do: base, else: ""

    case base do
      "" -> "file"
      base when byte_size(base) > 255 -> String.slice(base, 0, 200) <> Path.extname(base)
      base -> base
    end
  end

  @generic ~w(application/octet-stream binary/octet-stream application/x-www-form-urlencoded)

  @doc """
  Picks the MIME type: the client's, unless it is missing or generic, then
  the file's magic bytes, then its extension, then `text/plain` for anything
  that looks like text.
  """
  def detect_mime(client, head, filename) do
    client = client |> blank_to_nil() |> normalize_mime()

    cond do
      client && client not in @generic -> client
      sniffed = sniff(head) -> sniffed
      (ext = MIME.from_path(filename)) != "application/octet-stream" -> ext
      textual?(head) -> "text/plain"
      true -> "application/octet-stream"
    end
  end

  defp normalize_mime(nil), do: nil

  defp normalize_mime(mime),
    do: mime |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  defp sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp sniff(<<"GIF87a", _::binary>>), do: "image/gif"
  defp sniff(<<"GIF89a", _::binary>>), do: "image/gif"
  defp sniff(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  defp sniff(<<"%PDF-", _::binary>>), do: "application/pdf"
  defp sniff(_), do: nil

  defp textual?(""), do: true

  defp textual?(head) do
    String.valid?(head) and not String.contains?(head, <<0>>)
  end

  @doc "`image`, `text`, `pdf`, or `other` for a MIME type."
  def kind_for(mime, _filename \\ nil) do
    cond do
      mime in @image_mimes -> "image"
      mime == "application/pdf" -> "pdf"
      String.starts_with?(mime, "text/") -> "text"
      mime in @text_mimes -> "text"
      true -> "other"
    end
  end

  @doc "The MIME type to show a model: text documents always go as `text/plain`."
  def prompt_mime(%Document{kind: "text"}), do: "text/plain"
  def prompt_mime(%Document{mime: mime}), do: mime

  # ------------------------------------------------------------------ read

  def get(id) when is_binary(id), do: Document |> Repo.get(id) |> Repo.preload(@preloads)
  def get(_), do: nil

  def get!(id), do: Document |> Repo.get!(id) |> Repo.preload(@preloads)

  @doc """
  Lists documents, newest first.

  Options: `:search` (filename substring), `:kind`, `:channel` (only documents
  attached to a message in that channel id), `:limit` (default #{@default_limit}).
  """
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    Document
    |> filter_search(Keyword.get(opts, :search))
    |> filter_kind(Keyword.get(opts, :kind))
    |> filter_channel(Keyword.get(opts, :channel))
    |> order_by([d], desc: d.id)
    |> limit(^limit)
    |> preload(^@preloads)
    |> Repo.all()
  end

  defp filter_search(query, nil), do: query

  defp filter_search(query, term) do
    case String.trim(term) do
      "" -> query
      term -> where(query, [d], like(d.filename, ^("%" <> escape_like(term) <> "%")))
    end
  end

  defp escape_like(term), do: String.replace(term, ["%", "_"], &("\\" <> &1))

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, ""), do: query
  defp filter_kind(query, kind), do: where(query, [d], d.kind == ^kind)

  defp filter_channel(query, nil), do: query

  defp filter_channel(query, channel_id) do
    ids =
      from(a in Attachment,
        join: m in assoc(a, :message),
        where: m.channel_id == ^channel_id,
        select: a.document_id
      )

    where(query, [d], d.id in subquery(ids))
  end

  @doc "The messages a document is attached to, oldest first, with their channels."
  def usages(%Document{id: id}) do
    from(a in Attachment,
      join: m in assoc(a, :message),
      join: c in assoc(m, :channel),
      where: a.document_id == ^id,
      order_by: [asc: m.id],
      select: %{message_id: m.id, channel: c, inserted_at: m.inserted_at}
    )
    |> Repo.all()
  end

  @doc "The whole file."
  def read(%Document{id: id}), do: Store.read(id)

  @doc """
  A window of a text document as `{:ok, text, total_chars}`; `offset` and
  `length` count characters. Non-text kinds return `{:error, :not_text}`.
  """
  def read_text(document, offset \\ 0, length \\ 8_000)

  def read_text(%Document{kind: "text"} = document, offset, length) do
    with {:ok, bytes} <- read(document) do
      text = if String.valid?(bytes), do: bytes, else: String.replace_invalid(bytes)
      total = String.length(text)
      {:ok, String.slice(text, offset, length), total}
    end
  end

  def read_text(%Document{}, _offset, _length), do: {:error, :not_text}

  @doc "The file as a `data:` URL, the shape OpenCode wants for a prompt part."
  def data_url(%Document{} = document) do
    with {:ok, bytes} <- read(document) do
      {:ok, "data:#{prompt_mime(document)};base64," <> Base.encode64(bytes)}
    end
  end

  @doc "The public path of a document, with its filename for downloads."
  def url_path(%Document{id: id, filename: filename}), do: "/files/#{id}/#{URI.encode(filename)}"

  @doc "`12 KB`, `3.4 MB`."
  def size_label(bytes) when is_integer(bytes) do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{div(bytes, 1024)} KB"
      true -> :erlang.float_to_binary(bytes / (1024 * 1024), decimals: 1) <> " MB"
    end
  end

  def total_bytes, do: Repo.one(from(d in Document, select: coalesce(sum(d.byte_size), 0)))

  def count, do: Repo.aggregate(Document, :count)

  # ------------------------------------------------------------------ delete

  @doc """
  Removes the row (attachments cascade) and the bytes, then broadcasts
  `{:document_deleted, id, message_ids}` with the messages it was attached to,
  so open channels can redraw them.
  """
  def delete(%Document{} = document) do
    message_ids = document |> usages() |> Enum.map(& &1.message_id)

    with {:ok, deleted} <- Repo.delete(document) do
      Store.delete(deleted.id)

      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        topic(),
        {:document_deleted, deleted.id, message_ids}
      )

      {:ok, deleted}
    end
  end

  def topic, do: "documents"
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, topic())

  # ------------------------------------------------------------------ prompts

  @part_image_bytes 5 * 1024 * 1024
  @part_text_bytes 64 * 1024
  @max_parts 3

  @doc """
  Decides how each attachment reaches a model in a wake prompt: `:part` rides
  along as a file part (images up to 5 MB, text up to 64 KB, at most three per
  prompt), `:path` is only named, with its materialised path, so the agent
  reads it on demand. Returns `[{document, :part | :path}]` in input order.
  """
  def prompt_plan(documents) when is_list(documents) do
    {plan, _count} =
      Enum.map_reduce(documents, 0, fn document, count ->
        cond do
          count >= @max_parts -> {{document, :path}, count}
          part_worthy?(document) -> {{document, :part}, count + 1}
          true -> {{document, :path}, count}
        end
      end)

    plan
  end

  def prompt_plan(_), do: []

  defp part_worthy?(%{kind: "image", byte_size: size}), do: size <= @part_image_bytes
  defp part_worthy?(%{kind: "text", byte_size: size}), do: size <= @part_text_bytes
  defp part_worthy?(_), do: false

  @doc "The OpenCode `file` part for a document, or nil when its bytes cannot be read."
  def prompt_part(%Document{} = document) do
    case data_url(document) do
      {:ok, url} ->
        %{type: "file", mime: prompt_mime(document), filename: document.filename, url: url}

      _ ->
        nil
    end
  end

  # ------------------------------------------------------------------ materialise

  @doc """
  Copies the document into a repository's `.canopy/files/` so agents can read
  it with their own tools. Idempotent; returns the absolute path.
  """
  def materialize(%Document{} = document, repository_path) when is_binary(repository_path) do
    dir = Path.join(Canopy.Notes.dir(repository_path), "files")
    path = Path.join(dir, document.id <> "-" <> document.filename)

    with :ok <- Canopy.Notes.ensure_workspace(repository_path),
         :ok <- File.mkdir_p(dir),
         :ok <- copy_if_missing(document, path) do
      {:ok, path}
    end
  end

  defp copy_if_missing(document, path) do
    if File.regular?(path), do: :ok, else: File.cp(Store.path(document.id), path)
  end

  @doc "The repository-relative path a materialised document has."
  def materialized_relative_path(%Document{} = document),
    do: Path.join([".canopy", "files", document.id <> "-" <> document.filename])

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
