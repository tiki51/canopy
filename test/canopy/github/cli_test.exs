defmodule Canopy.GitHub.CLITest do
  # sets environment variables the fake gh reads, so not async
  use ExUnit.Case, async: false

  alias Canopy.GitHub
  alias Canopy.GitHub.CLI

  @fixtures Path.expand("../../support/gh_fixtures", __DIR__)
  @vars ~w(FAKE_GH_FIXTURE FAKE_GH_FIXTURE_api FAKE_GH_FIXTURE_version FAKE_GH_FIXTURE_auth
           FAKE_GH_FIXTURE_repo FAKE_GH_EXIT FAKE_GH_EXIT_auth FAKE_GH_EXIT_api FAKE_GH_LOG)

  setup do
    # Settings are read for the binary when no override is configured; the
    # test config points at the fake, so no database is needed
    log = Path.join(System.tmp_dir!(), "fake_gh_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_GH_LOG", log)

    on_exit(fn ->
      Enum.each(@vars, &System.delete_env/1)
      File.rm(log)
    end)

    %{log: log}
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp argv(log),
    do:
      log
      |> File.read!()
      |> String.split("--\n", trim: true)
      |> Enum.map(&String.split(&1, "\n", trim: true))

  @check %{"source" => "prs", "repo" => "acme/app"}

  test "a full read returns the items, the ETag, and the poll interval", %{log: log} do
    System.put_env("FAKE_GH_FIXTURE", fixture("pulls_200.txt"))

    assert {:ok, %{etag: "W/\"etag-pulls-1\"", poll_interval: 60, items: [pr12, pr11]}} =
             CLI.probe(@check, nil)

    assert pr12 == %{
             key: "pr:12",
             title: "Fix the login button",
             url: "https://github.com/acme/app/pull/12",
             author: "alice",
             branch: "main",
             labels: ["bug"],
             workflow: nil
           }

    assert pr11.key == "pr:11"

    assert [
             [
               "api",
               "-i",
               "repos/acme/app/pulls?state=open&sort=created&direction=desc&per_page=50"
             ]
           ] =
             argv(log)
  end

  test "a conditional read sends If-None-Match and reads the 304 from the status line, not the exit code",
       %{log: log} do
    System.put_env("FAKE_GH_FIXTURE", fixture("not_modified.txt"))
    # gh exits 1 on a 304
    System.put_env("FAKE_GH_EXIT", "1")

    assert {:ok, :not_modified} = CLI.probe(@check, "W/\"etag-pulls-1\"")
    assert [["api", "-i", "-H", "If-None-Match: W/\"etag-pulls-1\"", _path]] = argv(log)
  end

  test "agent-supplied values are single argv elements, URL-encoded, never shell-interpreted",
       %{log: log} do
    System.put_env("FAKE_GH_FIXTURE", fixture("pulls_200.txt"))
    check = %{"source" => "prs", "repo" => "acme/app", "branch" => "feat/$(rm -rf ~); echo"}

    assert {:ok, _} = CLI.probe(check, nil)
    assert [["api", "-i", path]] = argv(log)
    assert path =~ "base=feat%2F%24%28rm+-rf+~%29%3B+echo"
  end

  test "failed CI runs come from the workflow_runs list", _ctx do
    System.put_env("FAKE_GH_FIXTURE", fixture("runs_200.txt"))
    check = %{"source" => "ci_failures", "repo" => "acme/app", "branch" => "main"}

    assert {:ok, %{items: [run]}} = CLI.probe(check, nil)
    assert run.key == "run:9001"
    assert run.title == "CI: Bump deps"
    assert run.workflow == ".github/workflows/ci.yml"

    assert GitHub.path(check) ==
             "repos/acme/app/actions/runs?status=failure&per_page=30&branch=main"
  end

  test "errors say what is wrong and how to fix it" do
    System.put_env("FAKE_GH_FIXTURE", fixture("not_found.txt"))
    System.put_env("FAKE_GH_EXIT", "1")
    assert {:error, reason} = CLI.probe(@check, nil)
    assert reason =~ "GitHub said 404"

    System.put_env("FAKE_GH_FIXTURE", fixture("auth_required.txt"))
    System.put_env("FAKE_GH_EXIT", "4")

    assert {:error, "gh is not logged in: run `gh auth login` in a terminal"} =
             CLI.probe(@check, nil)

    System.put_env("FAKE_GH_FIXTURE", fixture("version.txt"))
    System.put_env("FAKE_GH_EXIT", "1")
    assert {:error, reason} = CLI.probe(@check, nil)
    assert reason =~ "gh failed (exit 1)"
  end

  test "a missing binary is reported, not raised" do
    previous = Application.get_env(:canopy, :github)
    Application.put_env(:canopy, :github, Keyword.put(previous, :binary, "/nonexistent/gh"))
    on_exit(fn -> Application.put_env(:canopy, :github, previous) end)

    assert {:error, reason} = CLI.probe(@check, nil)
    assert reason =~ "gh is not installed"
  end

  # 20
  test "a gh that cannot be launched is a reason, not a crash" do
    path = Path.join(System.tmp_dir!(), "not_executable_gh_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\necho hi\n")
    File.chmod!(path, 0o644)
    on_exit(fn -> File.rm(path) end)

    previous = Application.get_env(:canopy, :github)
    Application.put_env(:canopy, :github, Keyword.put(previous, :binary, path))
    on_exit(fn -> Application.put_env(:canopy, :github, previous) end)

    assert {:error, reason} = CLI.probe(@check, nil)
    assert reason =~ "gh failed to run"
  end

  test "status reads the version and the login", %{log: log} do
    System.put_env("FAKE_GH_FIXTURE_version", fixture("version.txt"))
    System.put_env("FAKE_GH_FIXTURE_auth", fixture("auth_status.txt"))

    assert {:ok, %{version: "2.5.2", too_old?: false, logged_in?: true, account: "octocat"}} =
             CLI.status()

    assert [["--version"], ["auth", "status"]] = argv(log)

    System.put_env("FAKE_GH_FIXTURE_version", fixture("old_version.txt"))
    System.put_env("FAKE_GH_FIXTURE_auth", fixture("auth_required.txt"))
    System.put_env("FAKE_GH_EXIT_auth", "1")
    assert {:ok, %{version: "1.14.0", too_old?: true, logged_in?: false}} = CLI.status()
  end

  test "resolve_repo asks gh which GitHub repository the checkout is", %{log: log} do
    System.put_env("FAKE_GH_FIXTURE_repo", fixture("repo_view.txt"))
    assert {:ok, "acme/app"} = CLI.resolve_repo(System.tmp_dir!())
    assert [["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]] = argv(log)
  end

  describe "Canopy.GitHub" do
    test "validate refuses what the sources cannot take" do
      assert :ok = GitHub.validate(%{"source" => "issues", "repo" => "a/b", "label" => "bug"})
      assert {:error, _} = GitHub.validate(%{"source" => "stars", "repo" => "a/b"})

      assert {:error, "repo must be owner/name"} =
               GitHub.validate(%{"source" => "prs", "repo" => "a b"})

      assert {:error, _} =
               GitHub.validate(%{"source" => "releases", "repo" => "a/b", "branch" => "main"})

      assert {:error, _} =
               GitHub.validate(%{
                 "source" => "ci_failures",
                 "repo" => "a/b",
                 "workflow_file" => "../x"
               })
    end

    test "issues leave pull requests out; filters apply to any item" do
      json = [
        %{"number" => 1, "title" => "Bug", "html_url" => "u1", "labels" => [%{"name" => "Bug"}]},
        %{"number" => 2, "title" => "PR", "pull_request" => %{}, "labels" => []},
        %{"number" => 3, "title" => "Feature", "labels" => [%{"name" => "feature"}]}
      ]

      assert [%{key: "issue:1"}] =
               GitHub.items(%{"source" => "issues", "repo" => "a/b", "label" => "bug"}, json)

      assert [%{key: "issue:1"}, %{key: "issue:3"}] =
               GitHub.items(%{"source" => "issues", "repo" => "a/b"}, json)
    end

    test "describe says what a watch looks for" do
      assert GitHub.describe(%{"source" => "ci_failures", "repo" => "a/b", "branch" => "main"}) ==
               "failed CI on main in a/b"

      assert GitHub.describe(%{"source" => "prs", "repo" => "a/b", "label" => "bug"}) ==
               "new pull requests labelled bug in a/b"
    end
  end
end
