defmodule CanopyWeb.PlaybookSharingTest do
  use ExUnit.Case, async: true

  alias CanopyWeb.PlaybookSharing

  defp entry(state, attrs \\ []) do
    name = Keyword.get(attrs, :name, Atom.to_string(state) |> String.replace("_", "-"))

    Map.merge(
      %{
        key: "playbooks/#{name}.md",
        name: name,
        description: nil,
        state: state,
        playbook: %{enabled: true},
        local_version: nil,
        remote_version: nil,
        base_version: nil,
        export_version: nil,
        path: "playbooks/#{name}.md",
        sha: nil,
        pr: nil,
        import_as: nil,
        error: nil
      },
      Map.new(attrs)
    )
  end

  @all [
    :new,
    :not_on_github,
    :update,
    :edited,
    :both_changed,
    :name_clash,
    :name_taken,
    :in_pr,
    :up_to_date,
    :unreadable
  ]

  defp states(list), do: Enum.map(list, & &1.state)

  describe "import_groups/1" do
    test "puts every state in its section, and leaves out what Import doesn't list" do
      groups = @all |> Enum.map(&entry(&1, export_version: 2)) |> PlaybookSharing.import_groups()

      assert states(groups.ready) == [:new, :update]
      assert states(groups.look) == [:both_changed, :name_clash]
      assert states(groups.cant) == [:unreadable]
      assert states(groups.up_to_date) == [:edited, :in_pr, :up_to_date]
    end
  end

  describe "export_groups/1" do
    test "puts every state in its section: edited, then not on GitHub, then both-changed" do
      groups =
        [:both_changed | @all]
        |> Enum.uniq()
        |> Enum.map(&entry(&1, export_version: 2))
        |> PlaybookSharing.export_groups()

      assert states(groups.changed) == [:edited, :not_on_github, :both_changed, :name_clash]
      assert states(groups.cant) == [:update, :name_taken]
      assert states(groups.up_to_date) == [:in_pr, :up_to_date]
    end

    test "keeps name order within each kind" do
      groups =
        [
          entry(:not_on_github, name: "a-new", export_version: 1),
          entry(:name_clash, name: "b-clash", export_version: 2),
          entry(:edited, name: "c-edited", export_version: 3),
          entry(:not_on_github, name: "d-new", export_version: 1),
          entry(:edited, name: "e-edited", export_version: 3)
        ]
        |> PlaybookSharing.export_groups()

      assert Enum.map(groups.changed, & &1.name) ==
               ["c-edited", "e-edited", "a-new", "d-new", "b-clash"]
    end

    test "an exportable state without an export_version can't be exported" do
      too_long =
        entry(:edited, export_version: nil, error: "too long for GitHub's copy by 12 bytes")

      groups = PlaybookSharing.export_groups([too_long])

      assert groups.changed == []
      assert [%{error: "too long" <> _}] = groups.cant
    end

    test "drops disabled playbooks" do
      draft = entry(:not_on_github, export_version: 1, playbook: %{enabled: false})
      assert PlaybookSharing.export_groups([draft]) == %{changed: [], cant: [], up_to_date: []}
    end
  end

  describe "export_error/1" do
    test "says how far over the limit, with thousands separated" do
      assert PlaybookSharing.export_error({:too_long, 5311}) == "5,311 bytes over the limit."
      assert PlaybookSharing.export_error({:too_long, 12}) == "12 bytes over the limit."

      assert PlaybookSharing.export_error({:too_long, 1_000_042}) ==
               "1,000,042 bytes over the limit."
    end
  end

  describe "default_ticks/2" do
    test "Import ticks new and update rows" do
      entries = Enum.map(@all, &entry(&1, export_version: 2))

      assert PlaybookSharing.default_ticks(entries, :import) ==
               MapSet.new(["playbooks/new.md", "playbooks/update.md"])
    end

    test "Export ticks only edited rows that can be exported" do
      entries = [
        entry(:edited, name: "a", export_version: 3),
        entry(:edited, name: "b", export_version: nil, error: "too long"),
        entry(:not_on_github, name: "c", export_version: 1),
        entry(:both_changed, name: "d", export_version: 7),
        entry(:edited, name: "e", export_version: 2, playbook: %{enabled: false})
      ]

      assert PlaybookSharing.default_ticks(entries, :export) == MapSet.new(["playbooks/a.md"])
    end

    test "a first export, with only playbooks not on GitHub, ticks nothing" do
      entries = [
        entry(:not_on_github, name: "bug-fix", export_version: 1),
        entry(:not_on_github, name: "feature-build", export_version: 1)
      ]

      assert PlaybookSharing.default_ticks(entries, :export) == MapSet.new()
    end
  end

  describe "tickable?/2" do
    test "Import: Ready and Needs-a-look rows; Export: Changed in Canopy rows" do
      assert PlaybookSharing.tickable?(entry(:new), :import)
      assert PlaybookSharing.tickable?(entry(:name_clash), :import)
      refute PlaybookSharing.tickable?(entry(:unreadable), :import)

      assert PlaybookSharing.tickable?(entry(:not_on_github, export_version: 1), :export)
      refute PlaybookSharing.tickable?(entry(:edited, export_version: nil), :export)
      refute PlaybookSharing.tickable?(entry(:update, export_version: 2), :export)
    end
  end

  describe "update_count/1" do
    test "counts update, both-changed and name-clash, not new or in-PR" do
      entries = Enum.map(@all, &entry(&1, pr: %{number: 3, url: "u"}))

      assert PlaybookSharing.update_count(%{entries: entries}) == 3
      assert PlaybookSharing.update_count(nil) == 0
    end
  end

  describe "pr_title/1" do
    test "no ticks is empty" do
      assert PlaybookSharing.pr_title([]) == ""
    end

    test "one update, one add, and a mix, with the export versions" do
      update = entry(:edited, name: "feature-build", export_version: 7)
      add = entry(:not_on_github, name: "site-docs-refresh", export_version: 1)

      assert PlaybookSharing.pr_title([update]) == "Update feature-build (v7)"
      assert PlaybookSharing.pr_title([add]) == "Add site-docs-refresh (v1)"

      assert PlaybookSharing.pr_title([update, add]) ==
               "Update feature-build (v7), add site-docs-refresh (v1)"
    end

    test "more than three is a count" do
      many = for n <- 1..5, do: entry(:edited, name: "p-#{n}", export_version: 2)
      adds = for n <- 1..4, do: entry(:not_on_github, name: "a-#{n}", export_version: 1)

      assert PlaybookSharing.pr_title(many) == "Update 5 playbooks"
      assert PlaybookSharing.pr_title(adds) == "Add 4 playbooks"
    end
  end

  describe "chip/1" do
    test "labels and classes for the four states that have one" do
      assert %{label: "⤓ Update · v3 → v4", class: "badge-secondary badge-soft"} =
               PlaybookSharing.chip(entry(:update, local_version: 3, remote_version: 4))

      assert %{label: "⚠ Both changed", class: "badge-warning badge-soft"} =
               PlaybookSharing.chip(entry(:both_changed))

      assert %{label: "⚠ Same name, different"} = PlaybookSharing.chip(entry(:name_clash))

      assert %{label: "In PR #14", class: "badge-ghost"} =
               PlaybookSharing.chip(entry(:in_pr, pr: %{number: 14, url: "u"}))
    end

    test "no chip for the states Export lists" do
      for state <- [:edited, :not_on_github, :name_taken, :up_to_date],
          do: assert(PlaybookSharing.chip(entry(state)) == nil)
    end
  end

  describe "error_copy/2" do
    test "every kind has a tone, a lead and a next step" do
      for kind <- [
            :gh_missing,
            :gh_signed_out,
            :gh_too_old,
            :not_found,
            :read_only,
            :empty_folder,
            :unreadable,
            :pr_failed,
            :stale,
            :gh_failed
          ] do
        assert {tone, lead, next} = PlaybookSharing.error_copy(kind, %{repo: "o/r"})
        assert tone in [:error, :warning, :info]
        assert lead != "" and next != ""
      end

      assert PlaybookSharing.error_copy(:not_set_up, %{}) == nil
    end

    test ":not_found names the repo, and the account only when one is known" do
      {:error, lead, next} = PlaybookSharing.error_copy(:not_found, %{repo: "acme/playbooks"})
      assert lead == "Can't see acme/playbooks"
      assert next =~ "your gh account"

      {:error, _, next} =
        PlaybookSharing.error_copy(:not_found, %{repo: "acme/playbooks", account: "sbarber"})

      assert next =~ "give sbarber access"
    end

    test "the empty folder names the folder and branch" do
      assert {:info, "playbooks/ is empty on main", _} =
               PlaybookSharing.error_copy(:empty_folder, %{folder: "playbooks", branch: "main"})

      assert {:info, _, "Nothing to import yet." <> _} =
               PlaybookSharing.error_copy(:empty_folder, %{folder: "playbooks"})

      assert {:info, _, "Nothing on GitHub yet. Tick the playbooks to share;" <> _} =
               PlaybookSharing.error_copy(:empty_folder, %{folder: "playbooks", mode: :export})
    end

    test "gh's errors name the button that checks again" do
      {:error, _, next} = PlaybookSharing.error_copy(:gh_signed_out, %{})
      assert next == "Run `gh auth login` in a terminal, then Check again."

      {:error, _, next} = PlaybookSharing.error_copy(:gh_too_old, %{check: "Check connection"})
      assert next == "Update it with `brew upgrade gh`, then Check connection."
    end
  end

  test "repo_url/2 links the folder on the branch once it's known" do
    config = %{repo: "acme/playbooks", branch: nil, folder: "playbooks"}

    assert PlaybookSharing.repo_url(config, nil) == "https://github.com/acme/playbooks"

    assert PlaybookSharing.repo_url(config, "main") ==
             "https://github.com/acme/playbooks/tree/main/playbooks"

    assert PlaybookSharing.repo_url(%{config | folder: ""}, "dev") ==
             "https://github.com/acme/playbooks/tree/dev"
  end

  test "version_line/2 with and without an origin" do
    assert PlaybookSharing.version_line(%{version: 3, origin_repo: nil}, false) == "v3"

    linked = %{version: 7, origin_repo: "tiki51/canopy-playbooks", origin_version: 5}

    assert PlaybookSharing.version_line(linked, true) ==
             "v7 · from tiki51/canopy-playbooks (v5) · edited since"

    assert PlaybookSharing.version_line(linked, false) == "v7 · from tiki51/canopy-playbooks (v5)"
  end
end
