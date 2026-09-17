defmodule Canopy.NotesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Notes, Repositories}

  test "registering a repository creates the workspace and keeps it out of git" do
    path = git_dir_fixture()
    {:ok, repository} = Repositories.create(%{path: path}, allow_outside_home: true)

    assert File.dir?(Path.join(path, ".canopy"))
    assert File.read!(Path.join(path, ".canopy/README.md")) =~ "Canopy workspace"
    assert File.read!(Notes.shared_path(path)) =~ "# Shared notes"

    exclude = File.read!(Path.join(path, ".git/info/exclude"))
    assert exclude =~ "\n.canopy/\n"

    # idempotent: no duplicate exclude line, files untouched
    File.write!(Notes.shared_path(path), "# Shared notes\n\n## 2026-09-09\n- keep me\n")
    assert :ok = Notes.ensure_workspace(path)
    assert File.read!(Notes.shared_path(path)) =~ "keep me"
    assert length(String.split(File.read!(Path.join(path, ".git/info/exclude")), ".canopy/")) == 2

    # git does not see it
    File.write!(Path.join(path, ".canopy/scratch.md"), "x")
    assert {:ok, []} = Repositories.status(repository)
  end

  test "get, put, append, size cap, and the prompt form" do
    path = git_dir_fixture()

    # nothing there yet: no file, then only the header
    assert Notes.get(path) == ""
    assert Notes.for_prompt(path) =~ "empty so far"
    assert :ok = Notes.ensure_workspace(path)
    assert Notes.get(path) == ""
    assert Notes.for_prompt(path) =~ "empty so far"

    assert {:ok, _} =
             Notes.append(path, "## 2026-09-15\n- Run `mix precommit` before a phase is done.\n")

    assert Notes.get(path) == "## 2026-09-15\n- Run `mix precommit` before a phase is done."

    # the file keeps its standing header above what the team wrote
    file = File.read!(Notes.shared_path(path))
    assert file =~ "# Shared notes"
    assert file =~ "\n\n## 2026-09-15\n- Run `mix precommit`"

    assert {:ok, body} = Notes.append(path, "- Tests never spawn the real claude CLI.")
    assert body =~ "phase is done.\n\n- Tests never spawn"
    assert Notes.for_prompt(path) =~ "Shared notes for this repository"
    assert Notes.for_prompt(path) =~ "canopy_notes_write"
    assert Notes.for_prompt(path) =~ "real claude CLI"

    # replace, with or without the header pasted back in
    assert {:ok, "fresh"} = Notes.put(path, "fresh\n\n")
    assert {:ok, "fresh"} = Notes.put(path, File.read!(Notes.shared_path(path)))
    assert Notes.get(path) == "fresh"

    assert {:error, :too_large} = Notes.put(path, String.duplicate("x", Notes.max_bytes() + 1))
    assert Notes.get(path) == "fresh"

    long = String.duplicate("a line of notes\n", 1_000)
    {:ok, _} = Notes.put(path, long)
    prompt = Notes.for_prompt(path)
    assert prompt =~ "notes continue"
    assert prompt =~ "canopy_notes_read"
    assert String.length(prompt) < String.length(long)

    assert {:ok, ""} = Notes.put(path, "")
    assert File.read!(Notes.shared_path(path)) =~ "# Shared notes"
    assert Notes.get(path) == ""
  end

  test "a hand-edited file without the header still reads whole" do
    path = git_dir_fixture()
    :ok = Notes.ensure_workspace(path)
    File.write!(Notes.shared_path(path), "# Our notes\n\n- keep me\n")
    assert Notes.get(path) == "# Our notes\n\n- keep me"
  end

  test "a missing repository is an error, not a crash" do
    assert {:error, _} = Notes.ensure_workspace("/definitely/not/here/" <> unique_suffix())
  end
end
