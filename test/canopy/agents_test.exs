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

  describe "groups" do
    test "blank groups become nil, and grouped/1 sorts groups with the loose ones last" do
      a = agent_fixture(%{name: "zed", group: "Product"})
      b = agent_fixture(%{name: "amy", group: "engineering"})
      c = agent_fixture(%{name: "loose", group: "   "})
      assert c.group == nil

      assert Agents.groups() == ["Product", "engineering"]

      assert [{"engineering", [^b]}, {"Product", [^a]}, {nil, [^c]}] = Agents.grouped([a, b, c])
      assert [{nil, [^c]}] = Agents.grouped([c])
      assert Agents.grouped([]) == []
    end
  end

  describe "models and defaults" do
    alias Canopy.Settings

    test "a Claude Code agent may leave its model and effort blank, but a model must be an alias" do
      assert {:ok, agent} =
               Agents.create(%{name: "inherits", engine: "claude_code", model_id: nil})

      assert agent.model_id == nil and agent.effort == nil

      assert {:error, changeset} =
               Agents.create(%{name: "wrong", engine: "claude_code", model_id: "gpt-5-nano"})

      assert %{model_id: [message]} = errors_on(changeset)
      assert message =~ "fable, opus, sonnet, haiku"

      # Claude Code has no providers: a leftover one is dropped
      {:ok, agent} = Agents.update(agent, %{model_provider: "opencode", model_id: "sonnet"})
      assert %{model_provider: nil, model_id: "sonnet"} = agent
    end

    test "an OpenCode model names both its provider and its id, or neither" do
      assert {:error, changeset} = Agents.create(%{name: "half", model_provider: "opencode"})
      assert %{model_id: ["pick a model from opencode"]} = errors_on(changeset)

      assert {:error, changeset} = Agents.create(%{name: "other-half", model_id: "gpt-5-nano"})
      assert %{model_provider: ["pick a provider for this model"]} = errors_on(changeset)

      assert {:ok, _} = Agents.create(%{name: "neither"})
    end

    test "effective_model/1 is the agent's own, else the default from Settings, else the engine's" do
      oc = agent_fixture(%{name: "oc"})
      cc = agent_fixture(%{name: "cc", engine: "claude_code", model_id: nil, effort: nil})

      own =
        agent_fixture(%{name: "own", engine: "claude_code", model_id: "opus", effort: "max"})

      assert Agents.effective_model(oc) == %{model_provider: nil, model_id: nil, source: :engine}
      assert Agents.effective_model(cc) == %{model_provider: nil, model_id: nil, source: :engine}
      assert Agents.effective_effort(cc) == %{effort: nil, source: :engine}

      {:ok, _} =
        Settings.put_default_model("opencode", %{
          model_provider: "opencode",
          model_id: "gpt-5-nano"
        })

      {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "sonnet"})
      {:ok, _} = Settings.put_default_effort("claude_code", "high")

      assert Agents.effective_model(oc) ==
               %{model_provider: "opencode", model_id: "gpt-5-nano", source: :default}

      assert Agents.effective_model(cc) ==
               %{model_provider: nil, model_id: "sonnet", source: :default}

      assert Agents.effective_effort(cc) == %{effort: "high", source: :default}

      assert Agents.effective_model(own) ==
               %{model_provider: nil, model_id: "opus", source: :agent}

      assert Agents.effective_effort(own) == %{effort: "max", source: :agent}

      # OpenCode has no effort setting
      assert Agents.effective_effort(oc) == %{effort: nil, source: :engine}

      # the agent itself still says "inherit"
      assert Agents.get!(cc.id).model_id == nil
    end

    test "model_usage/1 counts active agents; inherit_default_model/1 clears only that engine" do
      oc_own =
        agent_fixture(%{name: "oc-own", model_provider: "opencode", model_id: "big-pickle"})

      _oc_default = agent_fixture(%{name: "oc-default"})
      cc_own = agent_fixture(%{name: "cc-own", engine: "claude_code", model_id: "opus"})
      _cc_default = agent_fixture(%{name: "cc-default", engine: "claude_code", model_id: nil})

      retired =
        agent_fixture(%{
          name: "retired",
          model_provider: "opencode",
          model_id: "x",
          active: false
        })

      assert Agents.model_usage("opencode") == %{default: 1, own: 1}
      assert Agents.model_usage("claude_code") == %{default: 1, own: 1}
      assert Agents.effort_usage("claude_code") == %{default: 0, own: 2}

      Settings.subscribe()
      assert {:ok, 1} = Agents.inherit_default_model("opencode")
      assert_receive {:settings, :default_models_changed}

      assert %{model_provider: nil, model_id: nil} = Agents.get!(oc_own.id)
      assert Agents.get!(cc_own.id).model_id == "opus"
      assert Agents.get!(retired.id).model_id == "x"
      assert Agents.model_usage("opencode") == %{default: 2, own: 0}

      # nothing left to move: no broadcast
      assert {:ok, 0} = Agents.inherit_default_model("opencode")
      refute_receive {:settings, :default_models_changed}, 50

      assert {:ok, 2} = Agents.inherit_default_effort("claude_code")
      assert Agents.get!(cc_own.id).effort == nil
      assert Agents.get!(cc_own.id).model_id == "opus"
    end

    test "move_to_engine/3 moves only the named agents still on the engine with no model" do
      bare = agent_fixture(%{name: "bare"})
      own = agent_fixture(%{name: "own", model_provider: "opencode", model_id: "big-pickle"})
      moved = agent_fixture(%{name: "moved", engine: "claude_code", model_id: nil})
      retired = agent_fixture(%{name: "retired", active: false})
      other = agent_fixture(%{name: "not-a-starter"})

      names = ["bare", "own", "moved", "retired"]
      assert Agents.movable_count(names, "opencode") == 1

      Settings.subscribe()
      assert {:ok, 1} = Agents.move_to_engine(names, "opencode", "claude_code")
      assert_receive {:settings, :default_models_changed}

      assert %{engine: "claude_code", model_id: nil, model_provider: nil} = Agents.get!(bare.id)
      assert Agents.get!(own.id).engine == "opencode"
      assert Agents.get!(moved.id).engine == "claude_code"
      assert Agents.get!(retired.id).engine == "opencode"
      assert Agents.get!(other.id).engine == "opencode"

      assert {:ok, 0} = Agents.move_to_engine(names, "opencode", "claude_code")
      refute_receive {:settings, :default_models_changed}, 50
    end
  end
end
