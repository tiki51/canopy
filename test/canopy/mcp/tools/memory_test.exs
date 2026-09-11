defmodule Canopy.MCP.Tools.MemoryTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.Memory
  alias Canopy.MCP.Tools.{MemoryRead, MemoryWrite}

  setup do
    scenario()
  end

  test "read is empty at first, write appends by default and can replace", ctx do
    assert {:ok, text} = call(MemoryRead, %{}, ctx)
    assert text =~ "Your memory is empty"

    assert {:ok, text} =
             call(MemoryWrite, %{text: "## 2026-09-10\n- payments.py is the worker"}, ctx)

    assert text =~ "memory appended"
    assert {:ok, _} = call(MemoryWrite, %{text: "- prefer small PRs"}, ctx)
    assert {:ok, body} = call(MemoryRead, %{}, ctx)
    assert body =~ "payments.py is the worker\n\n- prefer small PRs"

    assert {:ok, text} = call(MemoryWrite, %{text: "# pruned", mode: "replace"}, ctx)
    assert text =~ "memory replaced"
    assert Memory.get(ctx.agent.id) == "# pruned"

    assert {:error, "text is empty"} = call(MemoryWrite, %{text: "  "}, ctx)
    assert {:error, reason} = call(MemoryWrite, %{text: "x", mode: "prepend"}, ctx)
    assert reason =~ "append or replace"
  end

  test "the memory is per agent", ctx do
    other = agent_fixture()
    other_session = session_fixture(%{channel: ctx.channel, agent_id: other.id})
    {:ok, _} = call(MemoryWrite, %{text: "mine"}, ctx)
    assert {:ok, text} = call(MemoryRead, %{}, other_session)
    assert text =~ "empty"
  end
end
