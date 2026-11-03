defmodule Canopy.Playbooks.Sharing.Remote.GHTest do
  # sets environment variables the fake gh reads, so not async
  use ExUnit.Case, async: false

  alias Canopy.GitHub
  alias Canopy.GitHub.CLI
  alias Canopy.Playbooks.Sharing.Remote.GH

  @fixtures Path.expand("../../../../support/gh_fixtures", __DIR__)
  @vars ~w(FAKE_GH_FIXTURE FAKE_GH_FIXTURE_api FAKE_GH_FIXTURE_version FAKE_GH_FIXTURE_auth
           FAKE_GH_EXIT FAKE_GH_EXIT_auth FAKE_GH_EXIT_api FAKE_GH_LOG FAKE_GH_SEQUENCE)

  @blob_sha "5b27c126dda0e785eb048852ed4f14c8ce388b09"

  setup do
    log = Path.join(System.tmp_dir!(), "fake_gh_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_GH_LOG", log)

    on_exit(fn ->
      Enum.each(@vars, &System.delete_env/1)
      File.rm(log)
    end)

    %{log: log}
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp api(name), do: System.put_env("FAKE_GH_FIXTURE_api", fixture(name))

  # the nth `gh api` call prints the nth fixture
  defp sequence(names) do
    dir = Path.join(System.tmp_dir!(), "fake_gh_seq_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    names
    |> Enum.with_index(1)
    |> Enum.each(fn {name, n} -> File.cp!(fixture(name), Path.join(dir, "#{n}.txt")) end)

    System.put_env("FAKE_GH_SEQUENCE", dir)
    on_exit(fn -> File.rm_rf(dir) end)
  end

  defp calls(log) do
    log
    |> File.read!()
    |> String.split("--\n", trim: true)
    |> Enum.map(&String.split(&1, "\n", trim: true))
  end

  defp inputs(log) do
    for call <- calls(log), "input: " <> json <- call, do: Jason.decode!(json)
  end

  test "GitHub.valid_ref?/1" do
    for ref <- ~w(main dev feature/x release-1.2 a_b) do
      assert GitHub.valid_ref?(ref), ref
    end

    for ref <- ["", "..", "a..b", "a//b", "/x", "-x", "x/", "x.lock", "a b", "a~1", nil] do
      refute GitHub.valid_ref?(ref), inspect(ref)
    end
  end

  describe "CLI.api/3" do
    test "encodes the query, sends the ETag, and returns status, headers and body", %{log: log} do
      api("contents_200.txt")

      assert {:ok, 200, %{"etag" => "W/\"etag-contents-1\""}, body} =
               CLI.api("GET", "repos/o/r/contents/pb",
                 query: [ref: "feature/x y"],
                 etag: "W/\"e\""
               )

      assert body =~ "bug-fix.md"

      assert [
               [
                 "api",
                 "-i",
                 "-X",
                 "GET",
                 "-H",
                 "If-None-Match: W/\"e\"",
                 "repos/o/r/contents/pb?ref=feature%2Fx+y"
               ]
             ] = calls(log)
    end

    test "sends input through a temp file it removes afterwards", %{log: log} do
      api("tree_201.txt")
      assert {:ok, 201, _, _} = CLI.api("POST", "repos/o/r/git/trees", input: %{a: "<b>"})

      [call] = calls(log)
      [file] = for {"--input", i} <- Enum.zip(call, tl(call)), do: i
      refute File.exists?(file)
      assert inputs(log) == [%{"a" => "<b>"}]
    end

    test "structured errors" do
      api("contents_404.txt")
      System.put_env("FAKE_GH_EXIT_api", "1")
      assert {:error, {:http, 404, "Not Found"}} = CLI.api("GET", "x")

      api("pulls_422.txt")

      assert {:error, {:http, 422, "Validation Failed: A pull request already exists" <> _}} =
               CLI.api("POST", "x", input: %{})

      api("auth_required.txt")
      System.put_env("FAKE_GH_EXIT_api", "4")
      assert {:error, :gh_signed_out} = CLI.api("GET", "x")

      System.delete_env("FAKE_GH_FIXTURE_api")
      System.put_env("FAKE_GH_EXIT_api", "1")
      assert {:error, {:gh, 1, "no output"}} = CLI.api("GET", "x")
    end

    test "a missing gh is :gh_missing" do
      previous = Application.get_env(:canopy, :github)
      Application.put_env(:canopy, :github, binary: "/nonexistent/gh")
      on_exit(fn -> Application.put_env(:canopy, :github, previous) end)

      assert {:error, :gh_missing} = CLI.api("GET", "x")
    end
  end

  describe "reads" do
    test "repo: default branch and push access" do
      api("repo_push_false.txt")
      assert {:ok, %{default_branch: "develop", can_push?: false}} = GH.repo("acme/playbooks")
    end

    test "list keeps files with their path, sha and size", %{log: log} do
      api("contents_200.txt")

      assert {:ok, %{etag: "W/\"etag-contents-1\"", files: files}} =
               GH.list("acme/playbooks", "main", "playbooks", nil)

      assert %{path: "playbooks/bug-fix.md", sha: @blob_sha, size: 133} in files
      refute Enum.any?(files, &(&1.path == "playbooks/old"))
      assert [[_, _, _, _, "repos/acme/playbooks/contents/playbooks?ref=main"]] = calls(log)
    end

    test "list at the root has no folder in the path", %{log: log} do
      api("contents_200.txt")
      assert {:ok, _} = GH.list("acme/playbooks", "main", "", "W/\"x\"")
      assert [[_, _, _, _, "-H", _, "repos/acme/playbooks/contents?ref=main"]] = calls(log)
    end

    test "list: 304 is not modified" do
      api("not_modified.txt")
      System.put_env("FAKE_GH_EXIT_api", "1")
      assert {:ok, :not_modified} = GH.list("acme/playbooks", "main", "playbooks", "W/\"x\"")
    end

    test "list: a missing folder on an existing branch is :no_folder; a missing branch isn't",
         %{log: log} do
      sequence(["contents_404.txt", "ref_200.txt"])
      assert {:ok, :no_folder} = GH.list("acme/playbooks", "dev", "playbooks", nil)
      assert List.last(List.last(calls(log))) == "repos/acme/playbooks/branches/dev"

      sequence(["contents_404.txt", "contents_404.txt"])

      assert {:error, {:not_found, "branch dev not found"}} =
               GH.list("acme/playbooks", "dev", "playbooks", nil)
    end

    test "read decodes the base64 blob" do
      api("blob_200.txt")
      assert {:ok, text} = GH.read("acme/playbooks", @blob_sha)
      assert text =~ "name: bug-fix\nversion: 3\n"
    end

    test "last_commit names the author" do
      api("commits_200.txt")

      assert {:ok, %{by: "mkoh", at: ~U[2026-10-30 12:00:00Z]}} =
               GH.last_commit("acme/playbooks", "main", "playbooks/bug-fix.md")
    end

    test "pr: merged" do
      api("pull_merged.txt")
      assert {:ok, :merged} = GH.pr("acme/playbooks", 14)
    end

    test "error kinds keep GitHub's text" do
      System.put_env("FAKE_GH_EXIT_api", "1")

      api("contents_404.txt")
      assert {:error, {:not_found, "Not Found (HTTP 404)"}} = GH.repo("acme/playbooks")

      api("forbidden_push.txt")
      assert {:error, {:read_only, "Resource not accessible" <> _}} = GH.repo("acme/playbooks")

      api("forbidden_rate.txt")
      assert {:error, {:gh_failed, "API rate limit exceeded" <> _}} = GH.repo("acme/playbooks")

      api("auth_required.txt")
      assert {:error, {:gh_signed_out, _}} = GH.repo("acme/playbooks")
    end

    test "account: signed in, signed out, too old" do
      System.put_env("FAKE_GH_FIXTURE_version", fixture("version.txt"))
      System.put_env("FAKE_GH_FIXTURE_auth", fixture("auth_status.txt"))
      assert {:ok, "octocat"} = GH.account()

      System.put_env("FAKE_GH_FIXTURE_auth", fixture("auth_required.txt"))
      System.put_env("FAKE_GH_EXIT_auth", "1")
      assert {:error, {:gh_signed_out, _}} = GH.account()

      System.put_env("FAKE_GH_FIXTURE_version", fixture("old_version.txt"))
      assert {:error, {:gh_too_old, "gh version 1.14.0 is too old" <> _}} = GH.account()
    end
  end

  describe "open_pr" do
    @files [%{path: "playbooks/bug-fix.md", content: "---\nname: bug-fix\n---\n"}]

    defp open_pr,
      do: GH.open_pr("acme/playbooks", "main", "canopy/playbooks-1102-2214", @files, "T", "B")

    test "six calls through the git data API", %{log: log} do
      sequence(
        ~w(ref_200.txt commit_200.txt tree_201.txt git_commit_201.txt ref_201.txt pulls_201.txt)
      )

      assert {:ok,
              %{
                number: 14,
                url: "https://github.com/acme/playbooks/pull/14",
                branch: "canopy/playbooks-1102-2214"
              }} = open_pr()

      paths =
        Enum.map(calls(log), fn call -> Enum.find(call, &String.starts_with?(&1, "repos/")) end)

      assert paths == [
               "repos/acme/playbooks/git/ref/heads/main",
               "repos/acme/playbooks/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               "repos/acme/playbooks/git/trees",
               "repos/acme/playbooks/git/commits",
               "repos/acme/playbooks/git/refs",
               "repos/acme/playbooks/pulls"
             ]

      assert [tree, commit, ref, pull] = inputs(log)

      assert tree == %{
               "base_tree" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
               "tree" => [
                 %{
                   "path" => "playbooks/bug-fix.md",
                   "mode" => "100644",
                   "type" => "blob",
                   "content" => "---\nname: bug-fix\n---\n"
                 }
               ]
             }

      assert commit == %{
               "message" => "T",
               "tree" => "cccccccccccccccccccccccccccccccccccccccc",
               "parents" => ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
             }

      assert ref["ref"] == "refs/heads/canopy/playbooks-1102-2214"

      assert pull == %{
               "title" => "T",
               "head" => "canopy/playbooks-1102-2214",
               "base" => "main",
               "body" => "B"
             }
    end

    test "an existing branch name gets -2, then -3", %{log: log} do
      sequence(
        ~w(ref_200.txt commit_200.txt tree_201.txt git_commit_201.txt refs_422.txt refs_422.txt ref_201.txt pulls_201.txt)
      )

      assert {:ok, %{branch: "canopy/playbooks-1102-2214-3"}} = open_pr()

      refs = for %{"ref" => r} <- inputs(log), do: r

      assert refs == [
               "refs/heads/canopy/playbooks-1102-2214",
               "refs/heads/canopy/playbooks-1102-2214-2",
               "refs/heads/canopy/playbooks-1102-2214-3"
             ]
    end

    test "a failure before the branch exists deletes nothing", %{log: log} do
      sequence(~w(ref_200.txt commit_200.txt forbidden_push.txt))
      assert {:error, {:pr_failed, "Resource not accessible" <> _}} = open_pr()
      refute Enum.any?(calls(log), &("DELETE" in &1))
    end

    test "a failed pull request deletes the branch and reports the pulls error", %{log: log} do
      sequence(
        ~w(ref_200.txt commit_200.txt tree_201.txt git_commit_201.txt ref_201.txt pulls_422.txt contents_404.txt)
      )

      assert {:error, {:pr_failed, "Validation Failed: A pull request already exists" <> _}} =
               open_pr()

      assert [
               "api",
               "-i",
               "-X",
               "DELETE",
               "repos/acme/playbooks/git/refs/heads/canopy/playbooks-1102-2214"
             ] =
               List.last(calls(log))
    end
  end
end
