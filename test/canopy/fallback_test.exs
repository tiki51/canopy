defmodule Canopy.FallbackTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Agents, EnginePauses, Fallback, Settings}

  @limit %{kind: "usage", reason: "usage limit", resets_at: nil, detail: "x"}

  describe "parse/1 and label/1" do
    test "engine and model; OpenCode also a provider; the model may hold more of either" do
      assert Fallback.parse("claude_code:sonnet") ==
               %{engine: "claude_code", provider: nil, model: "sonnet"}

      assert Fallback.parse("codex:gpt-5-codex") ==
               %{engine: "codex", provider: nil, model: "gpt-5-codex"}

      assert Fallback.parse("opencode:anthropic/claude-sonnet-4-5") ==
               %{engine: "opencode", provider: "anthropic", model: "claude-sonnet-4-5"}

      assert Fallback.parse("opencode:openrouter/meta/llama:free") ==
               %{engine: "opencode", provider: "openrouter", model: "meta/llama:free"}

      assert Fallback.parse("none") == :none
      assert Fallback.parse(nil) == nil
      assert Fallback.parse("sonnet") == nil
      assert Fallback.parse("opencode:gpt-5") == nil
      assert Fallback.parse(":x") == nil
    end

    test "encode/1 round-trips" do
      for v <- ["claude_code:sonnet", "opencode:anthropic/claude-sonnet-4-5"],
          do: assert(v |> Fallback.parse() |> Fallback.encode() == v)
    end

    test "labels" do
      assert Fallback.label(Fallback.parse("codex:gpt-5-codex")) == "Codex › gpt-5-codex"

      assert Fallback.label(Fallback.parse("opencode:anthropic/claude-sonnet-4")) ==
               "OpenCode › anthropic/claude-sonnet-4"
    end

    test "same_plan?/2 is the same engine" do
      assert Fallback.same_plan?("claude_code", Fallback.parse("claude_code:sonnet"))
      refute Fallback.same_plan?("claude_code", Fallback.parse("codex:gpt-5"))
    end
  end

  describe "validation" do
    test "Settings takes a known engine and model, OpenCode with a provider" do
      assert {:ok, s} =
               Settings.update(%{claude_fallback: "opencode:anthropic/claude-sonnet-4-5"})

      assert s.claude_fallback == "opencode:anthropic/claude-sonnet-4-5"
      assert {:ok, %{claude_fallback: nil}} = Settings.update(%{claude_fallback: " "})
      assert {:error, cs} = Settings.update(%{codex_fallback: "opencode:gpt-5"})
      assert %{codex_fallback: [_]} = errors_on(cs)
      assert {:error, cs} = Settings.update(%{opencode_fallback: "nope:model"})
      assert %{opencode_fallback: [_]} = errors_on(cs)
      assert {:error, _} = Settings.update(%{opencode_fallback: "none"})
    end

    test "an agent also takes none, and blank is the default" do
      agent = agent_fixture()
      assert {:ok, %{fallback: "none"}} = Agents.update(agent, %{fallback: "none"})
      assert {:ok, %{fallback: nil}} = Agents.update(agent, %{fallback: ""})
      assert {:error, cs} = Agents.update(agent, %{fallback: "sonnet"})
      assert %{fallback: [_]} = errors_on(cs)
    end
  end

  describe "resolve/1" do
    test "the agent's own, else its engine's Settings default; none is nil" do
      {:ok, _} = Settings.update(%{claude_fallback: "codex:gpt-5-codex"})
      agent = agent_fixture(%{engine: "claude_code"})

      assert Fallback.resolve(agent) == Fallback.parse("codex:gpt-5-codex")
      assert Fallback.default_for("claude_code") == Fallback.parse("codex:gpt-5-codex")
      assert Fallback.default_for("opencode") == nil

      {:ok, own} = Agents.update(agent, %{fallback: "opencode:anthropic/claude-sonnet-4-5"})
      assert Fallback.resolve(own).engine == "opencode"

      {:ok, none} = Agents.update(agent, %{fallback: "none"})
      assert Fallback.resolve(none) == nil
    end

    test "an agent on the default engine follows that engine's default" do
      {:ok, _} = Settings.update(%{default_engine: "opencode", opencode_fallback: "codex:gpt-5"})
      assert Fallback.resolve(agent_fixture()).engine == "codex"
    end
  end

  describe "route/1" do
    test "primary while the engine runs" do
      agent = agent_fixture(%{engine: "claude_code", fallback: "codex:gpt-5"})
      assert Fallback.route(agent) == {:primary, "claude_code"}
    end

    test "fallback while it's paused and the fallback's engine is available and not paused" do
      agent = agent_fixture(%{engine: "claude_code", fallback: "codex:gpt-5"})
      {:ok, _} = EnginePauses.engage("claude_code", @limit)
      assert Fallback.route(agent) == {:fallback, Fallback.parse("codex:gpt-5")}
      assert Fallback.unavailable_label(agent) == nil

      {:ok, _} = EnginePauses.engage("codex", @limit)
      assert {:wait, %{engine: "claude_code"}} = Fallback.route(agent)
      assert Fallback.unavailable_label(agent) == "Codex › gpt-5"
    end

    test "wait with no fallback, none, or one on the same engine" do
      {:ok, _} = EnginePauses.engage("claude_code", @limit)

      for fallback <- [nil, "none", "claude_code:sonnet"] do
        agent = agent_fixture(%{engine: "claude_code", fallback: fallback})
        assert {:wait, %{engine: "claude_code"}} = Fallback.route(agent)
      end

      same = agent_fixture(%{engine: "claude_code", fallback: "claude_code:sonnet"})
      assert Fallback.unavailable_label(same) == "Claude Code › sonnet"
    end

    test "wait when the fallback's engine isn't available" do
      {:ok, _} = Settings.update(%{codex_binary: "/nonexistent/codex"})
      previous = Application.get_env(:canopy, :codex)
      Application.put_env(:canopy, :codex, Keyword.delete(previous, :binary))
      on_exit(fn -> Application.put_env(:canopy, :codex, previous) end)

      refute Canopy.Engine.available?("codex")
      agent = agent_fixture(%{engine: "claude_code", fallback: "codex:gpt-5"})
      {:ok, _} = EnginePauses.engage("claude_code", @limit)
      assert {:wait, _} = Fallback.route(agent)
    end
  end

  test "available?/1: binaries on PATH, OpenCode's URL, unknown engines" do
    assert Canopy.Engine.available?("claude_code")
    assert Canopy.Engine.available?("codex")
    assert Canopy.Engine.available?("opencode")
    refute Canopy.Engine.available?("nope")
  end

  test "marker/1: a fallback session's messages name the engine, model and the engine it stands in for" do
    agent = agent_fixture(%{engine: "claude_code", fallback: "codex:gpt-5-codex"})

    assert Fallback.marker(%{fallback_of: "claude_code", engine: "codex", agent_id: agent.id}) ==
             %{"engine" => "codex", "model" => "gpt-5-codex", "from_engine" => "claude_code"}

    assert Fallback.marker(%{fallback_of: nil, engine: "claude_code"}) == nil
  end
end
