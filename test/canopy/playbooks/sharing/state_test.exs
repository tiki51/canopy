defmodule Canopy.Playbooks.Sharing.StateTest do
  use ExUnit.Case, async: true

  import Canopy.PlaybookSharingHelpers, only: [playbook_text: 1, playbook_text: 2]

  alias Canopy.Playbooks.Playbook
  alias Canopy.Playbooks.Sharing.{FakeRemote, State, Text}

  @config %{repo: "acme/playbooks", branch: nil, folder: "playbooks"}

  defp file(path, text) do
    State.prepare_file(
      %{path: path, sha: FakeRemote.blob_sha(text), size: byte_size(text)},
      {:ok, text}
    )
  end

  defp local(name, body, attrs \\ %{}) do
    struct!(
      %Playbook{
        id: "pb_" <> name,
        name: name,
        description: "Does #{name}.",
        body: body,
        enabled: true,
        version: 1,
        lock_version: 1
      },
      attrs
    )
  end

  defp linked(name, body, base, attrs \\ %{}) do
    local(
      name,
      body,
      Map.merge(
        %{
          origin_repo: "acme/playbooks",
          origin_path: "playbooks/#{name}.md",
          origin_version: 2,
          origin_sha: Text.content_hash(base),
          origin_body: base
        },
        attrs
      )
    )
  end

  defp build(files, locals), do: State.build(%{config: @config, files: files}, locals)

  defp entry(result, key), do: Enum.find(result.entries, &(&1.key == key))

  @base playbook_text("bug-fix")
  @mine playbook_text("bug-fix", guidance: "Mine.")
  @theirs playbook_text("bug-fix", guidance: "Theirs.")

  describe "states of a linked pair" do
    test "up to date, update, edited, both changed" do
      path = "playbooks/bug-fix.md"

      for {local_body, remote_body, state} <- [
            {@base, @base, :up_to_date},
            {@base, @theirs, :update},
            {@mine, @base, :edited},
            {@mine, @theirs, :both_changed}
          ] do
        result =
          build([file(path, Text.put_version(remote_body, 3))], [
            linked("bug-fix", local_body, @base)
          ])

        e = entry(result, path)
        assert e.state == state, "expected #{state}, got #{e.state}"
        assert e.remote_version == 3
        assert e.base_version == 2
        assert result.links == []
      end
    end

    test "in a PR while the text is the exported one" do
      playbook =
        linked("bug-fix", @mine, @base, %{
          pr_number: 14,
          pr_url: "u",
          pr_sha: Text.content_hash(@mine)
        })

      e = entry(build([file("playbooks/bug-fix.md", @base)], [playbook]), "playbooks/bug-fix.md")
      assert e.state == :in_pr
      assert e.pr == %{number: 14, url: "u"}
    end
  end

  describe "name pairs" do
    test "different content is a name clash; equal content is linked" do
      clash = build([file("playbooks/bug-fix.md", @theirs)], [local("bug-fix", @mine)])
      assert entry(clash, "playbooks/bug-fix.md").state == :name_clash
      assert entry(clash, "playbooks/bug-fix.md").base_version == nil
      assert clash.links == []

      equal = build([file("playbooks/bug-fix.md", @mine)], [local("bug-fix", @mine)])
      assert entry(equal, "playbooks/bug-fix.md").state == :up_to_date
      assert [{%Playbook{name: "bug-fix"}, %{path: "playbooks/bug-fix.md"}}] = equal.links
    end

    test "pairs by frontmatter name, whatever the file is called" do
      result = build([file("playbooks/bug-fix-v2.md", @theirs)], [local("bug-fix", @mine)])
      e = entry(result, "playbooks/bug-fix-v2.md")
      assert e.state == :name_clash
      assert e.path == "playbooks/bug-fix-v2.md"
    end

    test "a foreign origin counts as none" do
      playbook = linked("bug-fix", @mine, @base, %{origin_repo: "other/repo"})
      result = build([file("playbooks/bug-fix.md", @theirs)], [playbook])
      assert entry(result, "playbooks/bug-fix.md").state == :name_clash
    end
  end

  describe "new files" do
    test "a free name imports as itself; a taken one as a copy" do
      # `bug-fix` is linked to another file, so a second file with its name is new
      playbook = linked("bug-fix", @base, @base, %{origin_path: "playbooks/a.md"})

      result =
        build(
          [
            file("playbooks/a.md", @base),
            file("playbooks/b.md", @theirs),
            file("playbooks/c.md", playbook_text("triage"))
          ],
          [playbook]
        )

      assert entry(result, "playbooks/b.md").state == :new
      assert entry(result, "playbooks/b.md").import_as == "bug-fix-2"
      assert entry(result, "playbooks/c.md").import_as == nil
    end

    test "copy names skip names claimed in the same status" do
      playbook =
        linked("xx", playbook_text("xx"), playbook_text("xx"), %{
          origin_path: "playbooks/other.md"
        })

      result =
        build(
          [
            file("playbooks/other.md", playbook_text("xx")),
            file("playbooks/xx-2.md", playbook_text("xx-2")),
            file("playbooks/xx.md", playbook_text("xx", guidance: "One.")),
            file("playbooks/yy.md", playbook_text("xx", guidance: "Two."))
          ],
          [playbook]
        )

      assert entry(result, "playbooks/xx-2.md").import_as == nil
      assert entry(result, "playbooks/xx.md").import_as == "xx-3"
      assert entry(result, "playbooks/yy.md").import_as == "xx-4"
    end

    test "unreadable files say why" do
      bad =
        State.prepare_file(
          %{path: "playbooks/bad.md", sha: FakeRemote.blob_sha("x"), size: 1},
          {:ok, "nope"}
        )

      big =
        State.prepare_file(
          %{path: "playbooks/big.md", sha: FakeRemote.blob_sha("y"), size: 60_000},
          :skip
        )

      odd =
        State.prepare_file(
          %{path: "playbooks/a b.md", sha: FakeRemote.blob_sha("z"), size: 1},
          :skip
        )

      bad_version =
        file(
          "playbooks/v.md",
          String.replace(playbook_text("vv"), "name: vv\n", "name: vv\nversion: two\n")
        )

      result = build([bad, big, odd, bad_version], [])
      assert Enum.all?(result.entries, &(&1.state == :unreadable and is_binary(&1.error)))
      assert entry(result, "playbooks/big.md").error =~ "48 KB"
      assert entry(result, "playbooks/v.md").error =~ "version must be a whole number"
    end
  end

  describe "local playbooks" do
    test "not on GitHub, name taken, drafts left out" do
      result =
        build(
          [file("playbooks/taken.md", playbook_text("someone-else"))],
          [
            local("fresh", playbook_text("fresh")),
            local("taken", playbook_text("taken")),
            local("draft", playbook_text("draft"), %{enabled: false})
          ]
        )

      assert entry(result, "local:pb_fresh").state == :not_on_github
      assert entry(result, "local:pb_fresh").export_version == 1
      assert entry(result, "local:pb_taken").state == :name_taken
      assert entry(result, "local:pb_taken").export_version == nil
      refute entry(result, "local:pb_draft")
    end
  end

  describe "export_version" do
    test "never below GitHub's, and a file without version: counts as 0" do
      newer = linked("bug-fix", @mine, @base, %{version: 5})

      e =
        entry(
          build([file("playbooks/bug-fix.md", Text.put_version(@theirs, 6))], [newer]),
          "playbooks/bug-fix.md"
        )

      assert e.state == :both_changed
      assert e.export_version == 7

      e = entry(build([file("playbooks/bug-fix.md", @base)], [newer]), "playbooks/bug-fix.md")
      assert e.state == :edited
      assert e.remote_version == nil
      assert e.export_version == 5

      clash = local("bug-fix", @mine, %{version: 1})

      e =
        entry(
          build([file("playbooks/bug-fix.md", Text.put_version(@theirs, 6))], [clash]),
          "playbooks/bug-fix.md"
        )

      assert e.export_version == 7
    end

    test "a body too long for GitHub's name has no export_version" do
      pad = 39_995 - byte_size(playbook_text("ab", guidance: ""))
      body = playbook_text("ab", guidance: String.duplicate("x", pad))
      assert byte_size(body) == 39_995

      # paired by origin, so the export keeps GitHub's longer name (+24 bytes)
      remote =
        playbook_text("ab", guidance: "short") |> Text.put_name("a-much-longer-name-than-ab")

      playbook = linked("ab", body, remote, %{origin_path: "playbooks/ab.md"})
      e = entry(build([file("playbooks/ab.md", remote)], [playbook]), "playbooks/ab.md")

      assert e.state == :edited
      assert e.export_version == nil
      assert e.error == {:too_long, 19}
    end
  end

  test "copy_name keeps within 40 characters" do
    name = String.duplicate("a", 40)
    copy = State.copy_name(name, MapSet.new())
    assert String.length(copy) == 40
    assert String.ends_with?(copy, "-2")
  end
end
