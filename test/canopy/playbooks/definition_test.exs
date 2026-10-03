defmodule Canopy.Playbooks.DefinitionTest do
  use ExUnit.Case, async: true

  alias Canopy.Playbooks
  alias Canopy.Playbooks.Definition

  defp text(frontmatter, body \\ "") do
    "---\n" <> String.trim(frontmatter) <> "\n---\n" <> body
  end

  @minimal """
  name: tiny
  description: A tiny playbook.
  roles:
    dev: backend
  steps:
    - id: build
      title: Build it
      owner: dev
  """

  test "the seeded bug-fix playbook parses with its six steps, team, and gate" do
    assert {:ok, d} = Definition.parse(Playbooks.bug_fix_text())
    assert d.name == "bug-fix"
    assert d.team == "bugfix-team"
    assert d.coordinator == "project-manager"
    assert d.channel == "new"
    assert d.stall_after == 30
    assert d.warnings == []
    assert Enum.map(d.steps, & &1.id) == ~w(triage reproduce fix verify review sign-off)
    assert %{owner: ["backend", "frontend"]} = Definition.step(d, "fix")
    assert %{on_reject: "fix"} = Definition.step(d, "review")
    assert %{approval: true, owner: ["coordinator"]} = Definition.step(d, "sign-off")
    assert Definition.owner_roles(d) == ~w(test backend frontend reviewer)
  end

  test "defaults: the current channel, a 30 minute stall, no team" do
    assert {:ok, d} = Definition.parse(text(@minimal))
    assert d.channel == "current"
    assert d.stall_after == 30
    assert d.team == nil
    assert [%{id: "build", owner: ["dev"], approval: false, optional: false}] = d.steps
  end

  test "stall_after takes durations, minutes, or off" do
    for {value, minutes} <- [{"45m", 45}, {"2h", 120}, {"90", 90}, {"off", nil}, {"false", nil}] do
      assert {:ok, d} = Definition.parse(text(@minimal <> "stall_after: #{value}\n"))
      assert d.stall_after == minutes, "stall_after: #{value}"
    end

    assert {:error, [reason]} = Definition.parse(text(@minimal <> "stall_after: soon\n"))
    assert reason =~ "stall_after"
  end

  for {label, frontmatter, expected} <- [
        {"missing name",
         "description: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator",
         "name is missing"},
        {"missing steps", "name: abc\ndescription: x", "steps is missing"},
        {"a name that is not kebab-case",
         "name: Bug_Fix\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator",
         "kebab-case"},
        {"a description over 200 chars",
         "name: abc\ndescription: #{String.duplicate("x", 201)}\nsteps:\n  - id: a\n    title: A\n    owner: coordinator",
         "at most 200"},
        {"duplicate step ids",
         "name: abc\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator\n  - id: a\n    title: B\n    owner: coordinator",
         "duplicate step id a"},
        {"an undefined owner role",
         "name: abc\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: designer",
         "owner role designer is not defined"},
        {"an on_reject that points forward",
         "name: abc\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator\n    on_reject: b\n  - id: b\n    title: B\n    owner: coordinator",
         "on_reject must point to an earlier step"},
        {"unknown keys",
         "name: abc\ndescription: x\nwhen: always\nsteps:\n  - id: a\n    title: A\n    owner: coordinator",
         "unknown field \"when\""},
        {"an unknown step key",
         "name: abc\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator\n    timeout: 5",
         "step a: unknown field \"timeout\""},
        {"approval other than user",
         "name: abc\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator\n    approval: admin",
         "approval must be user"},
        {"invalid YAML", "name: [abc\ndescription: x", "invalid YAML"}
      ] do
    test "refuses #{label}" do
      assert {:error, reasons} = Definition.parse(text(unquote(frontmatter)))
      assert Enum.any?(reasons, &(&1 =~ unquote(expected))), inspect(reasons)
    end
  end

  test "more than 20 steps are refused" do
    steps =
      Enum.map_join(1..21, "\n", fn n ->
        "  - id: s#{n}\n    title: Step #{n}\n    owner: coordinator"
      end)

    assert {:error, ["at most 20 steps"]} =
             Definition.parse(text("name: big\ndescription: x\nsteps:\n" <> steps))
  end

  test "without frontmatter, the text is refused with a reason" do
    assert {:error, [reason]} = Definition.parse("# just markdown")
    assert reason =~ "frontmatter"
    assert {:error, _} = Definition.parse(nil)
  end

  test "with a team, any role may own a step (the team fills it at start)" do
    fm =
      "name: abc\ndescription: x\nteam: bugfix-team\nsteps:\n  - id: a\n    title: A\n    owner: [designer, qa]"

    assert {:ok, d} = Definition.parse(text(fm))
    assert Definition.owner_roles(d) == ~w(designer qa)
  end

  test "step_section/2 returns the text under a step's heading; guidance is what comes before" do
    body = """
    # Tiny

    Ground rules.

    ## build

    Build the thing.

    Done when: it builds.

    ## notes

    Not a step.
    """

    assert {:ok, d} = Definition.parse(text(@minimal, body))
    assert Definition.step_section(d, "build") == "Build the thing.\n\nDone when: it builds."
    assert Definition.step_section(d, "missing") == nil
    assert Definition.guidance(d) == "# Tiny\n\nGround rules."
    assert d.warnings == ["section \"## notes\" matches no step id"]
  end

  # 14
  test "an alias bomb is refused before the parser expands it" do
    bomb = """
    name: bomb
    description: x
    a: &a ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]
    b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
    c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
    d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
    e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
    f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
    g: &g [*f,*f,*f,*f,*f,*f,*f,*f,*f]
    steps:
      - id: a
        title: A
        owner: coordinator
    """

    {micros, result} = :timer.tc(fn -> Definition.parse(text(bomb)) end)
    assert {:error, [reason]} = result
    assert reason =~ "anchors and aliases"
    assert micros < 1_000_000

    # text that merely contains & or * is fine
    fm = """
    name: rnd
    description: "R&D: fix the *bold* thing & more"
    steps:
      - id: a
        title: R&D work
        owner: coordinator
    """

    assert {:ok, _} = Definition.parse(text(fm))
  end

  # 14
  test "size limits apply before parsing" do
    assert {:error, [reason]} = Definition.parse(String.duplicate("x", 40_001))
    assert reason =~ "too long"

    long_header =
      "name: big\ndescription: x\ninputs: " <> String.duplicate("y", 8_100) <> "\nsteps: []"

    assert {:error, [reason]} = Definition.parse(text(long_header))
    assert reason =~ "the frontmatter is too long"
  end

  # 15
  test "keys that are not plain text are reasons, never crashes" do
    for fm <- [
          "? [a, b]\n: x\nname: abc\ndescription: x\nsteps: []",
          "1: x\nname: abc\ndescription: x\nsteps:\n  - id: a\n    title: A\n    owner: coordinator",
          "name: abc\ndescription: x\nroles:\n  ? {a: 1}\n  : backend\nsteps:\n  - id: a\n    title: A\n    owner: coordinator",
          "name: abc\ndescription: x\nsteps:\n  - ? [x]\n    : y\n    id: a\n    title: A\n    owner: coordinator",
          "name: {a: 1}\ndescription: [x]\nsteps:\n  - id: a\n    title: {t: 1}\n    owner: {o: 1}"
        ] do
      assert {:error, [_ | _]} = Definition.parse(text(fm)), fm
    end
  end

  test "a step title must not be blank" do
    fm = "name: abc\ndescription: x\nsteps:\n  - id: a\n    title: \"  \"\n    owner: coordinator"
    assert {:error, ["step a: title is missing"]} = Definition.parse(text(fm))
  end
end
