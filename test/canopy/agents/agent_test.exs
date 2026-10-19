defmodule Canopy.Agents.AgentTest do
  # registers Codex in the global `:engines` config
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Agents, Settings}
  alias Canopy.Agents.Agent

  setup do
    engines = Application.get_env(:canopy, :engines)
    Application.put_env(:canopy, :engines, Map.put_new(engines, "codex", Canopy.Engine.Codex))
    on_exit(fn -> Application.put_env(:canopy, :engines, engines) end)
    :ok
  end

  describe "efforts/1" do
    test "Claude Code's levels; Codex adds ultra; other engines as before" do
      assert Agent.efforts("claude_code") == ~w(low medium high xhigh max)
      assert Agent.efforts("codex") == ~w(low medium high xhigh max ultra)
      assert Agent.efforts("opencode") == Agent.efforts()
      assert Agent.efforts() == Agent.efforts("claude_code")
    end

    test "the changeset checks the effort against the agent's engine" do
      assert {:ok, cx} = Agents.create(%{name: "cx", engine: "codex", effort: "ultra"})
      assert cx.effort == "ultra"

      assert {:ok, cx} = Agents.update(cx, %{light_effort: "ultra"})
      assert cx.light_effort == "ultra"

      assert {:error, cs} = Agents.create(%{name: "cc", engine: "claude_code", effort: "ultra"})
      assert %{effort: ["is invalid"]} = errors_on(cs)

      assert {:error, cs} = Agents.update(cx, %{effort: "minimal"})
      assert %{effort: ["is invalid"]} = errors_on(cs)
    end

    test "an effort left from another engine is dropped on save, and passed over until then" do
      {:ok, _} = Settings.put_default_engine("codex")
      follower = agent_fixture(%{name: "follower", effort: "ultra", light_effort: "ultra"})
      assert Agents.effective_effort(follower) == %{effort: "ultra", source: :agent}

      {:ok, _} = Settings.put_default_engine("claude_code")
      {:ok, _} = Settings.put_default_effort("claude_code", "high")
      # passed over, not cleared
      assert Agents.effective_effort(follower) == %{effort: "high", source: :default}
      assert Agents.get!(follower.id).effort == "ultra"

      # an unrelated edit drops it instead of refusing the save
      assert {:ok, saved} = Agents.update(follower, %{role: "Renamed"})
      assert %{effort: nil, light_effort: nil, role: "Renamed"} = saved

      # a Codex agent moved to Claude Code by hand loses it the same way
      cx = agent_fixture(%{name: "cx", engine: "codex", effort: "ultra"})

      assert {:ok, %{engine: "claude_code", effort: nil}} =
               Agents.update(cx, %{engine: "claude_code"})

      # an effort both engines know stays
      shared = agent_fixture(%{name: "shared", engine: "codex", effort: "high"})
      assert {:ok, %{effort: "high"}} = Agents.update(shared, %{engine: "claude_code"})
    end
  end

  describe "Codex models" do
    test "any model id but a Claude Code alias, never with a provider" do
      assert {:ok, cx} = Agents.create(%{name: "cx", engine: "codex", model_id: "gpt-6.1-sol"})
      assert %{model_provider: nil, model_id: "gpt-6.1-sol"} = cx

      assert {:ok, %{model_id: nil}} = Agents.create(%{name: "inherits", engine: "codex"})

      assert {:error, cs} = Agents.create(%{name: "alias", engine: "codex", model_id: "opus"})
      assert %{model_id: ["is a Claude Code model; pick a Codex model"]} = errors_on(cs)

      # Codex has no providers: a leftover one is dropped
      assert {:ok, cx} =
               Agents.update(cx, %{
                 model_provider: "openai",
                 model_id: "gpt-6-luna",
                 light_model_provider: "openai",
                 light_model_id: "gpt-5.6-terra"
               })

      assert %{model_provider: nil, model_id: "gpt-6-luna"} = cx
      assert %{light_model_provider: nil, light_model_id: "gpt-5.6-terra"} = cx

      assert {:error, cs} = Agents.update(cx, %{light_model_id: "haiku"})
      assert %{light_model_id: [_]} = errors_on(cs)
    end

    test "model_errors/3" do
      assert Agent.model_errors("codex", nil, nil) == []
      assert Agent.model_errors("codex", nil, "gpt-6.1-sol") == []
      assert Agent.model_errors("codex", "ignored", "gpt-6.1-sol") == []
      assert [model_id: _] = Agent.model_errors("codex", nil, "sonnet")
    end

    test "allowed_tools is accepted and ignored for Codex" do
      assert {:ok, cx} = Agents.create(%{name: "cx", engine: "codex", allowed_tools: "Read"})
      assert cx.allowed_tools == "Read"
    end
  end

  describe "model_fits?/3" do
    test "Codex runs any bare model id but a Claude Code alias" do
      assert Agent.model_fits?("codex", nil, "gpt-6.1-sol")
      refute Agent.model_fits?("codex", nil, "opus")
      # a provider/model pair is OpenCode's
      refute Agent.model_fits?("codex", "openai", "gpt-6.1-sol")
      assert Agent.model_fits?("codex", nil, nil)
    end

    test "Claude Code runs only its aliases" do
      assert Agent.model_fits?("claude_code", nil, "opus")
      refute Agent.model_fits?("claude_code", nil, "gpt-6.1-sol")
    end

    test "OpenCode runs only a model with its provider" do
      assert Agent.model_fits?("opencode", "openai", "gpt-5.4")
      # a bare id is a Claude Code or Codex model (or a half-filled old row):
      # OpenCode can't route it
      refute Agent.model_fits?("opencode", nil, "gpt-6.1-sol")
      refute Agent.model_fits?("opencode", nil, "sonnet")
      assert Agent.model_fits?("opencode", nil, nil)
    end

    test "a Codex model left on an agent that follows the default is passed over on OpenCode" do
      {:ok, _} = Settings.put_default_engine("codex")
      follower = agent_fixture(%{name: "follower", model_id: "gpt-6.1-sol"})
      assert Agents.effective_model(follower).source == :agent

      {:ok, _} = Settings.put_default_engine("opencode")

      assert Agents.effective_model(follower) ==
               %{model_provider: nil, model_id: nil, source: :engine}

      assert {:ok, %{model_id: nil}} = Agents.update(follower, %{role: "Other"})
    end
  end

  describe "execution_mode/1" do
    test "Codex reads the permission mode, as Claude Code does" do
      assert Agent.execution_mode(%{engine: "codex", permission_mode: "plan"}) == :plan
      assert Agent.execution_mode(%{engine: "codex", permission_mode: "default"}) == :build
      assert Agent.execution_mode(%{engine: "codex", permission_mode: "acceptEdits"}) == :build
      # OpenCode's field means nothing to Codex
      assert Agent.execution_mode(%{engine: "codex", opencode_agent: "plan"}) == :build
    end

    test "an agent on a Codex default keeps its reach through the mirrored fields" do
      {:ok, _} = Settings.put_default_engine("codex")
      follower = agent_fixture(%{name: "follower", opencode_agent: "plan"})
      assert follower.permission_mode == "plan"
      assert Agent.execution_mode(follower) == :plan
    end
  end
end
