defmodule Canopy.Playbooks.Sharing.CompareTest do
  use ExUnit.Case, async: true

  import Canopy.PlaybookSharingHelpers, only: [playbook_text: 2]

  alias Canopy.Playbooks.Sharing.Compare

  defp text(opts), do: playbook_text("bug-fix", opts)

  test "a step only GitHub has, from the base, is GitHub's addition" do
    base = text(steps: ~w(plan write))
    mine = base
    theirs = text(steps: ~w(plan write review))

    result = Compare.compare(mine, theirs, base)

    assert [
             %{
               kind: :added,
               by: :remote,
               step: "Review",
               text: "GitHub adds step Review (coordinator) after Write"
             }
           ] =
             result.changes

    assert [{_, _, :same}, {_, _, :same}, {nil, %{id: "review"}, :added}] = result.rows
  end

  test "who changed what, against the base" do
    base =
      text(steps: ~w(plan write), instructions: %{"plan" => "Plan it.", "write" => "Write it."})

    mine =
      text(
        steps: ~w(plan write),
        instructions: %{"plan" => "Plan it well.", "write" => "Write it."}
      )

    theirs =
      text(
        steps: ~w(plan write),
        instructions: %{"plan" => "Plan it.", "write" => "Write it up."}
      )

    changes = Compare.compare(mine, theirs, base).changes
    assert %{by: :local, step: "Plan"} = Enum.find(changes, &(&1.step == "Plan"))
    assert %{by: :remote, step: "Write"} = Enum.find(changes, &(&1.step == "Write"))
  end

  test "without a base nobody is named" do
    changes = Compare.compare(text(guidance: "A."), text(guidance: "B."), nil).changes
    assert [%{by: nil, step: nil, text: "The guidance differs"}] = changes
  end

  test "a # Title only one side has is not a change" do
    base = text(guidance: "Work carefully.")
    mine = text(guidance: "# Bug fix\n\nWork carefully.")

    for {l, r, b} <- [{mine, base, base}, {base, mine, base}, {mine, base, nil}] do
      result = Compare.compare(l, r, b)
      assert result.changes == []
      assert result.instructions == []
    end
  end

  test "a changed # Title is a title change, not a guidance change" do
    base = text(guidance: "# Bug fix\n\nWork carefully.")
    mine = text(guidance: "# Fixing bugs\n\nWork carefully.")

    assert [%{kind: :changed, by: :local, step: nil, text: text}] =
             Compare.compare(mine, base, base).changes

    assert text == "You changed the title: “Bug fix” → “Fixing bugs”"
    assert Compare.compare(mine, base, base).instructions == []

    assert [%{by: nil, text: "The title differs: yours “Fixing bugs”, GitHub's “Bug fix”"}] =
             Compare.compare(mine, base, nil).changes

    theirs = text(guidance: "# Bug fix\n\nWork fast.")

    assert [
             %{by: :local, text: "You changed the title" <> _},
             %{by: :remote, text: "GitHub changed the guidance"}
           ] = Compare.compare(mine, theirs, base).changes

    assert [%{step: nil, remote: [{:eq, "Work "}, {:ins, "fast."}]}] =
             Compare.compare(mine, theirs, base).instructions
  end

  test "moved steps get a row on each side" do
    result = Compare.compare(text(steps: ~w(aa bb cc)), text(steps: ~w(bb cc aa)), nil)
    kinds = Enum.map(result.rows, &elem(&1, 2))
    assert Enum.count(kinds, &(&1 == :moved)) == 2
    assert Enum.any?(result.changes, &(&1.kind == :moved))
  end

  test "an add on one side and a move on the other names only the mover" do
    base = text(steps: ~w(aa bb cc))
    mine = text(steps: ~w(aa bb cc dd))
    theirs = text(steps: ~w(bb cc aa))

    moves = Compare.compare(mine, theirs, base).changes |> Enum.filter(&(&1.kind == :moved))
    assert moves != []
    assert Enum.all?(moves, &(&1.by == :remote))
  end

  test "a word diff past the budget is one change per side, keeping the common ends" do
    words = fn prefix -> Enum.map_join(1..1_500, " ", &"#{prefix}#{&1}") end
    local = "Same start. " <> words.("a") <> " Same end."
    remote = "Same start. " <> words.("b") <> " Same end."

    %{local: l, remote: r} = Compare.segs(local, remote)
    assert [{:eq, "Same start. "}, {:ins, _}, {:eq, " Same end."}] = l
    assert [{:eq, "Same start. "}, {:ins, _}, {:eq, " Same end."}] = r
    assert Enum.map_join(l, &elem(&1, 1)) == local
    assert Enum.map_join(r, &elem(&1, 1)) == remote
  end

  test "instructions: each side's segments join back into its text" do
    mine = text(instructions: %{"work" => "Fix the bug quickly and well."})
    theirs = text(instructions: %{"work" => "Fix the bug carefully and well, then test."})

    [item] = Compare.compare(mine, theirs, nil).instructions
    assert item.step == "Work"
    assert Enum.map_join(item.local, &elem(&1, 1)) == "Fix the bug quickly and well."

    assert Enum.map_join(item.remote, &elem(&1, 1)) ==
             "Fix the bug carefully and well, then test."

    assert {:ins, "quickly"} in item.local
    assert Enum.any?(item.remote, &match?({:ins, _}, &1))
  end

  test "file diff labels both sides and shows the change" do
    diff =
      Compare.compare(text(guidance: "A."), text(guidance: "B."), nil,
        local_version: 4,
        remote_version: 3
      ).file_diff

    assert diff =~ "--- yours v4\n+++ GitHub v3\n@@ "
    assert diff =~ "\n-A.\n+B.\n"
    assert diff =~ "\n-version: 4\n"
  end

  test "a new file shows only GitHub's side" do
    theirs = text(steps: ~w(plan write), guidance: "Rules.")
    result = Compare.compare(nil, theirs, nil, remote_version: 2)

    assert result.changes == []
    assert [{nil, %{id: "plan"}, :added}, {nil, %{id: "write"}, :added}] = result.rows

    assert [
             %{step: nil, local: [], remote: [{:ins, "Rules."}]},
             %{step: "Plan"},
             %{step: "Write"}
           ] = result.instructions

    assert result.file_diff =~ "+++ GitHub v2\n@@ -0,0 +1,"

    assert result.file_diff
           |> String.split("\n")
           |> Enum.drop(3)
           |> Enum.reject(&(&1 == ""))
           |> Enum.all?(&String.starts_with?(&1, "+"))
  end
end
