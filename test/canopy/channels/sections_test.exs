defmodule Canopy.Channels.SectionsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Channels, Repositories}
  alias Canopy.Channels.{Channel, Section, Sections}

  setup do
    repository = repository_fixture()
    %{repository: repository}
  end

  defp names(repository_id), do: repository_id |> Sections.list() |> Enum.map(& &1.name)

  defp positions(repository_id), do: repository_id |> Sections.list() |> Enum.map(& &1.position)

  describe "create/2" do
    test "puts a new section first and shifts the rest", %{repository: repo} do
      Channels.subscribe()

      assert {:ok, %Section{name: "Releases", position: 0}} =
               Sections.create(repo.id, " Releases ")

      assert_receive {:channels, :changed}
      assert {:ok, _} = Sections.create(repo.id, "Bugs")
      assert names(repo.id) == ["Bugs", "Releases"]
      assert positions(repo.id) == [0, 1]
    end

    test "rejects blank, too long, multi-line and duplicate (any case) names", %{repository: repo} do
      assert {:error, cs} = Sections.create(repo.id, "  ")
      assert %{name: ["can't be blank"]} = errors_on(cs)

      assert {:error, cs} = Sections.create(repo.id, String.duplicate("x", 41))
      assert %{name: ["should be at most 40 character(s)"]} = errors_on(cs)

      assert {:error, cs} = Sections.create(repo.id, "two\nlines")
      assert %{name: ["must be on one line"]} = errors_on(cs)

      {:ok, _} = Sections.create(repo.id, "Releases")
      assert {:error, cs} = Sections.create(repo.id, "releases")
      assert Sections.error_message(cs) == "Name is already a section in this project"
      # the failed insert rolled back its shift
      assert positions(repo.id) == [0]

      other = repository_fixture()
      assert {:ok, _} = Sections.create(other.id, "Releases")
    end

    test "an unknown repository is an error, not a crash" do
      assert {:error, cs} = Sections.create("repo_missing", "Releases")
      assert %{repository_id: ["does not exist"]} = errors_on(cs)
    end
  end

  describe "find_or_create/2" do
    test "matches in any case without inserting or broadcasting", %{repository: repo} do
      {:ok, existing} = Sections.create(repo.id, "Releases")
      Channels.subscribe()

      assert {:ok, %Section{id: id, created?: false}} =
               Sections.find_or_create(repo.id, " RELEASES ")

      assert id == existing.id
      assert names(repo.id) == ["Releases"]
      refute_receive {:channels, :changed}
    end

    test "a new name is appended last and marked created", %{repository: repo} do
      {:ok, _} = Sections.create(repo.id, "A")
      {:ok, _} = Sections.create(repo.id, "B")

      assert {:ok, %Section{name: "Zed", position: 2, created?: true}} =
               Sections.find_or_create(repo.id, "Zed")

      assert names(repo.id) == ["B", "A", "Zed"]
    end

    test "an invalid name is an error on :name", %{repository: repo} do
      assert {:error, cs} = Sections.find_or_create(repo.id, String.duplicate("x", 41))
      assert %{name: ["should be at most 40 character(s)"]} = errors_on(cs)
      assert Sections.list(repo.id) == []
    end
  end

  test "find_by_name/2 trims and ignores case", %{repository: repo} do
    {:ok, section} = Sections.create(repo.id, "Releases")
    assert Sections.find_by_name(repo.id, "  releases ").id == section.id
    assert Sections.find_by_name(repo.id, "") == nil
    assert Sections.find_by_name(repo.id, "Other") == nil
  end

  test "validate_name/1 checks without writing" do
    assert Sections.validate_name("Releases") == :ok
    assert Sections.validate_name("  ") == :ok
    assert Sections.validate_name(nil) == :ok

    assert Sections.validate_name(String.duplicate("x", 41)) ==
             {:error, "should be at most 40 character(s)"}
  end

  test "rename/2 keeps names unique in any case", %{repository: repo} do
    {:ok, a} = Sections.create(repo.id, "A")
    {:ok, _} = Sections.create(repo.id, "B")
    assert {:ok, %Section{name: "Alpha"}} = Sections.rename(a, " Alpha ")
    assert {:error, cs} = Sections.rename(a, "b")
    assert %{name: ["is already a section in this project"]} = errors_on(cs)
    # a change of case alone is fine
    assert {:ok, %Section{name: "ALPHA"}} = Sections.rename(Sections.get(a.id), "ALPHA")
  end

  test "move/2 takes a final index, clamps it and keeps positions contiguous", %{repository: repo} do
    {:ok, c} = Sections.create(repo.id, "C")
    {:ok, _b} = Sections.create(repo.id, "B")
    {:ok, a} = Sections.create(repo.id, "A")
    assert names(repo.id) == ["A", "B", "C"]

    assert {:ok, sections} = Sections.move(a, 2)
    assert Enum.map(sections, & &1.name) == ["B", "C", "A"]
    assert {:ok, _} = Sections.move(Sections.get(c.id), -5)
    assert names(repo.id) == ["C", "B", "A"]
    assert {:ok, _} = Sections.move(Sections.get(c.id), 99)
    assert names(repo.id) == ["B", "A", "C"]
    assert positions(repo.id) == [0, 1, 2]
  end

  test "delete/1 sends its channels to the top, archives nothing, renumbers", %{repository: repo} do
    {:ok, keep} = Sections.create(repo.id, "Keep")
    {:ok, gone} = Sections.create(repo.id, "Gone")
    open = channel_fixture(%{repository_id: repo.id, section_id: gone.id})
    archived = channel_fixture(%{repository_id: repo.id, section_id: gone.id})
    {:ok, _} = Channels.archive(archived)

    assert {:ok, _} = Sections.delete(gone)
    assert Repo.get!(Channel, open.id).section_id == nil
    assert %Channel{section_id: nil, status: "archived"} = Repo.get!(Channel, archived.id)
    assert [%Section{id: id, position: 0}] = Sections.list(repo.id)
    assert id == keep.id
  end

  test "a raw delete nilifies channels through the foreign key", %{repository: repo} do
    {:ok, section} = Sections.create(repo.id, "Raw")
    channel = channel_fixture(%{repository_id: repo.id, section_id: section.id})
    Repo.query!("DELETE FROM channel_sections WHERE id = ?1", [section.id])
    assert Repo.get!(Channel, channel.id).section_id == nil
  end

  test "set_collapsed/2 sets an explicit state", %{repository: repo} do
    {:ok, section} = Sections.create(repo.id, "S")
    assert {:ok, %Section{collapsed: true}} = Sections.set_collapsed(section, true)

    assert {:ok, %Section{collapsed: true}} =
             Sections.set_collapsed(Sections.get(section.id), true)

    assert {:ok, %Section{collapsed: false}} = Sections.set_collapsed(section, false)
  end

  describe "move_channel/2" do
    test "files a channel and takes it back to the top", %{repository: repo} do
      {:ok, section} = Sections.create(repo.id, "S")
      channel = channel_fixture(%{repository_id: repo.id})
      Channels.subscribe()

      assert {:ok, %Channel{section_id: id}} = Sections.move_channel(channel, section)
      assert id == section.id
      assert_receive {:channels, :changed}
      assert {:ok, %Channel{section_id: nil}} = Sections.move_channel(channel, nil)
    end

    test "refuses DMs and sections of another project", %{repository: repo} do
      {:ok, section} = Sections.create(repo.id, "S")
      other = repository_fixture()
      foreign = channel_fixture(%{repository_id: other.id})
      assert Sections.move_channel(foreign, section) == {:error, :other_repository}

      {:ok, dm} = Channels.ensure_dm(repo.id, agent_fixture())
      assert Sections.move_channel(dm, section) == {:error, :dm}
    end
  end

  test "every write broadcasts {:channels, :changed}", %{repository: repo} do
    Channels.subscribe()
    {:ok, s} = Sections.create(repo.id, "S")
    assert_receive {:channels, :changed}
    {:ok, s} = Sections.rename(s, "T")
    assert_receive {:channels, :changed}
    {:ok, _} = Sections.move(s, 0)
    assert_receive {:channels, :changed}
    {:ok, s} = Sections.set_collapsed(s, true)
    assert_receive {:channels, :changed}
    {:ok, _} = Sections.delete(s)
    assert_receive {:channels, :changed}
  end

  describe "group/2" do
    test "buckets open channels A→Z, keeps empty sections, archives apart", %{repository: repo} do
      {:ok, later} = Sections.create(repo.id, "Later")
      {:ok, now} = Sections.create(repo.id, "Now")
      _b = channel_fixture(%{repository_id: repo.id, name: "bravo"})
      _a = channel_fixture(%{repository_id: repo.id, name: "alpha"})
      _z = channel_fixture(%{repository_id: repo.id, name: "zulu", section_id: now.id})
      _y = channel_fixture(%{repository_id: repo.id, name: "yankee", section_id: now.id})
      old = channel_fixture(%{repository_id: repo.id, name: "old", section_id: now.id})
      {:ok, _} = Channels.archive(old)

      repository = Enum.find(Repositories.list_with_channels(), &(&1.id == repo.id))
      group = Sections.group(repository, nil)

      assert Enum.map(group.top, & &1.name) == ["alpha", "bravo"]

      assert [
               %{section: %{id: now_id}, channels: now_channels},
               %{section: %{id: later_id}, channels: []}
             ] =
               group.sections

      assert {now_id, later_id} == {now.id, later.id}
      assert Enum.map(now_channels, & &1.name) == ["yankee", "zulu"]
      assert Enum.map(group.archived, & &1.name) == ["old"]

      # the open channel, though archived, stays in its section
      group = Sections.group(repository, old.id)
      assert group.archived == []

      assert ["old", "yankee", "zulu"] ==
               group.sections |> hd() |> Map.get(:channels) |> Enum.map(& &1.name)
    end

    test "a section_id with no loaded section counts as top", %{repository: repo} do
      {:ok, section} = Sections.create(repo.id, "S")
      channel = channel_fixture(%{repository_id: repo.id, section_id: section.id})
      repository = Enum.find(Repositories.list_with_channels(), &(&1.id == repo.id))
      group = Sections.group(%{repository | sections: []}, nil)
      assert Enum.map(group.top, & &1.id) == [channel.id]
    end
  end

  test "list_with_channels/0 carries each repository's sections by position", %{repository: repo} do
    {:ok, _} = Sections.create(repo.id, "B")
    {:ok, _} = Sections.create(repo.id, "A")
    repository = Enum.find(Repositories.list_with_channels(), &(&1.id == repo.id))
    assert Enum.map(repository.sections, & &1.name) == ["A", "B"]
  end
end
