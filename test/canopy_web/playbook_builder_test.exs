defmodule CanopyWeb.PlaybookBuilderTest do
  use ExUnit.Case, async: true

  alias Canopy.Playbooks
  alias Canopy.Playbooks.Definition
  alias CanopyWeb.PlaybookBuilder

  defp bug_fix do
    {:ok, definition} = Definition.parse(Playbooks.bug_fix_text())
    PlaybookBuilder.load(definition)
  end

  defp uid(draft, id), do: Enum.find(draft.steps, &(&1.id == id)).uid

  test "a duplicated step gets its own key; send-backs to the original stay with it" do
    draft = bug_fix()
    {draft, copy} = PlaybookBuilder.duplicate_step(draft, uid(draft, "fix"))

    assert %{id: "fix-copy", title: "Fix (copy)"} = PlaybookBuilder.step(draft, copy)
    assert %{on_reject: "fix"} = Enum.find(draft.steps, &(&1.id == "review"))
    assert {:ok, _} = PlaybookBuilder.parse(draft)
  end

  test "Undo after adding a step never leaves two steps with one uid" do
    draft = bug_fix()
    last = List.last(draft.steps).uid
    {draft, undo} = PlaybookBuilder.delete_step(draft, last)
    {draft, added} = PlaybookBuilder.add_step(draft, 0)
    draft = PlaybookBuilder.restore(draft, undo)

    uids = Enum.map(draft.steps, & &1.uid)
    assert added != last
    assert uids == Enum.uniq(uids)
  end

  test "Undo keeps send-backs with the restored step when a new step took its title" do
    draft = bug_fix()
    {draft, undo} = PlaybookBuilder.delete_step(draft, uid(draft, "fix"))
    assert %{on_reject: nil} = Enum.find(draft.steps, &(&1.id == "review"))

    {draft, added} = PlaybookBuilder.add_step(draft, 0, "lead")
    draft = PlaybookBuilder.update_step(draft, added, &%{&1 | title: "Fix"})
    draft = PlaybookBuilder.refresh(draft)
    assert %{id: "fix"} = PlaybookBuilder.step(draft, added)

    draft = PlaybookBuilder.restore(draft, undo)

    assert %{id: "fix-2"} = PlaybookBuilder.step(draft, added)
    assert %{on_reject: "fix"} = Enum.find(draft.steps, &(&1.id == "review"))
    assert Enum.find(draft.steps, &(&1.id == "fix")).uid == undo.step.uid
    assert {:ok, _} = PlaybookBuilder.parse(draft)
  end

  test "plain_words/1 says lead and channel name" do
    assert PlaybookBuilder.plain_words("pick the coordinator, or start with channel_name") ==
             "pick the lead, or start with a channel name"
  end
end
