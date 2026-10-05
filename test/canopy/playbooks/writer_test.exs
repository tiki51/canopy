defmodule Canopy.Playbooks.WriterTest do
  use ExUnit.Case, async: true

  alias Canopy.PlaybookHelpers
  alias Canopy.Playbooks
  alias Canopy.Playbooks.{Definition, Writer}

  defp draft!(text) do
    assert {:ok, definition} = Definition.parse(text)
    Writer.draft(definition)
  end

  defp round_trip(draft), do: draft |> Writer.to_text() |> draft!()

  @texts [
    {"the seeded bug-fix playbook", Playbooks.bug_fix_text()},
    {"the test helper's playbook",
     PlaybookHelpers.playbook_text("tiny", [{"plan", "Plan", "coordinator"}], "team: crew\n")},
    {"a playbook with every option",
     """
     ---
     name: everything
     description: "Quotes: a colon, and # a hash."
     team: "@crew"
     roles:
       writer: "@editor"
       checker: qa
       spare: researcher
     coordinator: project-manager
     channel: current
     stall_after: 90
     inputs: |
       What to write.
       Who reads it.
     steps:
       - id: draft
         title: "Draft: first pass"
         owner: [writer, checker]
       - id: check
         title: Fact check
         owner: checker
         on_reject: draft
         optional: true
       - id: ok
         title: Your sign-off
         owner: coordinator
         approval: user
     ---

     No heading here, just rules.

     ## Notes

     Kept with the rules.

     ## draft

     Write it.

     - point one
     - point two

     DONE WHEN: a draft exists
     and is long enough.

     ## old-step

     A note left over.

     ## check

     Check it.

     ## ok
     """},
    {"a playbook with no body",
     """
     ---
     name: bare
     description: Nothing but steps.
     stall_after: off
     steps:
       - id: only
         title: Only step
         owner: coordinator
     ---
     """}
  ]

  for {label, text} <- @texts do
    @text text

    test "#{label}: a draft survives writing and reading back" do
      draft = draft!(@text)
      assert round_trip(draft) == draft
    end

    test "#{label}: writing is stable after one normalising pass" do
      once = @text |> draft!() |> Writer.to_text()
      assert once |> draft!() |> Writer.to_text() == once
    end

    test "#{label}: the written text means the same to a run" do
      assert {:ok, before} = Definition.parse(@text)
      assert {:ok, after_} = @text |> draft!() |> Writer.to_text() |> Definition.parse()

      assert after_.steps == before.steps
      assert after_.roles == before.roles

      for key <- ~w(name description team coordinator channel stall_after inputs)a do
        assert Map.get(after_, key) == Map.get(before, key), "#{key}"
      end

      for step <- before.steps do
        assert Definition.step_section(after_, step.id) ==
                 normalise_section(Definition.step_section(before, step.id))
      end
    end
  end

  # "Done when" is one line in the builder
  defp normalise_section(text) when text in [nil, ""], do: nil

  defp normalise_section(text) do
    paragraphs = String.split(text, ~r/\n[ \t]*\n/)
    last = List.last(paragraphs)

    if Regex.match?(~r/\Adone when:/i, last) and not Regex.match?(~r/\n\s*[-*]/, last) do
      done = last |> String.replace(~r/\Adone when:/i, "") |> String.replace(~r/\s+/, " ")
      (Enum.drop(paragraphs, -1) ++ ["Done when: " <> String.trim(done)]) |> Enum.join("\n\n")
    else
      text
    end
  end

  test "the seed reads as the builder shows it" do
    draft = draft!(Playbooks.bug_fix_text())

    assert draft.title == "Bug fix"
    assert draft.guidance =~ ~r/\AGround rules for the whole run:/
    assert Enum.map(draft.roles, & &1.key) == ~w(test backend frontend reviewer)

    assert %{
             id: "triage",
             instructions: "Read the brief." <> _,
             done_when: "the task says what's broken, where, and how to see it, and names" <> _
           } = hd(draft.steps)

    sign_off = List.last(draft.steps)
    assert sign_off.done_when == ""
    assert sign_off.instructions =~ "Post one summary for the user"
    assert draft.notes == []
  end

  test "frontmatter keys come out in a fixed order and defaults are left out" do
    text = Writer.to_text(draft!(Playbooks.bug_fix_text()))
    [_, frontmatter, _] = String.split(text, "---\n", parts: 3)

    keys =
      frontmatter
      |> String.split("\n")
      |> Enum.flat_map(&(Regex.run(~r/\A([a-z_]+):/, &1, capture: :all_but_first) || []))

    assert keys == ~w(name description team roles coordinator channel inputs steps)
    refute text =~ "stall_after"
    assert text =~ "    owner: [backend, frontend]\n"
    assert text =~ "  - id: review\n    title: Review\n    owner: reviewer\n    on_reject: fix\n"
    assert text =~ "\n# Bug fix\n\nGround rules for the whole run:"
  end

  test "sections that match no step are kept at the end; earlier ones stay with the rules" do
    {_, text} = Enum.at(@texts, 2)
    draft = draft!(text)

    assert draft.title == "Everything"
    assert draft.guidance == "No heading here, just rules.\n\n## Notes\n\nKept with the rules."
    assert draft.notes == [{"old-step", "A note left over."}]
    assert Writer.to_text(draft) =~ ~r/Check it.\n\n## old-step\n\nA note left over.\n\z/
  end

  test "a Done when that is a list stays in the instructions, as written" do
    text = """
    ---
    name: listed
    description: D.
    steps:
      - id: a
        title: A
        owner: coordinator
    ---

    ## a

    Do it.

    Done when:
    - the first thing
    - the second thing
    """

    draft = draft!(text)

    assert draft.steps |> hd() |> Map.take([:instructions, :done_when]) ==
             %{
               instructions: "Do it.\n\nDone when:\n- the first thing\n- the second thing",
               done_when: ""
             }

    {:ok, before} = Definition.parse(text)
    {:ok, after_} = draft |> Writer.to_text() |> Definition.parse()
    assert Definition.step_section(after_, "a") == Definition.step_section(before, "a")
  end

  test "a role with no agent yet is kept in the draft but not written" do
    draft = %{
      Writer.blank()
      | name: "x-y",
        description: "D.",
        team: "crew",
        roles: [%{key: "dev", agent: nil}, %{key: "qa", agent: "test"}],
        steps: [
          %{
            id: "a",
            title: "A",
            owner: ["dev"],
            on_reject: nil,
            approval: false,
            optional: false,
            instructions: "",
            done_when: ""
          }
        ]
    }

    text = Writer.to_text(draft)
    assert text =~ "roles:\n  qa: test\n"
    refute text =~ "dev:"
    assert {:ok, _} = Definition.parse(text)
  end

  test "stall_after is written as minutes or hours" do
    for {minutes, line} <- [
          {45, "stall_after: 45m"},
          {120, "stall_after: 2h"},
          {nil, "stall_after: off"}
        ] do
      draft = %{draft!(Playbooks.bug_fix_text()) | stall_after: minutes}
      assert Writer.to_text(draft) =~ line <> "\n"
      assert round_trip(draft).stall_after == minutes
    end
  end

  test "slug/1 and humanize/1" do
    assert Writer.slug("Bug fix!") == "bug-fix"
    assert Writer.slug("  Café — release notes ") == "cafe-release-notes"
    assert Writer.slug(String.duplicate("ab ", 30)) |> String.length() <= 40
    assert Writer.humanize("bug-fix") == "Bug fix"
  end
end
