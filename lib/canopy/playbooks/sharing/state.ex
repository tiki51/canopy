defmodule Canopy.Playbooks.Sharing.State do
  @moduledoc """
  Pure: pairs the local playbooks with the files in the shared folder and
  gives each pair its state (see `Canopy.Playbooks.Sharing`).

  Pairing, first match wins:
  1. by origin: a playbook linked here (`origin_repo` is the configured repo,
     `origin_path` inside the folder) pairs with the file at `origin_path`;
  2. by name: an unpaired playbook not linked here pairs with the first file,
     in path order, whose frontmatter `name` is its name;
  3. files left over are `:new` (a taken name imports as `import_as`);
  4. enabled playbooks left over are `:not_on_github`, or `:name_taken` when
     their file path is occupied by any file.
  """

  alias Canopy.Playbooks.{Definition, Playbook}
  alias Canopy.Playbooks.Sharing.{Remote, Text}

  @max_file_bytes 48 * 1024
  @max_body_bytes 40_000
  @exportable [:edited, :not_on_github, :both_changed, :name_clash]

  @doc "The states an export may write."
  def exportable, do: @exportable

  @doc "The largest file, by its size in the listing, that is read at all."
  def max_file_bytes, do: @max_file_bytes

  @doc """
  A listed file with its text read (or the reason it wasn't): adds `text`,
  `hash`, `name` (frontmatter), `version`, `description`, `definition` and
  `error` (nil when readable).
  """
  def prepare_file(%{path: path, sha: sha} = file, read) do
    base =
      Map.merge(file, %{
        text: nil,
        hash: nil,
        name: nil,
        version: nil,
        description: nil,
        definition: nil,
        error: nil
      })

    cond do
      not Remote.file_name_ok?(path) ->
        %{
          base
          | error:
              "the file name has characters Canopy doesn't read (letters, digits, _ . - only)"
        }

      not Remote.sha_ok?(sha) ->
        %{base | error: "GitHub listed it with an unexpected blob sha"}

      Map.get(file, :size, 0) > @max_file_bytes ->
        %{base | error: "it's over 48 KB, more than a playbook can be"}

      true ->
        case read do
          {:ok, text} -> parse_file(base, text)
          {:error, {_kind, raw}} -> %{base | error: "couldn't read it: " <> raw}
          :skip -> base
        end
    end
  end

  defp parse_file(file, text) do
    stripped = Text.strip_version(text)

    with {:ok, definition} <- Definition.parse(stripped),
         {:ok, version} <- version(text) do
      %{
        file
        | text: text,
          hash: Text.content_hash(text),
          name: definition.name,
          version: version,
          description: definition.description,
          definition: definition
      }
    else
      {:error, [reason | _]} -> %{file | text: text, error: reason}
      {:error, reason} when is_binary(reason) -> %{file | text: text, error: reason}
    end
  end

  # the version: line, read by the parser's own rule
  defp version(text) do
    case Definition.parse(text) do
      {:ok, %Definition{version: version}} ->
        {:ok, version}

      {:error, reasons} ->
        case Enum.find(reasons, &String.starts_with?(&1, "version")) do
          nil -> {:ok, nil}
          reason -> {:error, reason}
        end
    end
  end

  @doc """
  The entries for a snapshot (`config`, `files` prepared by `prepare_file/2`)
  and the local playbooks (all of them, drafts included), plus `links`: the
  name pairs with equal content, as `{playbook, file}`, that should be linked.
  An entry's `error` is an `:unreadable` file's parse error (a string), or
  `{:too_long, bytes}` for a body that many bytes over the export limit.
  """
  def build(%{config: config, files: files}, locals) do
    files = Enum.sort_by(files, & &1.path)
    linked_here = Enum.filter(locals, &linked_here?(&1, config))

    # 1. by origin
    {by_origin, files_left} =
      Enum.reduce(files, {[], []}, fn file, {pairs, left} ->
        case Enum.find(linked_here, &(&1.origin_path == file.path)) do
          nil -> {pairs, [file | left]}
          playbook -> {[{playbook, file, :origin} | pairs], left}
        end
      end)

    files_left = Enum.reverse(files_left)
    paired_ids = MapSet.new(by_origin, fn {p, _, _} -> p.id end)

    # 2. by name, files in path order
    {by_name, files_left, paired_ids} =
      Enum.reduce(files_left, {[], [], paired_ids}, fn file, {pairs, left, ids} ->
        match =
          file.error == nil &&
            Enum.find(locals, fn p ->
              p.name == file.name and not MapSet.member?(ids, p.id) and
                not linked_here?(p, config)
            end)

        if match,
          do: {[{match, file, :name} | pairs], left, MapSet.put(ids, match.id)},
          else: {pairs, [file | left], ids}
      end)

    files_left = Enum.reverse(files_left)
    pairs = Enum.reverse(by_origin) ++ Enum.reverse(by_name)

    pair_entries = Enum.map(pairs, fn {p, f, how} -> pair_entry(p, f, how, config) end)

    links =
      for {p, f, :name} <- pairs, f.error == nil, Text.content_hash(p.body) == f.hash, do: {p, f}

    # 3. remote files left over
    new_entries = new_entries(files_left, locals)

    # 4. local playbooks left over (enabled only)
    paths = MapSet.new(files, & &1.path)

    local_entries =
      locals
      |> Enum.reject(&(MapSet.member?(paired_ids, &1.id) or not &1.enabled))
      |> Enum.map(&local_entry(&1, paths, config))

    entries =
      (pair_entries ++ new_entries ++ local_entries)
      |> Enum.sort_by(&String.downcase(&1.name))

    %{entries: entries, links: links}
  end

  @doc "Whether a playbook follows a file in the configured repo and folder."
  # GitHub's owner and repo names are case-insensitive
  def linked_here?(%Playbook{origin_repo: repo, origin_path: path}, %{repo: here, folder: folder})
      when is_binary(repo) and is_binary(here) and is_binary(path),
      do: String.downcase(repo) == String.downcase(here) and in_folder?(path, folder)

  def linked_here?(_playbook, _config), do: false

  defp in_folder?(path, folder) when folder in [nil, ""], do: not String.contains?(path, "/")
  defp in_folder?(path, folder), do: Path.dirname(path) == folder

  defp pair_entry(playbook, file, how, config) do
    base = entry(playbook, file)

    if file.error do
      %{base | state: :unreadable, error: file.error}
    else
      hl = Text.content_hash(playbook.body)

      state =
        cond do
          hl == file.hash -> :up_to_date
          in_pr?(playbook, hl) -> :in_pr
          how == :name -> :name_clash
          file.hash != playbook.origin_sha and hl == playbook.origin_sha -> :update
          hl != playbook.origin_sha and file.hash == playbook.origin_sha -> :edited
          true -> :both_changed
        end

      %{base | state: state, base_version: if(how == :origin, do: playbook.origin_version)}
      |> put_export(playbook, file.name, config)
    end
  end

  defp new_entries(files, locals) do
    taken = MapSet.new(locals, & &1.name)

    # plain names first: a file whose name is free imports under it (the
    # first of several with one name), so a copy name never takes it
    {plain, taken} =
      Enum.reduce(files, {MapSet.new(), taken}, fn file, {plain, taken} ->
        if file.error == nil and not MapSet.member?(taken, file.name),
          do: {MapSet.put(plain, file.path), MapSet.put(taken, file.name)},
          else: {plain, taken}
      end)

    {entries, _} =
      Enum.map_reduce(files, taken, fn file, taken ->
        base = entry(nil, file)

        cond do
          file.error ->
            {%{base | state: :unreadable, error: file.error}, taken}

          MapSet.member?(plain, file.path) ->
            {%{base | state: :new}, taken}

          true ->
            copy = copy_name(file.name, taken)
            {%{base | state: :new, import_as: copy}, MapSet.put(taken, copy)}
        end
      end)

    entries
  end

  defp local_entry(playbook, paths, config) do
    base = entry(playbook, nil)
    hl = Text.content_hash(playbook.body)

    cond do
      in_pr?(playbook, hl) ->
        %{base | state: :in_pr}

      MapSet.member?(paths, Text.file_path(config.folder, playbook.name)) ->
        %{base | state: :name_taken}

      true ->
        put_export(%{base | state: :not_on_github}, playbook, playbook.name, config)
    end
  end

  defp entry(playbook, file) do
    %{
      key: if(file, do: file.path, else: "local:" <> playbook.id),
      name: name(playbook, file),
      description: (playbook && playbook.description) || (file && file.description),
      state: nil,
      playbook: playbook,
      local_version: playbook && playbook.version,
      remote_version: file && file.version,
      base_version: nil,
      export_version: nil,
      path: file && file.path,
      sha: file && file.sha,
      pr: playbook && playbook.pr_number && %{number: playbook.pr_number, url: playbook.pr_url},
      import_as: nil,
      error: nil
    }
  end

  defp name(%Playbook{name: name}, _file), do: name
  defp name(nil, %{name: name}) when is_binary(name), do: name
  defp name(nil, %{path: path}), do: path |> Path.basename() |> Path.rootname()

  defp in_pr?(%Playbook{pr_number: n, pr_sha: sha}, hash), do: is_integer(n) and sha == hash

  # the number an export would write (never below GitHub's), or nil and why
  defp put_export(%{state: state} = entry, playbook, remote_name, _config)
       when state in @exportable do
    remote = entry.remote_version || 0
    local = playbook.version || 1

    version =
      if entry.path && remote >= local, do: remote + 1, else: local

    size = byte_size(Text.put_name(playbook.body, remote_name || playbook.name))

    if size > @max_body_bytes,
      do: %{entry | error: {:too_long, size - @max_body_bytes}},
      else: %{entry | export_version: version}
  end

  defp put_export(entry, _playbook, _remote_name, _config), do: entry

  @doc """
  A free name for a copy of `name`, not in `taken`: `<name>-2`, `<name>-3`,
  …, with `name` shortened so the whole stays within 40 characters.
  """
  def copy_name(name, taken) do
    Stream.iterate(2, &(&1 + 1))
    |> Stream.map(fn n ->
      suffix = "-#{n}"
      (name |> String.slice(0, 40 - String.length(suffix)) |> String.trim_trailing("-")) <> suffix
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end
end
