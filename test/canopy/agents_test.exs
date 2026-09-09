defmodule Canopy.AgentsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Agents

  test "create/1 normalizes and validates the slug" do
    assert {:ok, agent} = Agents.create(%{name: "@Backend", role: "Builds features"})
    assert agent.name == "backend"
    assert agent.display_name == "backend"
    assert agent.opencode_agent == "build"
    assert agent.active

    assert {:error, changeset} = Agents.create(%{name: "backend"})
    assert %{name: ["has already been taken"]} = errors_on(changeset)

    assert {:error, changeset} = Agents.create(%{name: "has space"})
    assert %{name: [_]} = errors_on(changeset)
  end

  test "get_by_name/1, list_active/0, update/2, deactivate/1" do
    agent = agent_fixture(%{name: "reviewer"})
    assert Agents.get_by_name("@reviewer").id == agent.id
    assert Agents.get_by_name("missing") == nil

    assert {:ok, agent} = Agents.update(agent, %{model_provider: "anthropic", model_id: "x"})
    assert agent.model_id == "x"

    assert {:ok, agent} = Agents.deactivate(agent)
    refute agent.active
    assert Agents.list_active() == []
    assert Enum.map(Agents.list(), & &1.id) == [agent.id]
  end
end
