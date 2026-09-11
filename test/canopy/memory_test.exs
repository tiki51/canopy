defmodule Canopy.MemoryTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Memory

  test "get, put, append, size cap, and the prompt form" do
    agent = agent_fixture()
    Memory.subscribe()

    assert Memory.get(agent.id) == ""
    assert Memory.updated_at(agent.id) == nil
    assert Memory.for_prompt(agent.id) =~ "empty so far"

    assert {:ok, _} =
             Memory.append(
               agent.id,
               "## 2026-09-10\n- The billing worker lives in payments.py.\n"
             )

    assert Memory.get(agent.id) == "## 2026-09-10\n- The billing worker lives in payments.py."
    assert_receive {:memory, :changed, id}
    assert id == agent.id
    assert %DateTime{} = Memory.updated_at(agent.id)

    assert {:ok, body} = Memory.append(agent.id, "- Steven prefers small PRs.")
    assert body =~ "payments.py.\n\n- Steven prefers small PRs."
    assert Memory.for_prompt(agent.id) =~ "Your memory across repositories"
    assert Memory.for_prompt(agent.id) =~ "small PRs"

    assert {:ok, "fresh"} = Memory.put(agent.id, "fresh\n\n")

    assert {:error, :too_large} =
             Memory.put(agent.id, String.duplicate("x", Memory.max_bytes() + 1))

    assert Memory.get(agent.id) == "fresh"

    long = String.duplicate("a line of memory\n", 1_000)
    {:ok, _} = Memory.put(agent.id, long)
    prompt = Memory.for_prompt(agent.id)
    assert String.length(prompt) < Memory.inline_chars() + 200
    assert prompt =~ "memory continues; read all of it with canopy_memory_read"
  end
end
