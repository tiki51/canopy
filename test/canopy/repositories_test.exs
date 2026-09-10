defmodule Canopy.RepositoriesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Repositories

  test "create/1 requires an existing git directory" do
    assert {:error, changeset} = Repositories.create(%{path: "relative/path"})
    assert %{path: ["must be an absolute path"]} = errors_on(changeset)

    assert {:error, changeset} = Repositories.create(%{path: "/definitely/not/here"})
    assert %{path: ["does not exist"]} = errors_on(changeset)

    plain_dir = Path.join(System.tmp_dir!(), "canopy-not-git-" <> unique_suffix())
    File.mkdir_p!(plain_dir)
    on_exit(fn -> File.rm_rf!(plain_dir) end)

    # a plain directory is initialised rather than rejected
    assert Repositories.needs_init?(plain_dir)
    assert {:ok, repository} = Repositories.create(%{path: plain_dir}, allow_outside_home: true)
    assert File.dir?(Path.join(plain_dir, ".git"))
    refute Repositories.needs_init?(plain_dir)
    assert {:ok, branch} = Repositories.current_branch(repository)
    assert branch in ["main", "master"]
  end

  test "create/1 rejects paths outside the home directory unless allowed" do
    path = git_dir_fixture()
    outside = Path.join(System.tmp_dir!(), "canopy-outside-" <> unique_suffix())
    File.mkdir_p!(outside)
    {_, 0} = System.cmd("git", ["init", "-q", outside])
    on_exit(fn -> File.rm_rf!(outside) end)

    if String.starts_with?(Path.expand(outside), System.user_home!()) do
      # tmp_dir lives under home on this machine; nothing to check
      assert {:ok, _} = Repositories.create(%{path: outside})
    else
      assert {:error, changeset} = Repositories.create(%{path: outside})
      assert %{path: ["must be inside your home directory"]} = errors_on(changeset)
      assert {:ok, _} = Repositories.create(%{path: outside}, allow_outside_home: true)
    end

    assert {:ok, repository} = Repositories.create(%{path: path}, allow_outside_home: true)
    assert repository.name == Path.basename(path)
    assert {:error, changeset} = Repositories.create(%{path: path}, allow_outside_home: true)
    assert %{path: ["has already been taken"]} = errors_on(changeset)
  end

  test "git helpers report branch, status, and diff stat" do
    repository = repository_fixture()
    path = repository.path

    assert {:ok, "main"} = Repositories.current_branch(repository)
    assert {:ok, []} = Repositories.status(repository)

    File.write!(Path.join(path, "README.md"), "hello\n")
    assert {:ok, ["?? README.md"]} = Repositories.status(path)
    assert {:ok, ["README.md"]} = Repositories.changed_files(path)

    {_, 0} = System.cmd("git", ["-C", path, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    File.write!(Path.join(path, "README.md"), "hello world\n")

    assert {:ok, stat} = Repositories.diff_stat(path)
    assert stat =~ "README.md"
    assert {:error, reason} = Repositories.git(path, ["rev-parse", "nope"])
    assert reason =~ "nope"
  end

  test "list/0, get!/1, and delete/1" do
    repository = repository_fixture()
    assert Enum.map(Repositories.list(), & &1.id) == [repository.id]
    assert Repositories.get!(repository.id).path == repository.path
    assert {:ok, _} = Repositories.delete(repository)
    assert Repositories.list() == []
  end
end
