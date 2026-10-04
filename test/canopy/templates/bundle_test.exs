defmodule Canopy.Templates.BundleTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Agents, Playbooks, Teams, Templates}
  alias Canopy.Fixtures
  alias Canopy.Templates.{Bundle, Import, Machine}
  alias Canopy.Templates.Import.Plan

  defp machine,
    do: %Machine{claude_code: true, opencode: {:ok, []}, opencode_agents: ~w(build plan)}

  defp zip(entries) do
    entries = Enum.map(entries, fn {path, data} -> {String.to_charlist(path), data} end)
    {:ok, {_, bin}} = :zip.create(~c"t.zip", entries, [:memory])
    bin
  end

  defp agent_file(name, body \\ "Prompt."),
    do: "---\ncanopy_template: 1\nkind: agent\nname: #{name}\nmode: build\n---\n#{body}\n"

  defp team_file(name, lead, members) do
    """
    ---
    canopy_template: 1
    kind: team
    name: #{name}
    lead: #{lead}
    members:
    #{Enum.map_join(members, "\n", &"  - name: #{&1}")}
    ---
    """
  end

  defp put_size(bin, at) do
    <<before::binary-size(^at), _::binary-size(4), rest::binary>> = bin
    before <> <<100::little-32>> <> rest
  end

  defp plan_zip(bin), do: Import.plan([{:file, "b.canopy.zip", bin}], machine: machine())

  defp named(plan, name), do: Enum.find(plan.items, &(&1.name == name))

  describe "reading" do
    test "a zip round-trips through export and read" do
      a = Fixtures.agent_fixture(%{name: "zip-a"})
      b = Fixtures.agent_fixture(%{name: "zip-b", engine: "claude_code"})
      {filename, bin} = Templates.export_agents([a, b])
      assert filename == "canopy-agents.zip"

      assert {:ok, %{manifest: %{"kind" => "bundle"}, files: files, notices: []}} =
               Bundle.read(bin)

      assert Enum.map(files, &elem(&1, 0)) == ["agents/zip-a.md", "agents/zip-b.md"]

      # read back on the same machine, nothing differs
      plan = plan_zip(bin)
      assert Enum.map(plan.items, & &1.status) == [:identical, :identical]
    end

    test "entries with .. or an absolute path refuse the bundle" do
      # `:zip.create` tidies names, so the bad ones are patched in afterwards
      for path <- ["../x.md", "agents/../../x.md", "/etc/x.md", "C:/x.md"] do
        stand_in = String.duplicate("q", String.length(path) - 5) <> "/x.md"
        bin = zip([{stand_in, agent_file("x")}]) |> :binary.replace(stand_in, path, [:global])
        assert {:error, [reason]} = Bundle.read(bin)
        assert reason =~ "unsafe entry path"
      end
    end

    test "too many entries, or too much once unpacked, refuse the bundle" do
      many = for n <- 1..(Bundle.max_entries() + 1), do: {"agents/a#{n}.md", agent_file("a#{n}")}
      assert {:error, [reason]} = Bundle.read(zip(many))
      assert reason =~ "too many entries"

      # zeros compress well: small zip, big contents
      huge = [{"agents/big.md", :binary.copy(<<0>>, Bundle.max_total_bytes() + 1)}]
      bin = zip(huge)
      assert byte_size(bin) < Bundle.max_zip_bytes()
      assert {:error, [reason]} = Bundle.read(bin)
      assert reason =~ "unpacks to more than"

      # a directory that understates the size still stops at the cap
      {central, _} = :binary.match(bin, <<0x50, 0x4B, 0x01, 0x02>>)
      lying = bin |> put_size(22) |> put_size(central + 24)
      assert {:error, [reason]} = Bundle.read(lying)
      assert reason =~ "too large" or reason =~ "unpacks to more than"

      big_file = [{"agents/big.md", agent_file("big", String.duplicate("x", 300_000))}]
      assert {:error, [reason]} = Bundle.read(zip(big_file))
      assert reason =~ "too large"
    end

    test "a zip over the size cap, or not a zip, is refused" do
      assert {:error, [reason]} =
               Bundle.read(:crypto.strong_rand_bytes(Bundle.max_zip_bytes() + 1))

      assert reason =~ "too long"
      assert {:error, [_]} = Bundle.read("PK\x03\x04 not really")
    end

    test "stray files are ignored with a notice; one wrapping folder is fine" do
      bin =
        zip([
          {"team/canopy.md", "---\ncanopy_template: 1\nkind: bundle\nname: t\n---\n"},
          {"team/agents/one.md", agent_file("one")},
          {"team/README.txt", "hi"},
          {"team/scripts/run.sh", "rm -rf /"},
          {"__MACOSX/team/._one.md", "junk"}
        ])

      assert {:ok, %{files: [{"agents/one.md", _}], notices: [notice]}} = Bundle.read(bin)
      assert notice =~ "README.txt, scripts/run.sh"
      refute notice =~ "MACOSX"
    end
  end

  describe "teams in bundles" do
    test "members resolve to the bundle's agents after renames" do
      Fixtures.agent_fixture(%{name: "builder", system_prompt: "Someone else."})

      bin =
        Bundle.encode(%{name: "crew"}, [
          {"agents/builder.md", agent_file("builder")},
          {"agents/checker.md", agent_file("checker")},
          {"teams/crew.md", team_file("crew", "builder", ~w(builder checker))}
        ])

      plan = plan_zip(bin)

      assert named(plan, "builder").choice == %{
               action: :rename,
               name: "builder-2",
               memory: nil,
               # the file names no engine: the agent follows the default
               engine: nil
             }

      team = named(plan, "crew")
      assert team.errors == []
      assert Enum.any?(team.notices, &(&1 =~ "@builder → @builder-2"))

      assert {:ok, _} = Import.apply(plan)
      crew = Teams.get_by_name("crew")
      assert crew.lead.name == "builder-2"
      assert Enum.map(crew.members, & &1.name) == ~w(builder-2 checker)
    end

    test "a skipped agent binds the team to the agent already here" do
      existing = Fixtures.agent_fixture(%{name: "lead-here"})

      bin =
        Bundle.encode(%{name: "crew"}, [
          {"agents/lead-here.md", agent_file("lead-here")},
          {"teams/crew2.md", team_file("crew2", "lead-here", ~w(lead-here))}
        ])

      plan = plan_zip(bin)
      agent = named(plan, "lead-here")
      assert {:ok, _} = Import.apply(plan, %{agent.id => %{"action" => "skip"}})
      assert Teams.get_by_name("crew2").lead_agent_id == existing.id
    end

    test "a member that resolves to nothing is an error" do
      bin =
        Bundle.encode(%{name: "x"}, [{"teams/lost.md", team_file("lost", "ghost", ~w(ghost))}])

      plan = plan_zip(bin)

      assert ["member @ghost isn't in this import or on this machine"] =
               named(plan, "lost").errors

      refute Plan.ready?(plan)
    end

    test "the lead must be a member" do
      bin =
        Bundle.encode(%{name: "x"}, [
          {"agents/a1.md", agent_file("a1")},
          {"teams/odd.md", team_file("odd", "boss", ~w(a1))}
        ])

      plan = plan_zip(bin)
      odd = named(plan, "odd")
      assert odd.status == :invalid
      assert Enum.any?(odd.errors, &(&1 =~ "lead @boss must be one of the members"))
    end

    test "exporting a team and its playbooks reads back as identical" do
      a = Fixtures.agent_fixture(%{name: "tm-a"})
      b = Fixtures.agent_fixture(%{name: "tm-b"})
      team = Fixtures.team_fixture([a, b], %{name: "tm", roles: %{b.id => "test"}})

      text =
        Playbooks.bug_fix_text()
        |> String.replace("name: bug-fix", "name: tm-fix")
        |> String.replace("team: bugfix-team", "team: tm")

      {:ok, _} = Playbooks.create(%{body: text})

      {filename, bin} = Templates.export_team(team, playbooks: true)
      assert filename == "tm.canopy.zip"
      {:ok, %{files: files}} = Bundle.read(bin)

      assert Enum.map(files, &elem(&1, 0)) ==
               ~w(agents/tm-a.md agents/tm-b.md playbooks/tm-fix.md teams/tm.md)

      assert {"playbooks/tm-fix.md", ^text} = List.keyfind(files, "playbooks/tm-fix.md", 0)

      plan = plan_zip(bin)

      assert Enum.all?(plan.items, &(&1.status == :identical)),
             inspect(Enum.map(plan.items, &{&1.name, &1.status}))
    end
  end

  describe "playbooks in bundles" do
    test "a playbook's references follow renames, in its frontmatter only" do
      Fixtures.agent_fixture(%{name: "pm", system_prompt: "Someone else."})

      playbook = """
      ---
      name: ship-it
      description: Ship a change with @pm watching.
      coordinator: pm
      roles:
        dev: dev1
        lead: "pm"
      steps:
        - id: build
          title: Build
          owner: dev
      ---

      Ask @pm when stuck.
      """

      bin =
        Bundle.encode(%{name: "x"}, [
          {"agents/pm.md", agent_file("pm", "Coordinate.")},
          {"agents/dev1.md", agent_file("dev1", "Tell @pm when done.")},
          {"playbooks/ship-it.md", playbook}
        ])

      plan = plan_zip(bin)
      item = named(plan, "ship-it")
      assert item.errors == []
      assert item.body =~ "coordinator: pm-2\n"
      assert item.body =~ "  lead: pm-2\n"
      assert item.body =~ "Ask @pm when stuck."
      assert item.body =~ "Ship a change with @pm watching."

      # the renamed agent's old @name in prose is listed, not rewritten
      pm = named(plan, "pm")
      assert Enum.any?(pm.notices, &(&1 =~ "@pm is mentioned in @dev1, playbook ship-it"))

      assert {:ok, _} = Import.apply(plan)
      assert {:ok, d} = Playbooks.definition(Playbooks.get_by_name("ship-it"))
      assert d.coordinator == "pm-2"
      assert d.roles == %{"dev" => "dev1", "lead" => "pm-2"}
    end

    test "a renamed playbook gets its new name in the text" do
      {:ok, _} =
        Playbooks.create(%{
          body: String.replace(Playbooks.bug_fix_text(), "name: bug-fix", "name: twin-fix")
        })

      text =
        String.replace(Playbooks.bug_fix_text(), "name: bug-fix", "name: twin-fix") <>
          "\nChanged.\n"

      plan = Import.plan([{:file, "twin-fix.md", text}], machine: machine())
      [item] = plan.items
      assert %{status: :conflict, choice: %{action: :rename, name: "twin-fix-2"}} = item
      assert {:ok, _} = Import.apply(plan)
      assert Playbooks.get_by_name("twin-fix-2").body =~ "name: twin-fix-2\n"
    end

    test "an agent a playbook names that isn't anywhere is a notice, not an error" do
      text = String.replace(Playbooks.bug_fix_text(), "name: bug-fix", "name: lonely-fix")
      plan = Import.plan([{:file, "lonely-fix.md", text}], machine: machine())
      [item] = plan.items
      assert item.errors == []
      assert Enum.any?(item.notices, &(&1 =~ "@project-manager isn't in this import"))
      assert Plan.ready?(plan)
    end
  end

  test "the gallery's bug-fix bundle restores the seeded team and playbook" do
    plan = Import.plan([{:gallery_bundle, "bug-fix"}], machine: machine())
    assert Plan.ready?(plan)
    assert {:ok, _} = Import.apply(plan)

    team = Teams.get_by_name("bugfix-team")
    assert team.lead.name == "backend"
    assert Enum.map(team.members, & &1.name) == ~w(backend frontend reviewer test)
    assert Playbooks.get_by_name("bug-fix").body == Playbooks.bug_fix_text()
    assert Agents.get_by_name("project-manager")
  end
end
