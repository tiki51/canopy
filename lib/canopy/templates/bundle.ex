defmodule Canopy.Templates.Bundle do
  @moduledoc """
  Several templates as one zip, each in its own file so the one-item readers
  work per entry and the zip unzips to a folder that diffs cleanly:

      canopy.md           kind: bundle (name, description); the body is a readme
      agents/<name>.md    agent templates
      teams/<name>.md     team files
      playbooks/<name>.md playbook texts, verbatim

  Reading happens in memory and never touches disk. It is guarded like the
  frontmatter reader: the zip is at most #{div(2_000_000, 1000)} KB, holds at
  most 100 entries and #{div(8_000_000, 1_000_000)} MB once unpacked (checked
  from the directory first, then again while inflating, so a directory that
  lies about sizes stops at the cap), and an entry with an absolute path or
  `..` refuses the whole bundle. Anything outside the four places above is
  ignored with a notice.
  """

  alias Canopy.Frontmatter
  alias Canopy.Templates.AgentTemplate

  @max_zip_bytes 2_000_000
  @max_entries 100
  @max_total_bytes 8_000_000
  @manifest "canopy.md"
  @folders ~w(agents teams playbooks)

  def max_zip_bytes, do: @max_zip_bytes
  def max_entries, do: @max_entries
  def max_total_bytes, do: @max_total_bytes

  @doc "Whether a binary looks like a zip (its local-header signature)."
  def zip?(<<0x50, 0x4B, 0x03, 0x04, _::binary>>), do: true
  def zip?(_), do: false

  # -- Writing ------------------------------------------------------------------

  @doc """
  A bundle zip from a manifest (`name`, `description`, optional `readme`) and
  `[{path, text}]` entries. Returns the zip's bytes.
  """
  def encode(manifest, files) when is_list(files) do
    canopy =
      Frontmatter.document(
        [
          canopy_template: AgentTemplate.version(),
          kind: "bundle",
          name: manifest[:name],
          description: manifest[:description],
          exported_from: Canopy.Templates.exported_from()
        ],
        manifest[:readme]
      )

    entries =
      Enum.map([{@manifest, canopy} | files], fn {path, text} ->
        {String.to_charlist(path), text}
      end)

    {:ok, {_name, bin}} = :zip.create(~c"bundle.zip", entries, [:memory])
    bin
  end

  # -- Reading ------------------------------------------------------------------

  @doc """
  Reads a bundle: `{:ok, %{manifest: map | nil, files: [{path, text}], notices: [line]}}`
  or `{:error, lines}`. `manifest` is the frontmatter of `canopy.md` plus its
  body as `"readme"`.
  """
  def read(bin) when is_binary(bin) do
    with :ok <- Frontmatter.check_size(bin, @max_zip_bytes, "the zip"),
         {:ok, entries} <- list(bin),
         :ok <- check_count(entries),
         :ok <- check_paths(entries),
         :ok <- check_declared(entries) do
      {wanted, notices} = select(entries)

      with {:ok, files} <- extract(bin, wanted),
           {:ok, manifest, files, manifest_notices} <- take_manifest(files) do
        {:ok, %{manifest: manifest, files: files, notices: notices ++ manifest_notices}}
      end
    end
  end

  defp list(bin) do
    case :zip.list_dir(bin) do
      {:ok, items} ->
        entries =
          for {:zip_file, name, info, _comment, offset, comp_size} <- items do
            %{
              path: entry_name(name),
              size: elem(info, 1),
              offset: offset,
              comp_size: comp_size
            }
          end

        if Enum.any?(entries, &is_nil(&1.path)),
          do: {:error, ["the zip has an entry whose name isn't readable text"]},
          else: {:ok, Enum.reject(entries, &String.ends_with?(&1.path, "/"))}

      {:error, _} ->
        {:error, ["that isn't a readable zip file"]}
    end
  rescue
    _ -> {:error, ["that isn't a readable zip file"]}
  end

  defp entry_name(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp entry_name(_), do: nil

  defp check_count(entries) do
    if length(entries) > @max_entries,
      do: {:error, ["the zip has too many entries (at most #{@max_entries})"]},
      else: :ok
  end

  defp check_paths(entries) do
    case Enum.find(entries, &unsafe_path?(&1.path)) do
      nil -> :ok
      %{path: path} -> {:error, ["the zip has an unsafe entry path: #{path}"]}
    end
  end

  defp unsafe_path?(path) do
    String.starts_with?(path, ["/", "\\"]) or Regex.match?(~r/\A[A-Za-z]:/, path) or
      String.contains?(path, ["\\", <<0>>]) or ".." in String.split(path, "/")
  end

  defp check_declared(entries) do
    if Enum.sum_by(entries, & &1.size) > @max_total_bytes,
      do: {:error, [too_large()]},
      else: :ok
  end

  defp too_large,
    do: "the zip unpacks to more than #{div(@max_total_bytes, 1_000_000)} MB"

  # The entries Canopy reads, after dropping one folder wrapped around
  # everything (a re-zipped bundle folder); the rest are named in a notice,
  # except the clutter archivers add.
  defp select(entries) do
    prefix = common_prefix(entries)

    entries
    |> Enum.map(&Map.put(&1, :name, String.replace_prefix(&1.path, prefix, "")))
    |> Enum.reject(&clutter?(&1.name))
    |> Enum.split_with(&wanted?(&1.name))
    |> then(fn {wanted, ignored} ->
      notices =
        case ignored do
          [] ->
            []

          ignored ->
            names = ignored |> Enum.map(& &1.name) |> Enum.take(5) |> Enum.join(", ")
            more = if length(ignored) > 5, do: " and #{length(ignored) - 5} more", else: ""
            ["ignored files outside agents/, teams/ and playbooks/: #{names}#{more}"]
        end

      {wanted, notices}
    end)
  end

  defp common_prefix(entries) do
    names = entries |> Enum.map(& &1.path) |> Enum.reject(&clutter?/1)

    with false <- @manifest in names,
         [first | _] <- names,
         [dir, _ | _] when dir not in @folders <- String.split(first, "/"),
         true <- Enum.all?(names, &String.starts_with?(&1, dir <> "/")) do
      dir <> "/"
    else
      _ -> ""
    end
  end

  defp clutter?(path) do
    String.starts_with?(path, "__MACOSX/") or Path.basename(path) == ".DS_Store"
  end

  defp wanted?(@manifest), do: true

  defp wanted?(name) do
    case String.split(name, "/") do
      [folder, file] when folder in @folders -> Path.extname(file) in [".md", ".markdown"]
      _ -> false
    end
  end

  defp extract(bin, entries) do
    entries
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, acc, total} ->
      max = min(AgentTemplate.max_bytes(), @max_total_bytes - total)

      case inflate_entry(bin, entry, max) do
        {:ok, data} ->
          if String.valid?(data),
            do: {:cont, {:ok, [{entry.name, data} | acc], total + byte_size(data)}},
            else: {:halt, {:error, ["#{entry.name} isn't UTF-8 text"]}}

        {:error, :too_large} ->
          {:halt,
           {:error,
            [
              if(max < AgentTemplate.max_bytes(),
                do: too_large(),
                else: "#{entry.name} is too large (at most #{AgentTemplate.max_bytes()} bytes)"
              )
            ]}}

        {:error, reason} ->
          {:halt, {:error, ["#{entry.name}: #{reason}"]}}
      end
    end)
    |> case do
      {:ok, files, _total} -> {:ok, Enum.sort(files)}
      error -> error
    end
  end

  # The entry's data, from its local header, inflated with a cap: `:zip`
  # would inflate the whole entry whatever its directory says.
  defp inflate_entry(bin, %{offset: offset, comp_size: comp_size}, max) do
    with true <- offset + 30 <= byte_size(bin),
         <<0x50, 0x4B, 0x03, 0x04, _::binary-size(4), method::little-16, _::binary-size(16),
           name_len::little-16, extra_len::little-16>> <- binary_part(bin, offset, 30),
         start = offset + 30 + name_len + extra_len,
         true <- start + comp_size <= byte_size(bin) do
      data = binary_part(bin, start, comp_size)

      case method do
        0 -> if byte_size(data) <= max, do: {:ok, data}, else: {:error, :too_large}
        8 -> inflate(data, max)
        _ -> {:error, "uses a compression method Canopy can't read"}
      end
    else
      _ -> {:error, "the zip is damaged"}
    end
  end

  defp inflate(data, max) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_loop(z, :zlib.safeInflate(z, data), [], 0, max)
    rescue
      _ -> {:error, "the zip is damaged"}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {status, out}, acc, size, max) when status in [:continue, :finished] do
    size = size + IO.iodata_length(out)

    cond do
      size > max -> {:error, :too_large}
      status == :finished -> {:ok, IO.iodata_to_binary([acc, out])}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), [acc, out], size, max)
    end
  end

  defp inflate_loop(_z, _other, _acc, _size, _max), do: {:error, "the zip is damaged"}

  defp take_manifest(files) do
    case List.keytake(files, @manifest, 0) do
      nil ->
        {:ok, nil, files, ["the zip has no canopy.md; read its files anyway"]}

      {{_, text}, rest} ->
        with {:ok, data, body} <-
               Frontmatter.read(
                 text,
                 "canopy.md",
                 AgentTemplate.max_bytes(),
                 AgentTemplate.max_header_bytes()
               ),
             :ok <- AgentTemplate.check_version(data),
             :ok <- check_bundle_kind(data) do
          {:ok, Map.put(data, "readme", String.trim(body)), rest, []}
        else
          {:error, lines} -> {:error, Enum.map(lines, &("canopy.md: " <> &1))}
        end
    end
  end

  defp check_bundle_kind(%{"kind" => "bundle"}), do: :ok
  defp check_bundle_kind(_), do: {:error, ["kind must be bundle"]}
end
