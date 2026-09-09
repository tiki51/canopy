defmodule CanopyWeb.RepositoriesLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.Fixtures
  alias Canopy.Repositories

  # `Fixtures.git_dir_fixture/0` lives under the project's `_build`, which is inside
  # the home directory; this one is in the system temp dir, outside it.
  defp outside_home_git_dir do
    path = Path.join(System.tmp_dir!(), "canopy-lv-" <> Fixtures.unique_suffix())
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", path])
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "renders the empty state without repositories", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/repositories")

    assert has_element?(view, "#repositories-empty")
    assert has_element?(view, "#repository-form")
  end

  test "lists registered repositories with their branch", %{conn: conn} do
    repository = Fixtures.repository_fixture()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    assert has_element?(view, "#repository-#{repository.id}", repository.name)
    assert has_element?(view, "#repository-#{repository.id}", "main")
    assert has_element?(view, "#sidebar-repo-#{repository.id}")
  end

  test "adds a git repository inside the home directory", %{conn: conn} do
    path = Fixtures.git_dir_fixture()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form", repository: %{path: path, name: "My Project"})
    |> render_submit()

    assert %{name: "My Project"} = repository = Repositories.get_by_path(path)
    assert has_element?(view, "#repository-#{repository.id}", "My Project")
    assert has_element?(view, "#sidebar-repo-#{repository.id}")
    refute has_element?(view, "#repositories-empty")
    # The form is reset for the next entry.
    refute has_element?(view, "#repository-form input[name='repository[path]'][value='#{path}']")
  end

  test "rejects a path that does not exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form",
      repository: %{path: "/definitely/not/here"},
      allow_outside_home: "true"
    )
    |> render_submit()

    assert has_element?(view, "#repository-form", "does not exist")
    assert Repositories.list() == []
  end

  test "rejects a directory that is not a git repository", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "canopy-plain-" <> Fixtures.unique_suffix())
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form", repository: %{path: path}, allow_outside_home: "true")
    |> render_submit()

    assert has_element?(view, "#repository-form", "is not a git repository")
    assert Repositories.list() == []
  end

  test "rejects a path outside the home directory unless allowed", %{conn: conn} do
    path = outside_home_git_dir()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form", repository: %{path: path})
    |> render_submit()

    assert has_element?(view, "#repository-form", "must be inside your home directory")
    assert Repositories.list() == []

    view
    |> form("#repository-form", repository: %{path: path}, allow_outside_home: "true")
    |> render_submit()

    assert %{} = repository = Repositories.get_by_path(path)
    assert has_element?(view, "#repository-#{repository.id}")
  end

  test "deletes a repository", %{conn: conn} do
    repository = Fixtures.repository_fixture()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view |> element("#delete-repository-#{repository.id}") |> render_click()

    refute has_element?(view, "#repository-#{repository.id}")
    refute has_element?(view, "#sidebar-repo-#{repository.id}")
    assert Repositories.list() == []
  end
end
