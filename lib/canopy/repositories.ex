defmodule Canopy.Repositories do
  @moduledoc """
  Local git repositories. Git is always invoked with an argument list and a
  working directory, never through a shell.
  """

  import Ecto.Query, warn: false

  alias Canopy.Repo
  alias Canopy.Repositories.Repository

  @doc "Repositories with their open channels preloaded, for the sidebar."
  def list_with_channels do
    channels =
      Canopy.Channels.list()
      |> Enum.reject(&Canopy.Channels.dm?/1)
      |> Enum.group_by(& &1.repository_id)

    Enum.map(list(), &Map.put(&1, :channels, Map.get(channels, &1.id, [])))
  end

  def list do
    Repo.all(from r in Repository, order_by: [asc: r.name, asc: r.id])
  end

  def get!(id), do: Repo.get!(Repository, id)

  def get_by_path(path) when is_binary(path) do
    Repo.get_by(Repository, path: Path.expand(path))
  end

  @doc """
  Registers a repository. The path must be absolute, exist, and contain `.git`.
  Paths outside the user's home directory are rejected unless
  `allow_outside_home: true` is given.
  """
  def create(attrs, opts \\ []) do
    %Repository{}
    |> Repository.changeset(attrs)
    |> validate_path(opts)
    |> Repo.insert()
  end

  def delete(%Repository{} = repository), do: Repo.delete(repository)

  @doc "Changeset for the repository form (path rules are applied by `create/2`)."
  def change(%Repository{} = repository, attrs \\ %{}),
    do: Repository.changeset(repository, attrs)

  @doc "Returns `{:ok, branch}` for the checked-out branch (or a short commit id when detached)."
  def current_branch(repo_or_path) do
    path = path_of(repo_or_path)

    case git(path, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {:ok, branch} when branch != "" -> {:ok, branch}
      _ -> git(path, ["rev-parse", "--short", "HEAD"])
    end
  end

  @doc "Returns `{:ok, lines}` from `git status --porcelain`."
  def status(repo_or_path) do
    with {:ok, output} <- git(path_of(repo_or_path), ["status", "--porcelain"]) do
      {:ok, output |> String.split("\n", trim: true)}
    end
  end

  @doc "Returns `{:ok, text}` from `git diff --stat` (working tree against the index)."
  def diff_stat(repo_or_path) do
    git(path_of(repo_or_path), ["diff", "--stat"])
  end

  @doc "Returns `{:ok, files}` listing paths changed in the working tree, staged or not."
  def changed_files(repo_or_path) do
    with {:ok, lines} <- status(repo_or_path) do
      files =
        lines
        |> Enum.map(fn line -> line |> String.slice(3..-1//1) |> String.trim() end)
        |> Enum.reject(&(&1 == ""))

      {:ok, files}
    end
  end

  @doc """
  Returns `{:ok, patch}` for one file: the working tree against `HEAD` (staged
  changes included). Untracked files, or files in a repository without commits,
  are shown as additions against an empty file.
  """
  def file_diff(repo_or_path, file) when is_binary(file) do
    path = path_of(repo_or_path)

    case git(path, ["diff", "HEAD", "--", file]) do
      {:ok, ""} -> untracked_diff(path, file)
      {:ok, patch} -> {:ok, patch}
      {:error, _} -> untracked_diff(path, file)
    end
  end

  # `git diff --no-index` exits 1 when the files differ, so the patch arrives as an error.
  defp untracked_diff(path, file) do
    case git(path, ["diff", "--no-index", "--", "/dev/null", file]) do
      {:ok, patch} -> {:ok, patch}
      {:error, "diff --git" <> _ = patch} -> {:ok, patch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Runs git with an argument list inside `path`. Never interpolates into a shell."
  def git(path, args) when is_binary(path) and is_list(args) do
    opts = [cd: path, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]]

    case System.cmd("git", args, opts) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    e in ErlangError -> {:error, "git could not be started: #{Exception.message(e)}"}
  end

  defp path_of(%Repository{path: path}), do: path
  defp path_of(path) when is_binary(path), do: path

  defp validate_path(changeset, opts) do
    allow_outside_home = Keyword.get(opts, :allow_outside_home, false)

    Ecto.Changeset.validate_change(changeset, :path, fn :path, path ->
      cond do
        not is_binary(path) or path == "" ->
          [path: "is required"]

        Path.type(path) != :absolute ->
          [path: "must be an absolute path"]

        not File.dir?(path) ->
          [path: "does not exist"]

        not File.exists?(Path.join(path, ".git")) ->
          [path: "is not a git repository"]

        not allow_outside_home and not inside_home?(path) ->
          [path: "must be inside your home directory"]

        true ->
          []
      end
    end)
  end

  defp inside_home?(path) do
    home = System.user_home!() |> Path.expand()
    path = Path.expand(path)
    path == home or String.starts_with?(path, home <> "/")
  end
end
