defmodule Canopy.Playbooks.WriterEdgeCasesTest do
  @moduledoc "What people type into the builder must come back where they put it."
  use ExUnit.Case, async: true

  alias Canopy.Playbooks.{Definition, Writer}

  defp step(id, fields \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: id,
        owner: ["coordinator"],
        on_reject: nil,
        approval: false,
        optional: false,
        instructions: "",
        done_when: ""
      },
      fields
    )
  end

  defp draft(fields) do
    Map.merge(%{Writer.blank() | name: "edge", description: "Edge cases."}, fields)
  end

  defp round_trip(draft) do
    text = Writer.to_text(draft)
    assert {:ok, definition} = Definition.parse(text), text
    Writer.draft(definition)
  end

  test "a title ending in # keeps it" do
    draft = draft(%{title: "C# tips", steps: [step("a")]})
    assert round_trip(draft).title == "C# tips"
  end

  # The writer may demote a typed `## ` to `### `; what matters is that the
  # text stays where it was typed.
  test "a ## subheading typed into a step's instructions stays in that step" do
    instructions = "Do the thing.\n\n## Example\n\nLike this."
    draft = draft(%{steps: [step("a", %{instructions: instructions}), step("b")]})
    back = round_trip(draft)

    assert hd(back.steps).instructions =~ ~r/\ADo the thing\.\n\n##+ Example\n\nLike this\.\z/
    assert back.notes == []
  end

  test "a ## subheading typed into the ground rules stays in the ground rules" do
    guidance = "Be kind.\n\n## b\n\nNot the step."
    draft = draft(%{guidance: guidance, steps: [step("a"), step("b")]})
    back = round_trip(draft)

    assert back.guidance =~ ~r/\ABe kind\.\n\n##+ b\n\nNot the step\.\z/
    assert Enum.map(back.steps, & &1.id) == ["a", "b"]
    assert back.notes == []
  end

  test "a ## line inside a fenced code block is written as typed" do
    instructions = "Run:\n\n```markdown\n## Example\n```"
    draft = draft(%{steps: [step("a", %{instructions: instructions})]})
    assert Writer.to_text(draft) =~ "```markdown\n## Example\n```"
  end

  test "a multi-line \"Done when\" list reaches the agent unchanged" do
    text = """
    ---
    name: edge
    description: Edge cases.
    steps:
      - id: a
        title: A
        owner: coordinator
    ---

    # Edge

    ## a

    Do it.

    Done when:
    - one
    - two
    """

    assert {:ok, before} = Definition.parse(text)
    assert {:ok, after_} = before |> Writer.draft() |> Writer.to_text() |> Definition.parse()
    assert Definition.step_section(after_, "a") == Definition.step_section(before, "a")
  end

  test "multi-line description and inputs with YAML-special characters survive" do
    draft =
      draft(%{
        team: "crew",
        description: "Line one: \"quoted\" # not a comment",
        inputs: "What's broken?\n- key: value\n[brackets], {braces} & *stars*",
        steps: [step("a", %{title: "- dash: colon", owner: ["qa-lead", "true", "a,b"]})]
      })

    back = round_trip(draft)
    assert back.description == draft.description
    assert back.inputs == draft.inputs
    assert hd(back.steps).title == "- dash: colon"
    assert hd(back.steps).owner == ["qa-lead", "true", "a,b"]
  end

  test "CRLF line endings pasted into instructions do not split the step" do
    draft = draft(%{steps: [step("a", %{instructions: "One.\r\n\r\nTwo."}), step("b")]})
    back = round_trip(draft)

    assert Enum.map(back.steps, & &1.id) == ["a", "b"]
    assert hd(back.steps).instructions =~ "Two."
  end
end
