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
    {:ok, draft} = PlaybookBuilder.restore(draft, undo)

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

    {:ok, draft} = PlaybookBuilder.restore(draft, undo)

    assert %{id: "fix-2"} = PlaybookBuilder.step(draft, added)
    assert %{on_reject: "fix"} = Enum.find(draft.steps, &(&1.id == "review"))
    assert Enum.find(draft.steps, &(&1.id == "fix")).uid == undo.step.uid
    assert {:ok, _} = PlaybookBuilder.parse(draft)
  end

  test "plain_words/1 says lead and channel name" do
    assert PlaybookBuilder.plain_words(
             "a DM keeps its agents and this run needs others (the coordinator or the roster); start it with channel_name to run it in a new channel"
           ) ==
             "a DM keeps its agents and this run needs others (the lead or the roster); start it with a channel name to run it in a new channel"

    assert PlaybookBuilder.plain_words("the coordinator is missing") == "the lead is missing"
  end

  test "plain_words/1 never touches names that say coordinator" do
    assert PlaybookBuilder.plain_words("the coordinator @coordinator-bot is deactivated") ==
             "the lead @coordinator-bot is deactivated"

    for text <- [
          "coordinator-handoff is disabled; the user enables it on the Playbooks page",
          "@coordinator (role review) is deactivated; use assign",
          "no agent @coordinator-bot for role coordinator-review; fix it with assign"
        ] do
      assert PlaybookBuilder.plain_words(text) == text
    end

    assert PlaybookBuilder.plain_words(
             "#coordinator-sync already has a playbook run in progress (coordinator-handoff, 7); finish or cancel it first, or start in a new channel with channel_name"
           ) ==
             "#coordinator-sync already has a playbook run in progress (coordinator-handoff, 7); finish or cancel it first, or start in a new channel with a channel name"
  end

  # -- a new playbook's name -----------------------------------------------------

  defp titled(title, taken \\ []) do
    PlaybookBuilder.blank(taken) |> Map.put(:title, title) |> PlaybookBuilder.refresh()
  end

  defp name_problems(draft) do
    draft
    |> PlaybookBuilder.problems(PlaybookBuilder.parse(draft))
    |> Enum.filter(&(&1[:kind] == :name))
  end

  test "a title with no plain letters still gives the playbook a valid name" do
    for title <- ["日本語のレビュー", "🚀🚀", "Ревью"] do
      draft = titled(title)
      assert draft.name == "playbook"
      assert name_problems(draft) == []
    end

    assert titled("日本語のレビュー", ["playbook", "playbook-2"]).name == "playbook-3"
    # the name follows the title once it has letters to make one from
    assert titled("日本語 review").name == "review"
    assert titled("").name == ""
  end

  test "a one-letter title gets a free made-up name; a one-letter name is a problem" do
    assert titled("X").name == "playbook"
    assert titled("X", ["playbook"]).name == "playbook-2"

    draft = %{titled("X") | name: "x", name_follows_title: false}

    assert [%{text: "The name agents know it by needs at least 2 characters."}] =
             name_problems(draft)

    draft = %{titled("X") | name: "Not Kebab", name_follows_title: false}
    assert [%{text: "The name agents know it by must be lowercase" <> _}] = name_problems(draft)
  end

  # -- send-backs follow steps, not keys -------------------------------------------

  defp fresh_draft(titles) do
    Enum.reduce(titles, %{PlaybookBuilder.blank() | steps: []}, fn title, draft ->
      {draft, uid} = PlaybookBuilder.add_step(draft, length(draft.steps))

      draft
      |> PlaybookBuilder.update_step(uid, &%{&1 | title: title})
      |> PlaybookBuilder.refresh()
    end)
  end

  defp at(draft, n), do: Enum.at(draft.steps, n)

  test "renaming one of two steps with one title keeps the send-back on its step" do
    draft = fresh_draft(["Review", "Review", "Wrap up"])
    [first, second, wrap] = draft.steps
    assert {first.id, second.id} == {"review", "review-2"}

    # Wrap up sends back to the first Review
    draft = PlaybookBuilder.set_send_back(draft, wrap.uid, "review")
    assert at(draft, 2).back_uid == first.uid

    draft =
      draft
      |> PlaybookBuilder.update_step(first.uid, &%{&1 | title: "Check"})
      |> PlaybookBuilder.refresh()

    assert Enum.map(draft.steps, & &1.id) == ~w(check review wrap-up)
    assert at(draft, 2).on_reject == "check"

    assert PlaybookBuilder.text(draft) =~
             "  - id: wrap-up\n    title: Wrap up\n    on_reject: check\n"
  end

  test "reordering two untitled steps keeps the send-back on its step" do
    draft = fresh_draft(["", "", "Review"])
    [a, b, review] = draft.steps
    assert {a.id, b.id} == {"step-1", "step-2"}

    draft = PlaybookBuilder.set_send_back(draft, review.uid, "step-1")

    draft =
      draft |> PlaybookBuilder.reorder([b.uid, a.uid, review.uid]) |> PlaybookBuilder.refresh()

    assert Enum.map(draft.steps, & &1.uid) == [b.uid, a.uid, review.uid]
    assert PlaybookBuilder.step(draft, a.uid).id == "step-2"
    # still the step it was set to, now keyed step-2
    assert PlaybookBuilder.step(draft, review.uid).on_reject == "step-2"
  end

  test "a send-back to a key no step has stays, so it shows as a problem" do
    draft = bug_fix()
    review = uid(draft, "review")
    draft = PlaybookBuilder.update_step(draft, review, &%{&1 | on_reject: "ghost", back_uid: nil})
    draft = PlaybookBuilder.refresh(draft)

    assert %{on_reject: "ghost"} = PlaybookBuilder.step(draft, review)

    assert Enum.any?(
             PlaybookBuilder.problems(draft, PlaybookBuilder.parse(draft)),
             &(&1[:kind] == :send_back)
           )
  end

  # -- undo at the step limit ----------------------------------------------------------

  test "Undo is refused, with a reason, when the draft already has the most steps" do
    draft = bug_fix()
    {draft, undo} = PlaybookBuilder.delete_step(draft, uid(draft, "fix"))

    draft =
      Enum.reduce(length(draft.steps)..(PlaybookBuilder.max_steps() - 1)//1, draft, fn _, d ->
        d |> PlaybookBuilder.add_step(length(d.steps)) |> elem(0)
      end)

    assert length(draft.steps) == PlaybookBuilder.max_steps()
    assert {:error, reason} = PlaybookBuilder.restore(draft, undo)
    assert reason =~ "at most 20 steps"

    {draft, _} = PlaybookBuilder.delete_step(draft, List.last(draft.steps).uid)
    assert {:ok, draft} = PlaybookBuilder.restore(draft, undo)
    assert length(draft.steps) == PlaybookBuilder.max_steps()
  end
end
