defmodule Canopy.Templates.AgentTemplateTest do
  use Canopy.DataCase, async: false

  alias Canopy.Agents.Agent
  alias Canopy.Fixtures
  alias Canopy.Templates
  alias Canopy.Templates.AgentTemplate

  @fields ~w(name display_name role group color system_prompt engine opencode_agent model_provider
             model_id permission_mode effort allowed_tools routing_enabled light_model_provider
             light_model_id light_effort)a

  # export → decode → attrs → changeset gives back the agent's own fields
  defp round_trip(agent) do
    text = AgentTemplate.encode(agent)
    assert {:ok, template} = AgentTemplate.decode(text)
    assert template.warnings == []
    {attrs, notices} = AgentTemplate.attrs(template, template.engine)
    assert notices == []
    changeset = Agent.changeset(%Agent{}, attrs)
    assert changeset.valid?, inspect(changeset.errors)
    {Map.take(Ecto.Changeset.apply_changes(changeset), @fields), text}
  end

  defp own(agent), do: Map.take(agent, @fields)

  describe "round trip" do
    test "model routing travels: routing, light model, light effort" do
      claude =
        Fixtures.agent_fixture(%{
          name: "router",
          engine: "claude_code",
          model_id: "sonnet",
          routing_enabled: true,
          light_model_id: "haiku",
          light_effort: "low",
          system_prompt: "Route."
        })

      {attrs, text} = round_trip(claude)
      assert attrs == own(claude)
      assert text =~ "routing: true"
      assert text =~ "light_model: haiku"
      assert text =~ "light_effort: low"

      opencode =
        Fixtures.agent_fixture(%{
          name: "oc-router",
          routing_enabled: true,
          light_model_provider: "opencode",
          light_model_id: "small",
          system_prompt: "Route."
        })

      {attrs, text} = round_trip(opencode)
      assert attrs == own(opencode)
      assert text =~ "light_model: opencode/small"
      refute text =~ "light_effort"
    end

    test "routing off is left out of the file" do
      agent = Fixtures.agent_fixture(%{name: "plain", system_prompt: "Plain."})
      refute AgentTemplate.encode(agent) =~ "routing"
      refute AgentTemplate.encode(agent) =~ "light_"
    end

    test "an OpenCode agent with a model of its own" do
      agent =
        Fixtures.agent_fixture(%{
          name: "builder",
          display_name: "Builder",
          role: "Builds: things, carefully",
          group: "Engineering",
          color: "#2563eb",
          system_prompt: "You are @builder.\n\n---\n\nYou build.",
          opencode_agent: "plan",
          model_provider: "openai",
          model_id: "gpt-5.4"
        })

      {attrs, text} = round_trip(agent)
      assert attrs == own(agent)
      assert text =~ ~s(color: "#2563eb")
      assert text =~ "model: openai/gpt-5.4"
      assert text =~ "mode: plan"
      refute text =~ "permission_mode"
    end

    test "an OpenCode agent inheriting the default model" do
      agent = Fixtures.agent_fixture(%{name: "inheritor", system_prompt: "Inherit."})
      {attrs, text} = round_trip(agent)
      assert attrs == own(agent)
      refute text =~ "model:"
    end

    test "a Claude Code agent with allowed tools" do
      agent =
        Fixtures.agent_fixture(%{
          name: "claudy",
          engine: "claude_code",
          model_id: "opus",
          effort: "high",
          permission_mode: "acceptEdits",
          allowed_tools: "Bash(git diff *)\nRead, Grep",
          system_prompt: "Careful."
        })

      {attrs, text} = round_trip(agent)
      assert %{attrs | allowed_tools: nil} == %{own(agent) | allowed_tools: nil}
      assert Agent.allowed_tools_list(attrs) == ["Bash(git diff *)", "Read", "Grep"]
      assert text =~ "allowed_tools:\n  - Bash(git diff *)\n  - Read\n  - Grep\n"
      assert text =~ "mode: build"
      refute text =~ "opencode_agent"
    end
  end

  describe "mode" do
    test "an export writes the engine-neutral mode" do
      plan = Fixtures.agent_fixture(%{engine: "claude_code", permission_mode: "plan"})
      assert AgentTemplate.encode(plan) =~ "mode: plan"
      build = Fixtures.agent_fixture(%{opencode_agent: "build"})
      assert AgentTemplate.encode(build) =~ "mode: build"
    end

    test "without the engine's own key, mode sets it on either engine" do
      {:ok, t} = decode("mode: plan")
      assert {%{opencode_agent: "plan"}, []} = AgentTemplate.attrs(t, "opencode")
      assert {%{permission_mode: "plan"}, []} = AgentTemplate.attrs(t, "claude_code")

      {:ok, t} = decode("mode: build")
      assert {%{opencode_agent: "build"}, []} = AgentTemplate.attrs(t, "opencode")
      assert {%{permission_mode: "default"}, []} = AgentTemplate.attrs(t, "claude_code")
    end

    test "keys for another engine are left out, with a notice" do
      {:ok, t} =
        decode(
          "engine: claude_code\nmode: plan\nmodel: opus\npermission_mode: plan\neffort: high"
        )

      {attrs, [notice]} = AgentTemplate.attrs(t, "opencode")
      assert %{opencode_agent: "plan", model_id: nil, effort: nil} = attrs
      assert notice =~ "permission_mode, effort, model opus don't apply to OpenCode"
    end
  end

  describe "memory" do
    test "is written only when asked for, and read back after the marker" do
      agent = Fixtures.agent_fixture(%{name: "rememberer", system_prompt: "Prompt."})
      refute AgentTemplate.encode(agent) =~ "canopy:memory"

      text = AgentTemplate.encode(agent, memory: "Knows the repo layout.")
      assert text =~ "memory: included"
      assert {:ok, t} = AgentTemplate.decode(text)
      assert t.system_prompt == "Prompt."
      assert t.memory == "Knows the repo layout."
    end

    test "the marker in a prompt without the flag is left alone" do
      {:ok, t} = decode("", "Before\n<!-- canopy:memory -->\nAfter")
      assert t.system_prompt == "Before\n<!-- canopy:memory -->\nAfter"
      assert t.memory == nil
    end
  end

  describe "file checks" do
    test "a newer canopy_template is refused, and so is a missing one" do
      assert {:error, [reason]} =
               AgentTemplate.decode("---\ncanopy_template: 2\nkind: agent\nname: x\n---\n")

      assert reason =~ "newer Canopy"

      assert {:error, [reason]} = AgentTemplate.decode("---\nkind: agent\nname: x\n---\n")
      assert reason =~ "canopy_template is missing"
    end

    test "an unknown key is a warning, not an error" do
      assert {:ok, %{warnings: [warning]}} = decode("future_setting: on")
      assert warning =~ "future_setting"
    end

    test "field types are checked" do
      assert {:error, reasons} = decode("role: 42\nallowed_tools: Bash\nmode: edit")
      assert "role must be text" in reasons
      assert "allowed_tools must be a list of text" in reasons
      assert "mode must be plan or build" in reasons
    end

    test "the 256 KB cap holds" do
      big = String.duplicate("x", AgentTemplate.max_bytes())
      assert {:error, [reason]} = decode("", big)
      assert reason =~ "too long"
    end

    test "seed is a gallery-only key" do
      assert {:ok, %{warnings: [_]}} = decode("seed: true")
      assert {:ok, %{seed: true, warnings: []}} = decode("seed: true", "", gallery: true)
    end
  end

  describe "Claude Code subagent files" do
    test "are read with the description as the role, and tools left out" do
      text = """
      ---
      name: code-reviewer
      description: #{String.duplicate("Reviews code. ", 20)}
      tools: Read, Grep
      model: inherit
      ---

      You review code.
      """

      assert {:ok, :agent, t} = Templates.decode(text)
      assert t.format == :claude_code
      assert t.engine == "claude_code"
      assert t.model == nil
      assert String.length(t.role) == 200
      assert Enum.any?(t.warnings, &(&1 =~ "cut to 200"))
      assert Enum.any?(t.warnings, &(&1 =~ "tools was left out"))

      {attrs, []} = AgentTemplate.attrs(t, "claude_code")
      assert Agent.changeset(%Agent{}, attrs).valid?
      assert attrs.system_prompt == "You review code."
    end

    test "a model alias becomes the Claude Code model" do
      text = "---\nname: quick\ndescription: Fast\nmodel: haiku\n---\nGo."
      assert {:ok, :agent, %{model: "haiku"} = t} = Templates.decode(text)
      assert {%{model_id: "haiku"}, []} = AgentTemplate.attrs(t, "claude_code")
    end
  end

  defp decode(frontmatter, body \\ "Prompt.", opts \\ []) do
    "---\ncanopy_template: 1\nkind: agent\nname: sample\n#{frontmatter}\n---\n#{body}"
    |> AgentTemplate.decode(opts)
  end
end
