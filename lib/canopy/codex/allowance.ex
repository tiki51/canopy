defmodule Canopy.Codex.Allowance do
  @moduledoc """
  What Canopy itself accepts for a Codex agent in `default` (ask first) mode,
  the counterpart of Claude Code's default allowed tools (`Edit`, `Write`,
  `Bash(git *)`): in-repository file changes outside the protected paths, and
  plain git commands. Also the path rule and the shell lexer that the
  remembered Always rules (`Canopy.Codex.Approvals`) share. Pure.

  **The simple-command test** works on Codex's raw `command`, never on its
  `commandActions` (a compound line comes back as one action):

    1. Codex's shell wrapper (`/bin/zsh -lc '…'`, `/bin/bash -lc '…'`,
       `sh -c '…'`) is undone; anything else is taken as it is.
    2. Any shell metacharacter refuses it, quoted or not.
    3. The rest is split into words by a small POSIX lexer (quotes only, no
       expansion).

  **Plain git** is an allowlist of subcommands, with the options that run a
  program or write elsewhere refused (§7.4 of the design). A refused command
  only gets a card, so the test errs on the strict side.

  **The path rule**: a path is inside the repository when, expanded and
  with its existing components resolved through symlinks, it has the
  repository's resolved root as a prefix. `..` components refuse. The
  protected paths (`.git`, `.codex`, `.claude`, `.mcp.json`, `.canopy`) are
  never accepted.
  """

  alias Canopy.Codex.Command

  @wrappers [
    ~w(/bin/zsh -lc),
    ~w(/bin/zsh -c),
    ~w(/bin/bash -lc),
    ~w(/bin/bash -c),
    ~w(/bin/sh -c),
    ~w(zsh -lc),
    ~w(bash -lc),
    ~w(bash -c),
    ~w(sh -c)
  ]

  # `$` covers `$(`, `${` and plain variable expansion (word splitting could
  # inject options).
  @metachars [
    ";",
    "&",
    "|",
    "$",
    "`",
    ">",
    "<",
    "(",
    ")",
    "{",
    "}",
    "*",
    "?",
    "[",
    "~",
    "!",
    "\n",
    "\r"
  ]

  @git_allowed ~w(status log diff show branch add commit restore switch checkout stash rev-parse ls-files blame grep merge-base)
  @git_refused_long ~w(--upload-pack --receive-pack --exec --open-files-in-pager --ext-diff --textconv --output --extcmd --tool)
  @git_refused_short ~w(x O)

  @protected ~w(.git .codex .claude .canopy)
  @protected_files ~w(.mcp.json)

  # -- Commands ---------------------------------------------------------------------

  @doc "Codex's raw command with its shell wrapper undone, or the command itself."
  def unwrap(command) when is_binary(command) do
    trimmed = String.trim(command)

    Enum.find_value(@wrappers, trimmed, fn [shell, flag] ->
      prefix = shell <> " " <> flag <> " "

      with true <- String.starts_with?(trimmed, prefix),
           {:ok, [inner]} <- lex(String.replace_prefix(trimmed, prefix, "")) do
        inner
      else
        _ -> nil
      end
    end)
  end

  def unwrap(_command), do: nil

  @doc """
  Steps 1–3: the command's words when it is a simple command (no shell
  metacharacter anywhere), else `:error`.
  """
  def simple_words(command) when is_binary(command) do
    inner = unwrap(command)

    cond do
      inner == nil -> :error
      Enum.any?(@metachars, &String.contains?(inner, &1)) -> :error
      true -> with {:ok, [_ | _] = words} <- lex(inner), do: {:ok, words}, else: (_ -> :error)
    end
  end

  def simple_words(_command), do: :error

  @doc "Whether the command is a plain git command Canopy accepts in ask-first mode."
  def plain_git?(command) do
    case simple_words(command) do
      {:ok, words} -> plain_git_words?(words)
      :error -> false
    end
  end

  @doc "Step 4 on words already lexed."
  def plain_git_words?(["git", sub | rest]) when sub in @git_allowed,
    do: not Enum.any?(rest, &refused_git_option?/1)

  def plain_git_words?(_words), do: false

  defp refused_git_option?("--" <> _ = word) do
    name = word |> String.split("=", parts: 2) |> hd()

    # git accepts unambiguous abbreviations of long options, so a word that
    # is a prefix of a refused option refuses too
    Enum.any?(@git_refused_long, fn opt ->
      name == opt or (String.length(name) > 3 and String.starts_with?(opt, name))
    end)
  end

  # short options can be bundled (`-nO./x.sh`)
  defp refused_git_option?("-" <> letters) when letters != "",
    do: Enum.any?(@git_refused_short, &String.contains?(letters, &1))

  defp refused_git_option?(_word), do: false

  @doc """
  A small POSIX lexer: words split on blanks, single and double quotes and
  backslash escapes undone, nothing expanded. `{:error, :unterminated}` for
  an open quote.
  """
  def lex(text) when is_binary(text), do: lex(String.graphemes(text), :none, nil, [])

  defp lex([], :none, nil, acc), do: {:ok, Enum.reverse(acc)}
  defp lex([], :none, word, acc), do: {:ok, Enum.reverse([word | acc])}
  defp lex([], _quote, _word, _acc), do: {:error, :unterminated}

  defp lex([c | rest], :none, word, acc) when c in [" ", "\t"],
    do: lex(rest, :none, nil, if(word, do: [word | acc], else: acc))

  defp lex(["'" | rest], :none, word, acc), do: lex(rest, :single, word || "", acc)
  defp lex(["\"" | rest], :none, word, acc), do: lex(rest, :double, word || "", acc)
  defp lex(["\\", c | rest], :none, word, acc), do: lex(rest, :none, (word || "") <> c, acc)
  defp lex([c | rest], :none, word, acc), do: lex(rest, :none, (word || "") <> c, acc)

  defp lex(["'" | rest], :single, word, acc), do: lex(rest, :none, word, acc)
  defp lex([c | rest], :single, word, acc), do: lex(rest, :single, word <> c, acc)

  defp lex(["\"" | rest], :double, word, acc), do: lex(rest, :none, word, acc)

  defp lex(["\\", c | rest], :double, word, acc) when c in ["\"", "\\", "$", "`"],
    do: lex(rest, :double, word <> c, acc)

  defp lex([c | rest], :double, word, acc), do: lex(rest, :double, word <> c, acc)

  # -- Paths ------------------------------------------------------------------------

  @doc "Whether every path is inside the repository and none is protected."
  def in_repo_files?([], _repository_path), do: false

  def in_repo_files?(paths, repository_path),
    do: Enum.all?(paths, &(inside?(&1, repository_path) and not protected?(&1, repository_path)))

  @doc "The path rule: inside the repository, symlinks resolved, no `..`."
  def inside?(path, repository_path) when is_binary(path) and is_binary(repository_path) do
    case relative(path, repository_path) do
      {:ok, _rel} -> true
      :outside -> false
    end
  end

  def inside?(_path, _repository_path), do: false

  @doc """
  Whether the path is git's or an agent's settings (never accepted): under a
  `.git`, `.codex`, `.claude` or `.canopy` at any depth (a submodule's
  `sub/.git` too), or the repository's own `.mcp.json`.
  """
  def protected?(path, repository_path) do
    case relative(path, repository_path) do
      {:ok, rel} ->
        case rel |> Path.split() |> Enum.map(&String.downcase/1) do
          [] -> false
          [only] -> only in @protected or only in @protected_files
          parts -> Enum.any?(parts, &(&1 in @protected))
        end

      :outside ->
        false
    end
  end

  @doc """
  How a card shows a path: repository-relative inside the repository,
  absolute outside it with the home directory as `~`.
  """
  def display_path(path, repository_path) when is_binary(path) do
    case relative(path, repository_path) do
      {:ok, ""} -> "."
      {:ok, rel} -> rel
      :outside -> home(Path.expand(path, repository_path || "/"))
    end
  end

  def display_path(path, _repository_path), do: path

  defp home(path) do
    home = System.user_home()

    cond do
      home in [nil, ""] ->
        path

      path == home ->
        "~"

      String.starts_with?(path, home <> "/") ->
        "~/" <> String.replace_prefix(path, home <> "/", "")

      true ->
        path
    end
  end

  # `{:ok, repo-relative}` for a path inside the repository.
  defp relative(path, repository_path) when is_binary(repository_path) do
    if ".." in Path.split(path) do
      :outside
    else
      root = Path.split(Command.resolve(repository_path))
      full = Path.split(Command.resolve(Path.expand(path, repository_path)))

      if Enum.take(full, length(root)) == root,
        do: {:ok, full |> Enum.drop(length(root)) |> join()},
        else: :outside
    end
  end

  defp relative(_path, _repository_path), do: :outside

  defp join([]), do: ""
  defp join(parts), do: Path.join(parts)
end
