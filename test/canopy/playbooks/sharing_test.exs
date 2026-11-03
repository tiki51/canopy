defmodule Canopy.Playbooks.SharingTest do
  use Canopy.DataCase, async: false

  import Canopy.PlaybookSharingHelpers

  alias Canopy.Playbooks
  alias Canopy.Playbooks.Sharing
  alias Canopy.Playbooks.Sharing.{FakeRemote, Text}

  defp create!(text, attrs \\ %{}) do
    {:ok, playbook} = Playbooks.create(Map.merge(%{body: text}, attrs))
    playbook
  end

  defp entry(status, key), do: Enum.find(status.entries, &(&1.key == key))

  # until the Refresher's read in flight has `n` callers waiting on it
  defp await_waiters(n) do
    case :sys.get_state(Canopy.Playbooks.Sharing.Refresher) do
      %{read: %{waiters: waiters}} when length(waiters) == n ->
        :ok

      _ ->
        Process.sleep(5)
        await_waiters(n)
    end
  end

  describe "config" do
    test "not set up until a repo is saved" do
      assert Sharing.config() == :not_set_up
      assert {:error, {:not_set_up, _}} = Sharing.status(max_age: 0)

      assert {:ok, %{repo: "acme/playbooks", branch: nil, folder: "playbooks"}} =
               Sharing.save_config(%{
                 "repo" => " acme/playbooks ",
                 "branch" => "",
                 "folder" => "playbooks/"
               })
    end

    test "validates the repo, branch and folder" do
      assert {:error, changeset} =
               Sharing.save_config(%{repo: "nope", branch: "a..b", folder: "x/../y"})

      errors = errors_on(changeset)
      assert errors.repo == ["must be owner/name"]
      assert errors.branch == ["isn't a branch name GitHub accepts"]
      assert errors.folder == ["must be a folder path like playbooks or team/playbooks"]

      assert {:error, changeset} = Sharing.save_config(%{repo: "a/b", folder: "./x"})
      assert errors_on(changeset).folder
    end

    test "a blank folder is the repository root" do
      assert {:ok, %{folder: ""}} = Sharing.save_config(%{repo: "a/b", folder: ""})
      assert {:ok, %{folder: ""}} = Sharing.config()
    end

    test "a blank repo turns sharing off and keeps the links" do
      text = playbook_text("triage")
      configure_sharing()
      playbook = create!(text) |> link_playbook("playbooks/triage.md", 3, text)
      Sharing.subscribe()

      assert :not_set_up = Sharing.save_config(%{"repo" => " ", "branch" => "", "folder" => ""})
      assert_receive {:playbook_sharing, :config_changed}
      assert Sharing.config() == :not_set_up
      assert Sharing.cached_status() == nil

      kept = Playbooks.get(playbook.id)
      assert kept.origin_path == "playbooks/triage.md"
      assert kept.version == playbook.version
    end

    test "save_config broadcasts and forgets the cached status" do
      configure_sharing()
      stub_remote(%{"triage" => playbook_text("triage")})
      assert {:ok, _} = Sharing.status(max_age: 0)
      assert {:ok, _} = Sharing.cached_status()

      Sharing.subscribe()
      configure_sharing(folder: "other")
      assert_receive {:playbook_sharing, :config_changed}
      assert Sharing.cached_status() == nil
    end

    test "parse_location" do
      assert Sharing.parse_location("tiki51/canopy-playbooks") ==
               %{repo: "tiki51/canopy-playbooks", branch: nil, folder: nil}

      assert Sharing.parse_location("https://github.com/o/r.git") == %{
               repo: "o/r",
               branch: nil,
               folder: nil
             }

      assert Sharing.parse_location("https://github.com/o/r/tree/dev/team/pb?x=1") ==
               %{repo: "o/r", branch: "dev", folder: "team/pb"}

      assert Sharing.parse_location("not a repo") == :error
      assert Sharing.parse_location("https://github.com/o/r/blob/main/x.md") == :error
    end
  end

  describe "check" do
    test "reports the account, push access, branch and count" do
      stub_remote(%{
        "playbooks/a-one.md" => playbook_text("a-one"),
        "playbooks/README.md" => "# hi"
      })

      assert {:ok,
              %{account: "sbarber", can_push?: true, branch: "main", folder?: true, count: 1}} =
               Sharing.check(%{repo: "acme/playbooks", branch: nil, folder: "playbooks"})

      stub_remote(%{}, can_push?: false, no_folder: true)

      assert {:ok, %{can_push?: false, folder?: false, count: 0}} =
               Sharing.check(%{repo: "acme/playbooks", branch: "", folder: "playbooks"})

      stub_remote(%{}, fail: [account: :gh_signed_out])
      assert {:error, {:gh_signed_out, _}} = Sharing.check(%{repo: "acme/playbooks"})
    end
  end

  describe "status" do
    setup do
      configure_sharing()
      :ok
    end

    test "lists files and local playbooks with their states and the resolved branch" do
      create!(playbook_text("local-only"))
      stub_remote(%{"triage" => playbook_text("triage")}, versions: %{"triage" => 3})

      assert {:ok, status} = Sharing.status(max_age: 0)
      assert status.branch == "main"
      assert status.account == "sbarber"
      assert status.can_push?

      assert %{state: :new, remote_version: 3, name: "triage"} =
               entry(status, "playbooks/triage.md")

      assert [%{state: :not_on_github, name: "local-only"}] =
               Enum.filter(status.entries, &(&1.playbook != nil))
    end

    test "a missing folder isn't an error" do
      create!(playbook_text("local-only"))
      stub_remote(%{}, no_folder: true)

      assert {:ok, %{folder?: false, entries: [%{state: :not_on_github}]}} =
               Sharing.status(max_age: 0)
    end

    test "errors come back as kinds" do
      stub_remote(%{}, fail: [repo: :not_found])
      assert {:error, {:not_found, _}} = Sharing.status(max_age: 0)
    end

    test "is cached, and the cached status follows local edits" do
      playbook = create!(playbook_text("bug-fix"))
      stub_remote(%{"bug-fix" => playbook_text("bug-fix")})

      Sharing.subscribe()
      assert {:ok, status} = Sharing.status(max_age: 0)
      assert_receive {:playbook_sharing, :status, _}
      assert entry(status, "playbooks/bug-fix.md").state == :up_to_date

      FakeRemote.put_file("playbooks/bug-fix.md", playbook_text("bug-fix", guidance: "New."))
      assert {:ok, cached} = Sharing.status(max_age: 600)
      assert entry(cached, "playbooks/bug-fix.md").state == :up_to_date

      {:ok, _} =
        Playbooks.update(Playbooks.get!(playbook.id), %{
          body: playbook_text("bug-fix", guidance: "Mine.")
        })

      assert {:ok, cached} = Sharing.cached_status()
      assert entry(cached, "playbooks/bug-fix.md").state == :edited
    end

    test "links a name pair with equal content" do
      playbook = create!(playbook_text("bug-fix"), %{source: "seed"})
      stub_remote(%{"bug-fix" => playbook_text("bug-fix")}, versions: %{"bug-fix" => 2})
      Playbooks.subscribe()

      assert {:ok, _} = Sharing.status(max_age: 0)
      assert_receive {:playbooks, :changed}

      linked = Playbooks.get!(playbook.id)
      assert linked.origin_repo == "acme/playbooks"
      assert linked.origin_path == "playbooks/bug-fix.md"
      assert linked.origin_version == 2
      assert linked.lock_version == playbook.lock_version

      {:ok, _} = Playbooks.update(linked, %{body: playbook_text("bug-fix", guidance: "Mine.")})
      assert entry(Sharing.cached_status() |> elem(1), "playbooks/bug-fix.md").state == :edited
    end

    test "the repo typed with other casing keeps the link" do
      playbook = create!(playbook_text("bug-fix"), %{source: "seed"})
      stub_remote(%{"bug-fix" => playbook_text("bug-fix")})
      {:ok, _} = Sharing.status(max_age: 0)

      {:ok, _} =
        Playbooks.update(Playbooks.get!(playbook.id), %{
          body: playbook_text("bug-fix", guidance: "Mine.")
        })

      configure_sharing(repo: "Acme/Playbooks")
      {:ok, status} = Sharing.status(max_age: 0)

      assert entry(status, "playbooks/bug-fix.md").state == :edited
      assert Playbooks.get!(playbook.id).origin_repo == "acme/playbooks"
    end

    test "a read is shared, and reset stops one in flight" do
      stub_remote(%{"triage" => playbook_text("triage")})
      FakeRemote.hold(:list)

      first = Task.async(fn -> Sharing.status(max_age: 0) end)
      second = Task.async(fn -> Sharing.status(max_age: 0) end)
      await_waiters(2)
      FakeRemote.release(:list)
      assert {:ok, _} = Task.await(first)
      assert {:ok, _} = Task.await(second)
      assert Enum.count(FakeRemote.calls(), &(&1 == :list)) == 1

      FakeRemote.hold(:list)
      waiting = Task.async(fn -> Sharing.status(max_age: 0) end)
      await_waiters(1)
      Canopy.Playbooks.Sharing.Refresher.reset()
      assert {:error, {:gh_failed, _}} = Task.await(waiting)
      FakeRemote.release()
    end

    test "a result read under old settings is dropped" do
      stub_remote(%{"triage" => playbook_text("triage")})
      FakeRemote.hold(:list)
      reading = Task.async(fn -> Sharing.status(max_age: 0) end)
      await_waiters(1)
      configure_sharing(folder: "elsewhere")
      FakeRemote.release()
      assert {:error, {:stale, "sharing settings changed"}} = Task.await(reading)
    end
  end

  describe "compare" do
    setup do
      configure_sharing()
      :ok
    end

    test "an update, with who changed it" do
      base = playbook_text("bug-fix")
      playbook = create!(base) |> link_playbook("playbooks/bug-fix.md", 2, base)

      stub_remote(%{"bug-fix" => playbook_text("bug-fix", steps: ~w(work review))},
        versions: %{"bug-fix" => 3}
      )

      {:ok, _} = Sharing.status(max_age: 0)

      assert {:ok, comparison} = Sharing.compare("playbooks/bug-fix.md")
      assert comparison.entry.state == :update
      assert comparison.local.version == playbook.version
      assert comparison.remote.version == 3
      assert comparison.remote.by == "mkoh"
      assert comparison.base_version == 2
      assert [%{kind: :added, by: :remote}] = comparison.changes
    end

    test "a new file has only GitHub's side" do
      stub_remote(%{"triage" => playbook_text("triage", guidance: "Rules.")})
      {:ok, _} = Sharing.status(max_age: 0)

      assert {:ok,
              %{
                local: nil,
                base_version: nil,
                changes: [],
                file_diff: diff,
                remote: %{definition: d}
              }} =
               Sharing.compare("playbooks/triage.md")

      assert d.name == "triage"
      assert is_binary(diff)
    end

    test "both changed carries the version last synced" do
      base = playbook_text("bug-fix")
      playbook = create!(base) |> link_playbook("playbooks/bug-fix.md", 5, base)
      {:ok, _} = Playbooks.update(playbook, %{body: playbook_text("bug-fix", guidance: "Mine.")})

      stub_remote(%{"bug-fix" => playbook_text("bug-fix", guidance: "Theirs.")},
        versions: %{"bug-fix" => 6}
      )

      {:ok, status} = Sharing.status(max_age: 0)
      assert %{state: :both_changed, base_version: 5} = entry(status, "playbooks/bug-fix.md")
      assert {:ok, %{base_version: 5}} = Sharing.compare("playbooks/bug-fix.md")
    end

    test "a file that doesn't parse is unreadable, with the parse error" do
      stub_remote(%{"broken" => "---\nname: broken\n---\n\nNo steps."})
      {:ok, status} = Sharing.status(max_age: 0)
      assert %{state: :unreadable, error: reason} = entry(status, "playbooks/broken.md")

      assert {:error, {:unreadable, ^reason}} = Sharing.compare("playbooks/broken.md")
      assert is_binary(reason) and reason != ""
    end

    test "an unknown key, or no status, is stale" do
      assert {:error, {:stale, _}} = Sharing.compare("playbooks/x.md")
      stub_remote(%{})
      {:ok, _} = Sharing.status(max_age: 0)
      assert {:error, {:stale, _}} = Sharing.compare("playbooks/x.md")
    end
  end

  describe "import" do
    setup do
      configure_sharing()
      :ok
    end

    test "a new file arrives enabled, linked, at GitHub's version; undo deletes it" do
      stub_remote(%{"triage" => playbook_text("triage")}, versions: %{"triage" => 4})
      {:ok, status} = Sharing.status(max_age: 0)
      Playbooks.subscribe()

      assert {:ok, %{playbooks: [playbook], undo: undo}} =
               Sharing.import([{entry(status, "playbooks/triage.md"), :take}])

      assert_receive {:playbooks, :changed}
      assert playbook.name == "triage"
      assert playbook.enabled
      assert playbook.version == 4
      assert playbook.origin_path == "playbooks/triage.md"
      refute playbook.body =~ "version:"
      assert entry(elem(Sharing.cached_status(), 1), "playbooks/triage.md").state == :up_to_date

      assert :ok = Sharing.undo_import(undo)
      refute Playbooks.get(playbook.id)
      assert {:error, {:stale, "undo expired"}} = Sharing.undo_import(undo)
    end

    test "a new file whose name is taken imports as import_as" do
      base = playbook_text("xx")
      create!(base) |> link_playbook("playbooks/other.md", 1, base)

      stub_remote(%{
        "playbooks/other.md" => base,
        "playbooks/xx-2.md" => playbook_text("xx-2"),
        "playbooks/xx.md" => playbook_text("xx", guidance: "Another.")
      })

      {:ok, status} = Sharing.status(max_age: 0)
      new = entry(status, "playbooks/xx.md")
      assert new.import_as == "xx-3"

      assert {:ok, %{playbooks: [%{name: "xx-3"} = copy]}} = Sharing.import([{new, :take}])
      assert copy.origin_path == "playbooks/xx.md"
    end

    test "replace mine takes GitHub's text and version; undo restores yours" do
      base = playbook_text("bug-fix")
      mine = playbook_text("bug-fix", guidance: "Mine.")
      playbook = create!(base) |> link_playbook("playbooks/bug-fix.md", 2, base)
      {:ok, playbook} = Playbooks.update(playbook, %{body: mine})

      stub_remote(%{"bug-fix" => playbook_text("bug-fix", guidance: "Theirs.")},
        versions: %{"bug-fix" => 3}
      )

      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "playbooks/bug-fix.md")
      assert e.state == :both_changed

      assert {:ok, %{playbooks: [replaced], undo: undo}} = Sharing.import([{e, :take}])
      assert replaced.body =~ "Theirs."
      assert replaced.version == 3
      assert replaced.origin_version == 3

      assert :ok = Sharing.undo_import(undo)
      restored = Playbooks.get!(playbook.id)
      assert restored.body == mine
      assert restored.version == playbook.version
      assert restored.origin_version == 2
    end

    test "replace mine on an agent's draft claims it for the user" do
      draft =
        create!(playbook_text("triage", guidance: "Draft."), %{source: "agent", enabled: false})

      stub_remote(%{"triage" => playbook_text("triage", guidance: "Theirs.")})

      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "playbooks/triage.md")
      assert e.playbook.id == draft.id

      assert {:ok, %{playbooks: [replaced]}} = Sharing.import([{e, :take}])
      assert replaced.id == draft.id
      assert replaced.source == "user"
      refute replaced.enabled
    end

    test "keep both creates a linked copy and unlinks yours" do
      playbook = create!(playbook_text("bug-fix", guidance: "Mine."))
      stub_remote(%{"bug-fix" => playbook_text("bug-fix", guidance: "Theirs.")})
      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "playbooks/bug-fix.md")
      assert e.state == :name_clash
      assert Sharing.copy_name("bug-fix") == "bug-fix-2"

      assert {:ok, %{playbooks: [copy]}} = Sharing.import([{e, :keep_both}])
      assert copy.name == "bug-fix-2"
      assert copy.origin_path == "playbooks/bug-fix.md"
      assert Playbooks.get!(playbook.id).origin_path == nil

      {:ok, status} = Sharing.status(max_age: 0)
      assert entry(status, "playbooks/bug-fix.md").playbook.id == copy.id
      assert entry(status, "local:" <> playbook.id).state == :name_taken
    end

    test "a local edit since the status was built is stale, and nothing is imported" do
      base = playbook_text("bug-fix")
      playbook = create!(base) |> link_playbook("playbooks/bug-fix.md", 1, base)

      stub_remote(%{
        "bug-fix" => playbook_text("bug-fix", guidance: "Theirs."),
        "triage" => playbook_text("triage")
      })

      {:ok, status} = Sharing.status(max_age: 0)
      {:ok, _} = Playbooks.update(playbook, %{body: playbook_text("bug-fix", guidance: "Mine.")})

      assert {:error, {:stale, _}} =
               Sharing.import([
                 {entry(status, "playbooks/triage.md"), :take},
                 {entry(status, "playbooks/bug-fix.md"), :take}
               ])

      refute Playbooks.get_by_name("triage")
    end

    test "a choice the state doesn't allow is stale" do
      stub_remote(%{"triage" => playbook_text("triage")})
      {:ok, status} = Sharing.status(max_age: 0)

      assert {:error, {:stale, _}} =
               Sharing.import([{entry(status, "playbooks/triage.md"), :keep_both}])
    end
  end

  describe "export" do
    setup do
      configure_sharing()
      :ok
    end

    test "opens a PR with the version line, records it, and the merge links it" do
      playbook = create!(playbook_text("triage"))
      stub_remote(%{})
      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "local:" <> playbook.id)
      assert %{state: :not_on_github, export_version: 1} = e

      assert {:ok, %{number: 1, url: url, branch: "canopy/playbooks-" <> _}} =
               Sharing.export([e], %{title: "Add triage", note: "Please look."})

      assert [%{title: "Add triage", base: "main", body: body, files: [file]}] =
               FakeRemote.opened_prs()

      assert body =~ "Please look."
      assert file.path == "playbooks/triage.md"
      assert file.content =~ "name: triage\nversion: 1\n"

      recorded = Playbooks.get!(playbook.id)
      assert recorded.pr_number == 1
      assert recorded.pr_url == url
      assert recorded.lock_version == playbook.lock_version
      assert entry(elem(Sharing.cached_status(), 1), "local:" <> playbook.id).state == :in_pr

      FakeRemote.merge_pr(1)
      {:ok, status} = Sharing.status(max_age: 0)
      merged = Playbooks.get!(playbook.id)
      assert merged.pr_number == nil
      assert merged.origin_path == "playbooks/triage.md"
      assert merged.origin_version == 1
      assert entry(status, "playbooks/triage.md").state == :up_to_date
    end

    test "opens the branch the dialog showed, if it is one of ours, and says which was used" do
      [a, b, c] = Enum.map(~w(aa bb cc), &create!(playbook_text(&1)))
      stub_remote(%{})
      {:ok, status} = Sharing.status(max_age: 0)
      export = &Sharing.export([entry(status, "local:" <> &1.id)], %{title: "t", branch: &2})

      assert {:ok, %{branch: "canopy/playbooks-0102-030405"}} =
               export.(a, "canopy/playbooks-0102-030405")

      # taken already: GitHub's copy gets -2, and the result says so
      assert {:ok, %{branch: "canopy/playbooks-0102-030405-2"}} =
               export.(b, "canopy/playbooks-0102-030405")

      assert {:ok, %{branch: "canopy/playbooks-" <> rest}} = export.(c, "main")
      assert rest =~ ~r/\A\d{4}-\d{6}\z/
    end

    test "never lowers GitHub's version, and writes to the paired file's path" do
      playbook = create!(playbook_text("bug-fix", guidance: "Mine."))

      stub_remote(%{"playbooks/bug-fix-v2.md" => playbook_text("bug-fix")},
        versions: %{"playbooks/bug-fix-v2.md" => 6}
      )

      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "playbooks/bug-fix-v2.md")
      assert %{state: :name_clash, export_version: 7} = e

      assert {:ok, _} = Sharing.export([e], %{title: "t", note: nil})

      assert [%{files: [%{path: "playbooks/bug-fix-v2.md", content: content}]}] =
               FakeRemote.opened_prs()

      assert content =~ "version: 7"
      assert Playbooks.get!(playbook.id).version == 7

      # the builder holding the old struct still moves past the PR's number
      {:ok, saved} =
        Playbooks.update(playbook, %{body: playbook_text("bug-fix", guidance: "Again.")})

      assert saved.version == 8
    end

    test "a change on GitHub since you looked is stale" do
      base = playbook_text("bug-fix")
      playbook = create!(base) |> link_playbook("playbooks/bug-fix.md", 1, base)
      {:ok, _} = Playbooks.update(playbook, %{body: playbook_text("bug-fix", guidance: "Mine.")})
      stub_remote(%{"bug-fix" => base})
      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "playbooks/bug-fix.md")
      assert e.state == :edited

      FakeRemote.put_file("playbooks/bug-fix.md", playbook_text("bug-fix", guidance: "Theirs."))

      assert {:error, {:stale, "bug-fix changed on GitHub since you looked"}} =
               Sharing.export([e], %{title: "t"})

      assert FakeRemote.opened_prs() == []
    end

    test "a local edit since you looked is stale" do
      playbook = create!(playbook_text("triage"))
      stub_remote(%{})
      {:ok, status} = Sharing.status(max_age: 0)

      {:ok, _} =
        Playbooks.update(playbook, %{body: playbook_text("triage", guidance: "Changed.")})

      assert {:error, {:stale, _}} =
               Sharing.export([entry(status, "local:" <> playbook.id)], %{title: "t"})
    end

    test "without push access it's read only; a failed PR is pr_failed and changes nothing" do
      playbook = create!(playbook_text("triage"))
      stub_remote(%{}, can_push?: false)
      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "local:" <> playbook.id)
      assert {:error, {:read_only, _}} = Sharing.export([e], %{title: "t"})

      FakeRemote.set_push(true)
      FakeRemote.fail(:open_pr, :gh_failed)
      assert {:error, {:pr_failed, _}} = Sharing.export([e], %{title: "t"})
      assert Playbooks.get!(playbook.id).pr_number == nil
    end

    test "a PR opened in another repo waits for that repo to come back" do
      playbook = create!(playbook_text("triage"))
      stub_remote(%{})
      {:ok, status} = Sharing.status(max_age: 0)
      {:ok, _} = Sharing.export([entry(status, "local:" <> playbook.id)], %{title: "t"})

      configure_sharing(repo: "acme/other")
      {:ok, _} = Sharing.status(max_age: 0)
      refute :pr in FakeRemote.calls()
      assert Playbooks.get!(playbook.id).pr_number == 1

      # the fake has one repo, so the merge waits until acme/playbooks is back
      configure_sharing(repo: "Acme/Playbooks")
      FakeRemote.merge_pr(1)
      {:ok, _} = Sharing.status(max_age: 0)
      merged = Playbooks.get!(playbook.id)
      assert merged.pr_number == nil
      assert merged.origin_path == "playbooks/triage.md"
    end

    test "a file past the 200 read is still checked before export overwrites it" do
      playbook = create!(playbook_text("zz"))

      others =
        Map.new(1..200, fn n ->
          name = "aa#{String.pad_leading("#{n}", 3, "0")}"
          {name, playbook_text(name)}
        end)

      stub_remote(others)
      {:ok, status} = Sharing.status(max_age: 0)
      e = entry(status, "local:" <> playbook.id)
      assert e.state == :not_on_github

      FakeRemote.put_file("playbooks/zz.md", playbook_text("zz", guidance: "Theirs."))

      assert {:error, {:stale, "zz changed on GitHub since you looked"}} =
               Sharing.export([e], %{title: "t"})
    end

    test "a closed PR is forgotten" do
      playbook = create!(playbook_text("triage"))
      stub_remote(%{})
      {:ok, status} = Sharing.status(max_age: 0)
      {:ok, _} = Sharing.export([entry(status, "local:" <> playbook.id)], %{title: "t"})

      FakeRemote.close_pr(1)
      {:ok, status} = Sharing.status(max_age: 0)
      assert Playbooks.get!(playbook.id).pr_number == nil
      assert entry(status, "local:" <> playbook.id).state == :not_on_github
    end
  end

  test "branch_name" do
    assert "canopy/playbooks-" <> rest = Sharing.branch_name(~U[2026-11-02 22:14:07Z])
    assert rest =~ ~r/\A\d{4}-\d{4}07\z/
    assert Canopy.GitHub.valid_ref?("canopy/playbooks-" <> rest)
  end

  test "version: in a body is dropped on save, and only content changes bump" do
    {:ok, playbook} = Playbooks.create(%{body: Text.put_version(playbook_text("aa"), 9)})
    assert playbook.version == 1
    refute playbook.body =~ "version:"

    {:ok, same} = Playbooks.update(playbook, %{body: playbook.body <> "\n\n"})
    assert same.version == 1

    {:ok, changed} = Playbooks.update(same, %{body: playbook_text("aa", guidance: "New.")})
    assert changed.version == 2

    {:ok, toggled} = Playbooks.set_enabled(changed, false)
    assert toggled.version == 2
  end
end
