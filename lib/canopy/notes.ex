defmodule Canopy.Notes do
  @moduledoc """
  The `.canopy/` workspace inside a repository: a place for agents to keep
  notes between turns, outside the source tree.

      .canopy/
        README.md          what this directory is
        NOTES.md           shared, for facts every agent should know
        notes/<agent>.md   one per agent: its own memory of this codebase
        files/             documents shared in Canopy, copied here for agents to read

  Agents read and write these with OpenCode's own file tools; Canopy only
  creates the files, points agents at them in the system prompt, and keeps the
  directory out of git through `.git/info/exclude` so it never shows up as a
  change. Every function here is best-effort: a missing or read-only
  repository returns an error instead of raising, and never blocks a turn.
  """

  @dir ".canopy"
  @exclude_line ".canopy/"

  @readme """
  # Canopy workspace

  Notes that Canopy's agents keep about this repository. `NOTES.md` is shared;
  `notes/<agent>.md` belongs to one agent. Entries are dated. `files/` holds
  copies of documents shared in Canopy chats (`<doc id>-<name>`), and `out/`
  is where agents write files they intend to share. Canopy keeps this
  directory out of git through `.git/info/exclude`; remove that line if you
  want to commit the notes.
  """

  @shared_header """
  # Shared notes

  Facts every agent working here should know: conventions, how to run things,
  decisions that stuck. Short, current, dated. Delete what is no longer true.
  """

  def dir(repository_path), do: Path.join(repository_path, @dir)
  def shared_path(repository_path), do: Path.join(dir(repository_path), "NOTES.md")

  def agent_path(repository_path, %{name: name}),
    do: Path.join([dir(repository_path), "notes", name <> ".md"])

  @doc "Creates the workspace, its shared files, and the git exclude entry. Idempotent."
  def ensure_workspace(repository_path) when is_binary(repository_path) do
    with :ok <- File.mkdir_p(Path.join(dir(repository_path), "notes")),
         :ok <- write_new(Path.join(dir(repository_path), "README.md"), @readme),
         :ok <- write_new(shared_path(repository_path), @shared_header) do
      exclude_from_git(repository_path)
    end
  end

  @doc "Creates an agent's notes file with a header if it does not exist yet."
  def ensure_agent_notes(repository_path, %{name: name} = agent)
      when is_binary(repository_path) do
    with :ok <- ensure_workspace(repository_path) do
      write_new(agent_path(repository_path, agent), """
      # @#{name} notes

      Your memory of this repository between turns. Keep it short and current:
      what you learned, what you decided, what bit you. Date entries with
      `## YYYY-MM-DD` headings and delete what is stale.
      """)
    end
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
