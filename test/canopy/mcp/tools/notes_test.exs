defmodule Canopy.MCP.Tools.NotesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.Notes
  alias Canopy.MCP.Tools.{NotesRead, NotesWrite}
  alias Canopy.Runtime.Prompts

  setup do
    scenario()
  end

  test "read is empty at first, write appends by default and can replace", ctx do
    assert {:ok, text} = call(NotesRead, %{}, ctx)
    assert text =~ "empty"

    assert {:ok, text} =
             call(NotesWrite, %{text: "## 2026-09-15\n- payments.py is the worker"}, ctx)

    assert text =~ "notes appended"
    assert {:ok, _} = call(NotesWrite, %{text: "- prefer small PRs"}, ctx)
    assert {:ok, body} = call(NotesRead, %{}, ctx)
    assert body =~ "payments.py is the worker\n\n- prefer small PRs"

    # the file in the repository is what the tools wrote, under the standing header
    assert File.read!(Notes.shared_path(ctx.repository.path)) =~
             "# Shared notes\n\n" <> "Facts every agent"

    assert File.read!(Notes.shared_path(ctx.repository.path)) =~ "prefer small PRs\n"

    assert {:ok, text} = call(NotesWrite, %{text: "# pruned", mode: "replace"}, ctx)
    assert text =~ "notes replaced"
    assert Notes.get(ctx.repository.path) == "# pruned"

    assert {:error, "text is empty"} = call(NotesWrite, %{text: "  "}, ctx)
    assert {:error, reason} = call(NotesWrite, %{text: "x", mode: "prepend"}, ctx)
    assert reason =~ "append or replace"

    assert {:error, reason} =
             call(NotesWrite, %{text: String.duplicate("x", Notes.max_bytes() + 1)}, ctx)

    assert reason =~ "pruned version"
  end

  test "the notes are per repository and shared by every agent in it", ctx do
    other_agent = agent_fixture()
    same_repo = session_fixture(%{channel: ctx.channel, agent_id: other_agent.id})
    {:ok, _} = call(NotesWrite, %{text: "- ours"}, ctx)
    assert {:ok, "- ours"} = call(NotesRead, %{}, same_repo)

    elsewhere = scenario()
    assert {:ok, text} = call(NotesRead, %{}, elsewhere)
    assert text =~ "empty"
  end

  test "the notes ride along in every agent's system prompt for the repository", ctx do
    {:ok, _} = call(NotesWrite, %{text: "- run `mix precommit` first"}, ctx)

    text = Prompts.system(ctx.agent, ctx.channel, ctx.repository)
    assert text =~ "Shared notes for this repository"
    assert text =~ "- run `mix precommit` first"
    assert text =~ Notes.shared_path(ctx.repository.path)
    refute text =~ "{{"
  end

  test "a repository whose directory is gone is an error, not a crash", ctx do
    File.rm_rf!(ctx.repository.path)
    assert {:ok, text} = call(NotesRead, %{}, ctx)
    assert text =~ "empty"
  end
end
