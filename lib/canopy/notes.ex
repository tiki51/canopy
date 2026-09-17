defmodule Canopy.Notes do
  @moduledoc """
  The `.canopy/` workspace inside a repository: what the team knows about this
  codebase, kept outside the source tree.

      .canopy/
        README.md          what this directory is
        NOTES.md           the team's shared notes about this repository
        files/             documents shared in Canopy, copied here for agents to read
        out/               where agents write files they intend to share

  `NOTES.md` is one Markdown document per repository. Every agent working in
  the repository gets it in its system prompt and updates it through the
  `notes_read` and `notes_write` tools, the way its own memory works across
  repositories. You can edit the file by hand; Canopy keeps the directory out
  of git through `.git/info/exclude` so it never shows up as a change. Every
  function here is best-effort: a missing or read-only repository returns an
  error instead of raising, and never blocks a turn.
  """

  @dir ".canopy"
  @exclude_line ".canopy/"
  @max_bytes 64 * 1024
  @inline_chars 3_000

  @readme """
  # Canopy workspace

  What Canopy's agents keep about this repository. `NOTES.md` is the team's
  shared notes; agents read it in every prompt and add to it as they learn.
  `files/` holds copies of documents shared in Canopy chats (`<doc id>-<name>`),
  and `out/` is where agents write files they intend to share. Canopy keeps
  this directory out of git through `.git/info/exclude`; remove that line if
  you want to commit the notes.
  """

  @shared_header """
  # Shared notes

  Facts every agent working here should know: conventions, how to run things,
  decisions that stuck. Short, current, dated. Delete what is no longer true.
  """

  def max_bytes, do: @max_bytes
  def inline_chars, do: @inline_chars

  def dir(repository_path), do: Path.join(repository_path, @dir)
  def shared_path(repository_path), do: Path.join(dir(repository_path), "NOTES.md")

  @doc "Creates the workspace, its shared files, and the git exclude entry. Idempotent."
  def ensure_workspace(repository_path) when is_binary(repository_path) do
    with :ok <- File.mkdir_p(dir(repository_path)),
         :ok <- write_new(Path.join(dir(repository_path), "README.md"), @readme),
         :ok <- write_new(shared_path(repository_path), @shared_header) do
      exclude_from_git(repository_path)
    end
  end

  @doc """
  The shared notes as a document: the file without its standing header, so an
  untouched file reads as empty. Missing file or repository is an empty string.
  """
  @spec get(String.t()) :: String.t()
  def get(repository_path) when is_binary(repository_path) do
    case File.read(shared_path(repository_path)) do
      {:ok, contents} -> strip_header(contents)
      {:error, _} -> ""
    end
  end

  @doc """
  Replaces the shared notes. The standing header is kept above the body so the
  file explains itself to whoever opens it. `{:error, :too_large}` past the
  size cap; other file errors come back as `{:error, reason}`.
  """
  @spec put(String.t(), String.t()) :: {:ok, String.t()} | {:error, :too_large | term}
  def put(repository_path, body) when is_binary(repository_path) and is_binary(body) do
    body = body |> strip_header() |> String.trim()

    if byte_size(body) > @max_bytes do
      {:error, :too_large}
    else
      contents = if body == "", do: @shared_header, else: @shared_header <> "\n" <> body <> "\n"

      with :ok <- ensure_workspace(repository_path),
           :ok <- File.write(shared_path(repository_path), contents) do
        {:ok, body}
      end
    end
  end

  @doc "Appends a block to the shared notes, separated by a blank line."
  def append(repository_path, text) when is_binary(text) do
    current = get(repository_path)
    text = String.trim(text)
    joined = if current == "", do: text, else: current <> "\n\n" <> text
    put(repository_path, joined)
  end

  @doc """
  The notes as they go into a system prompt: everything when short, otherwise
  the first #{@inline_chars} characters and a pointer to the tool.
  """
  def for_prompt(repository_path) do
    case get(repository_path) do
      "" ->
        "The shared notes for this repository are empty so far."

      body when byte_size(body) <= @inline_chars ->
        "Shared notes for this repository (read them; add to them with canopy_notes_write when you learn something every agent here should know):\n" <>
          body

      body ->
        "Shared notes for this repository (add to them with canopy_notes_write):\n" <>
          String.slice(body, 0, @inline_chars) <>
          "\n…(notes continue; read all of them with canopy_notes_read.)"
    end
  end

  # The header is Canopy's, not the team's: it is dropped when reading so
  # agents see only what was written, and put back when writing.
  defp strip_header(contents) do
    contents
    |> String.replace_prefix(@shared_header, "")
    |> String.replace_prefix(String.trim(@shared_header), "")
    |> String.trim()
  end

  defp write_new(path, contents) do
    if File.exists?(path), do: :ok, else: File.write(path, contents)
  end

  # `.git/info/exclude` is git's per-clone ignore list: it keeps `.canopy/` out
  # of status and diffs without touching the project's own .gitignore.
  defp exclude_from_git(repository_path) do
    git_dir = Path.join(repository_path, ".git")

    if File.dir?(git_dir) do
      exclude = Path.join([git_dir, "info", "exclude"])

      with :ok <- File.mkdir_p(Path.dirname(exclude)) do
        current = File.read(exclude) |> then(fn {_, c} -> if(is_binary(c), do: c, else: "") end)

        if Enum.member?(String.split(current, "\n"), @exclude_line) do
          :ok
        else
          sep = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"

          File.write(
            exclude,
            current <> sep <> "# Canopy agent workspace\n" <> @exclude_line <> "\n"
          )
        end
      end
    else
      :ok
    end
  end
end
