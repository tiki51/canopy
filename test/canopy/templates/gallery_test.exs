defmodule Canopy.Templates.GalleryTest do
  use Canopy.DataCase, async: false

  import ExUnit.CaptureIO

  alias Canopy.Agents.Agent
  alias Canopy.{Agents, Playbooks, Seeds, Templates}
  alias Canopy.Templates.{AgentTemplate, Gallery}

  test "every gallery agent decodes and passes the changeset on either engine, with no warnings" do
    files = Gallery.agent_files()
    assert length(files) == 20

    for {name, text} <- files do
      assert {:ok, :agent, t} = Templates.decode(text, gallery: true), name
      assert t.warnings == [], "#{name}: #{inspect(t.warnings)}"
      assert t.name == name
      assert t.mode in ["plan", "build"], "#{name} has no mode"
      # engine-neutral: the importing machine picks the engine and model
      assert is_nil(t.engine) and is_nil(t.model) and is_nil(t.effort), name

      for engine <- ["opencode", "claude_code"] do
        {attrs, notices} = AgentTemplate.attrs(t, engine)
        assert notices == [], "#{name}: #{inspect(notices)}"
        changeset = Agent.changeset(%Agent{}, attrs)
        assert changeset.valid?, "#{name} on #{engine}: #{inspect(changeset.errors)}"
      end
    end

    names = Enum.map(files, &elem(&1, 0))
    assert names == Enum.uniq(names)
  end

  test "the seeded agents are the gallery's seed entries" do
    assert length(Gallery.seed_agents()) == 13
    assert Enum.sort(Seeds.agent_names()) == Enum.sort(Enum.map(Gallery.seed_agents(), & &1.name))

    new = Gallery.agents() |> Enum.reject(& &1.template.seed) |> Enum.map(& &1.name)

    assert new ==
             ~w(accessibility-reviewer dependency-updater incident-investigator migration-reviewer
                performance-engineer release-manager security-reviewer)
  end

  test "the bug-fix bundle carries the seeded team and playbook, and the agents they name" do
    bundle = Gallery.bundle("bug-fix")
    assert bundle.title == "Bug-fix team and playbook"
    paths = Enum.map(bundle.files, &elem(&1, 0))
    assert "teams/bugfix-team.md" in paths

    # the playbook is a copy of the seeded one: keep them the same
    assert {"playbooks/bug-fix.md", text} = List.keyfind(bundle.files, "playbooks/bug-fix.md", 0)
    assert text == Playbooks.bug_fix_text()

    for name <- ~w(backend frontend reviewer test project-manager),
        do: assert("agents/#{name}.md" in paths)

    for {path, text} <- bundle.files, path != "canopy.md", path != "playbooks/bug-fix.md" do
      assert {:ok, _kind, _} = Templates.decode(text, gallery: true), path
    end
  end

  test "compare/2 tells an added agent from one that differs" do
    capture_io(&Seeds.run/0)
    template = Enum.find(Gallery.seed_agents(), &(&1.name == "reviewer"))
    reviewer = Agents.get_by_name("reviewer")
    assert Gallery.compare(template, reviewer) == :added

    # the engine is this machine's business
    {:ok, moved} = Agents.update(reviewer, %{engine: "claude_code", permission_mode: "default"})
    assert Gallery.compare(template, moved) == :added

    {:ok, edited} = Agents.update(moved, %{role: "Something else"})
    assert Gallery.compare(template, edited) == :differs
  end
end
