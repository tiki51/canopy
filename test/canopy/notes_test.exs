defmodule Canopy.NotesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Notes, Repositories}

  test "registering a repository creates the workspace and keeps it out of git" do
    path = git_dir_fixture()
    {:ok, repository} = Repositories.create(%{path: path}, allow_outside_home: true)

    assert File.dir?(Path.join(path, ".canopy/notes"))
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
    File.write!(Path.join(path, ".canopy/notes/scratch.md"), "x")
    assert {:ok, []} = Repositories.status(repository)
  end

  test "an agent's notes file is created with a header, once" do
    path = git_dir_fixture()
    agent = agent_fixture(%{name: "noter" <> unique_suffix()})

    assert :ok = Notes.ensure_agent_notes(path, agent)
    file = Notes.agent_path(path, agent)
    assert file == Path.join([path, ".canopy", "notes", agent.name <> ".md"])
    assert File.read!(file) =~ "# @#{agent.name} notes"
    assert File.read!(file) =~ "## YYYY-MM-DD"

    File.write!(file, "# mine\n")
    assert :ok = Notes.ensure_agent_notes(path, agent)
    assert File.read!(file) == "# mine\n"
  end

  test "a missing repository is an error, not a crash" do
    assert {:error, _} = Notes.ensure_workspace("/definitely/not/here/" <> unique_suffix())
  end
end
