defmodule Canopy.Templates.ImportTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Agents, Channels, Memory, Playbooks, Schedules, Teams}
  alias Canopy.Agents.Agent
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Templates.{AgentTemplate, Import, Machine}
  alias Canopy.Templates.Import.{Item, Plan}

  setup :verify_on_exit!

  @providers [%{id: "openai", name: "OpenAI", models: ["gpt-5.4"], pricing: %{}}]

  # Both engines ready, OpenCode offering one model and the built-in agents.
  defp machine(overrides \\ []) do
    struct(
      %Machine{claude_code: true, opencode: {:ok, @providers}, opencode_agents: ~w(build plan)},
      overrides
    )
  end

  defp template(name, extra \\ "", body \\ "You are the agent.") do
    "---\ncanopy_template: 1\nkind: agent\nname: #{name}\n#{extra}\n---\n#{body}\n"
  end

  defp plan(text, opts \\ []) do
    Import.plan([{:file, "agent.md", text}], Keyword.put_new(opts, :machine, machine()))
  end

  defp item(%Plan{items: [item]}), do: item
  defp item(%Plan{items: items}, name), do: Enum.find(items, &(&1.name == name))

  defp counts do
    for schema <- [Agent, Canopy.Teams.Team, Canopy.Playbooks.Playbook, Canopy.Memory.AgentMemory],
        do: Repo.aggregate(schema, :count)
  end

  describe "plan/2" do
    test "writes nothing" do
      Fixtures.agent_fixture(%{name: "taken"})
      before = counts()

      plan =
        Import.plan(
          [
            {:file, "a.md",
             template("fresh", "memory: included", "Hi\n\n<!-- canopy:memory -->\n\nKnows.")},
            {:file, "b.md", template("taken")}
          ],
          machine: machine()
        )

      assert length(plan.items) == 2
      assert counts() == before
    end

    test "statuses: new, conflict, identical, invalid" do
      same = Fixtures.agent_fixture(%{name: "same", system_prompt: "You are the agent."})
      Fixtures.agent_fixture(%{name: "differs", role: nil, system_prompt: "Something else."})

      assert %Item{status: :new, choice: %{action: :create}} = item(plan(template("brand-new")))

      conflict = item(plan(template("differs")))
      assert %Item{status: :conflict, choice: %{action: :rename, name: "differs-2"}} = conflict
      assert [{:system_prompt, "Something else.", "You are the agent."}] = conflict.diff
      assert conflict.prompt_diff == [del: ["Something else."], ins: ["You are the agent."]]

      identical = item(plan(AgentTemplate.encode(same)))
      assert %Item{status: :identical, choice: %{action: :skip}} = identical

      invalid = item(plan(template("Bad Name!")))
      assert %Item{status: :invalid, choice: %{action: :skip}} = invalid
      assert Enum.any?(invalid.errors, &(&1 =~ "name: must be lowercase"))
    end

    test "a template can't grant bypass permissions" do
      text = template("bypasser", "engine: claude_code\npermission_mode: bypassPermissions")
      assert %Item{status: :invalid, errors: errors} = item(plan(text))
      assert Enum.any?(errors, &(&1 =~ "permission_mode"))
      refute Plan.ready?(plan(text))
    end

    test "the permission line turns risky for acceptEdits and broad patterns" do
      calm = item(plan(template("calm", "engine: claude_code\npermission_mode: plan")))

      assert %{risky: false, text: "Claude Code · plan · no extra tools approved"} =
               calm.permission

      bold =
        item(plan(template("bold", "engine: claude_code\nallowed_tools:\n  - Bash(*)")))

      assert %{risky: true} = bold.permission
      assert bold.permission.text =~ "runs without asking: Bash(*)"
    end

    test "rename suggestions are free, unique, and at most 40 characters" do
      long = String.duplicate("a", 40)
      Fixtures.agent_fixture(%{name: long})
      Fixtures.agent_fixture(%{name: String.duplicate("a", 38) <> "-2"})

      Fixtures.team_fixture([Fixtures.agent_fixture()], %{name: String.duplicate("a", 38) <> "-3"})

      %Item{choice: %{name: name}} = item(plan(template(long)))
      assert name == String.duplicate("a", 38) <> "-4"
      assert String.length(name) <= 40

      # two conflicting items in one import get different names
      Fixtures.agent_fixture(%{name: "twin"})

      plan =
        Import.plan(
          [{:file, "a.md", template("twin")}, {:file, "b.md", template("twin", "role: other")}],
          machine: machine()
        )

      [a, b] = plan.items
      assert a.choice.name != b.choice.name
      assert Enum.all?(plan.items, &(&1.errors == []))
    end

    test "a typed rename is checked" do
      Fixtures.agent_fixture(%{name: "busy"})
      Fixtures.agent_fixture(%{name: "also-busy"})
      plan = plan(template("busy"))
      id = item(plan).id

      plan = Import.choose(plan, %{id => %{"action" => "rename", "name" => "also-busy"}})
      assert ["also-busy is already taken here"] = item(plan).errors

      plan = Import.choose(plan, %{id => %{"name" => "Not OK"}})
      assert [error] = item(plan).errors
      assert error =~ "lowercase"

      plan = Import.choose(plan, %{id => %{"name" => "@Free-Name"}})
      assert %Item{errors: [], choice: %{name: "free-name"}} = item(plan)
    end
  end

  describe "apply/2" do
    test "creates new agents with their memory, and summarises" do
      text =
        template(
          "fresh",
          "memory: included",
          "Prompt.\n\n<!-- canopy:memory -->\n\nKnows things."
        )

      assert {:ok, summary} = Import.apply(plan(text))
      assert Import.summary_text(summary) == "Imported @fresh."

      agent = Agents.get_by_name("fresh")
      assert agent.system_prompt == "Prompt."
      assert Memory.get(agent.id) == "Knows things."
    end

    test "memory can be left out of a new agent" do
      text = template("forgetful", "memory: included", "P.\n<!-- canopy:memory -->\nSecret.")
      plan = plan(text)
      assert {:ok, _} = Import.apply(plan, %{item(plan).id => %{"memory" => "skip"}})
      assert Memory.get(Agents.get_by_name("forgetful").id) == ""
    end

    test "rename creates a second agent and leaves the first alone" do
      original = Fixtures.agent_fixture(%{name: "dup", system_prompt: "Original."})
      assert {:ok, summary} = Import.apply(plan(template("dup")))
      assert Import.summary_text(summary) == "Imported @dup-2."
      assert Agents.get!(original.id).system_prompt == "Original."
      assert Agents.get_by_name("dup-2").system_prompt == "You are the agent."
    end

    test "replace keeps the id, channels, schedules, and memory unless memory is chosen" do
      %{agent: agent, channel: channel} = Fixtures.scenario()

      {:ok, schedule} =
        Schedules.create(%{
          channel_id: channel.id,
          agent_id: agent.id,
          instruction: "Ping.",
          when: "1h"
        })

      {:ok, _} = Memory.put(agent.id, "Old memory.")

      text =
        template(
          agent.name,
          "role: Replaced role\nmemory: included",
          "New prompt.\n<!-- canopy:memory -->\nNew memory."
        )

      plan = plan(text)
      id = item(plan).id
      assert %Item{status: :conflict} = item(plan)

      assert {:ok, summary} = Import.apply(plan, %{id => %{"action" => "replace"}})
      assert Import.summary_text(summary) == "Replaced @#{agent.name}."

      replaced = Agents.get!(agent.id)
      assert replaced.role == "Replaced role"
      assert replaced.system_prompt == "New prompt."
      assert Enum.any?(Channels.members(channel), &(&1.id == agent.id))
      assert Schedules.get(schedule.id).agent_id == agent.id
      assert Memory.get(agent.id) == "Old memory."

      # choosing to append the memory
      plan =
        plan(template(agent.name, "memory: included", "Again.\n<!-- canopy:memory -->\nMore."))

      assert {:ok, _} =
               Import.apply(plan, %{
                 item(plan).id => %{"action" => "replace", "memory" => "append"}
               })

      assert Memory.get(agent.id) == "Old memory.\n\nMore."
    end

    test "replace keeps a deactivated agent deactivated, with a notice" do
      agent = Fixtures.agent_fixture(%{name: "sleeper", active: false})
      plan = plan(template("sleeper"))
      assert Enum.any?(item(plan).notices, &(&1 =~ "deactivated"))
      assert {:ok, _} = Import.apply(plan, %{item(plan).id => %{"action" => "replace"}})
      refute Agents.get!(agent.id).active
    end

    test "skip writes nothing for that item" do
      Fixtures.agent_fixture(%{name: "skipme", system_prompt: "Mine."})
      before = counts()
      plan = plan(template("skipme"))
      assert {:error, :invalid} = Import.apply(plan, %{item(plan).id => %{"action" => "skip"}})
      assert counts() == before
    end

    test "all or nothing: when one item can't be written, none is" do
      plan =
        Import.plan(
          [{:file, "a.md", template("good-one")}, {:file, "b.md", template("late-clash")}],
          machine: machine()
        )

      assert Plan.ready?(plan)
      Fixtures.agent_fixture(%{name: "late-clash"})
      before = counts()
      assert {:error, :stale} = Import.apply(plan)
      assert counts() == before
      refute Agents.get_by_name("good-one")
    end

    test "an invalid item is skipped, and can't be written" do
      plan =
        Import.plan(
          [{:file, "a.md", template("good-one")}, {:file, "b.md", template("bad one!")}],
          machine: machine()
        )

      bad = item(plan, "bad one!")
      assert bad.choice.action == :skip
      plan = Import.choose(plan, %{bad.id => %{"action" => "create"}})
      assert item(plan, "bad one!").choice.action == :skip
      assert {:ok, summary} = Import.apply(plan)
      assert Import.summary_text(summary) == "Imported @good-one; skipped @bad one!."
    end

    test "returns :stale when the name was taken after the preview" do
      plan = plan(template("racer"))
      Fixtures.agent_fixture(%{name: "racer"})
      assert {:error, :stale} = Import.apply(plan)
      assert [%{name: "racer"}] = Enum.filter(Agents.list(), &(&1.name == "racer"))
    end
  end

  describe "machine fallbacks" do
    test "an engine this Canopy doesn't know becomes the engine for new agents" do
      text = template("futurist", "engine: codex\nmode: plan\nmodel: gpt-9")
      item = item(plan(text))
      assert %{engine: "opencode", opencode_agent: "plan", model_id: nil} = item.attrs
      assert Enum.any?(item.notices, &(&1 =~ "engine codex isn't supported here; using OpenCode"))
      assert item.errors == []
    end

    test "with OpenCode away and Claude Code installed, new agents go to Claude Code" do
      item =
        item(
          plan(template("roamer", "mode: plan"),
            machine: machine(opencode: {:error, :econnrefused})
          )
        )

      assert %{engine: "claude_code", permission_mode: "plan"} = item.attrs
    end

    test "a Claude model alias this Canopy doesn't offer inherits the default" do
      item = item(plan(template("old-model", "engine: claude_code\nmodel: claude-2")))
      assert item.attrs.model_id == nil
      assert Enum.any?(item.notices, &(&1 =~ "isn't a Claude Code model here"))
      assert item.errors == []
    end

    test "an OpenCode model missing from the live list inherits the default" do
      item = item(plan(template("picky", "engine: opencode\nmodel: anthropic/claude-x")))
      assert %{model_provider: nil, model_id: nil} = item.attrs
      assert Enum.any?(item.notices, &(&1 =~ "anthropic/claude-x isn't available"))

      kept = item(plan(template("happy", "engine: opencode\nmodel: openai/gpt-5.4")))
      assert %{model_provider: "openai", model_id: "gpt-5.4"} = kept.attrs
    end

    test "with OpenCode unreachable, the model is kept with a notice" do
      text = template("hopeful", "engine: opencode\nmodel: anthropic/claude-x")

      item =
        item(
          plan(text, machine: machine(opencode: {:error, :econnrefused}, opencode_agents: nil))
        )

      assert %{model_provider: "anthropic", model_id: "claude-x"} = item.attrs
      assert Enum.any?(item.notices, &(&1 =~ "couldn't check model anthropic/claude-x"))
      assert Enum.any?(item.notices, &(&1 =~ "OpenCode isn't reachable"))
    end

    test "an OpenCode agent this machine doesn't define falls back to plan" do
      item = item(plan(template("custom", "engine: opencode\nopencode_agent: reviewer-bot")))
      assert item.attrs.opencode_agent == "plan"
      assert Enum.any?(item.notices, &(&1 =~ "reviewer-bot isn't defined here; using plan"))
    end

    test "Claude Code not installed keeps the engine, with a notice, and the engine can be switched" do
      plan =
        plan(template("needs-claude", "engine: claude_code\nmode: plan"),
          machine: machine(claude_code: false)
        )

      item = item(plan)
      assert item.attrs.engine == "claude_code"
      assert Enum.any?(item.notices, &(&1 =~ "Claude Code isn't installed"))

      plan = Import.choose(plan, %{item.id => %{"engine" => "opencode"}})
      assert %{engine: "opencode", opencode_agent: "plan"} = item(plan).attrs
    end

    test "probe/0 asks OpenCode for its models and agents" do
      repository = Fixtures.repository_fixture()

      expect(OC, :providers, fn _opts ->
        {:ok, %{"providers" => [%{"id" => "openai", "models" => %{"gpt-5.4" => %{}}}]}}
      end)

      expect(OC, :agents, fn dir, _opts ->
        assert dir == repository.path

        {:ok,
         [
           %{"name" => "build"},
           %{"name" => "docs-bot", "mode" => "primary"},
           %{"name" => "title", "hidden" => true}
         ]}
      end)

      machine = Machine.probe()
      assert {:ok, [%{id: "openai", models: ["gpt-5.4"]}]} = machine.opencode
      assert Enum.sort(machine.opencode_agents) == ~w(build docs-bot plan)
      assert machine.claude_code
    end
  end

  describe "playbooks and Claude Code files on their own" do
    test "a playbook file imports enabled, as the user's, verbatim" do
      text = String.replace(Playbooks.bug_fix_text(), "name: bug-fix", "name: my-fix")
      plan = Import.plan([{:file, "my-fix.md", text}], machine: machine())
      assert %Item{kind: :playbook, status: :new} = item(plan)
      assert {:ok, _} = Import.apply(plan)
      assert %{enabled: true, source: "user", body: ^text} = Playbooks.get_by_name("my-fix")
    end

    test "a Claude Code subagent file imports as a Claude Code agent" do
      text = "---\nname: helper\ndescription: Helps out\nmodel: sonnet\n---\nHelp."
      plan = Import.plan([{:text, text}], machine: machine())
      assert {:ok, _} = Import.apply(plan)

      assert %{engine: "claude_code", model_id: "sonnet", role: "Helps out"} =
               Agents.get_by_name("helper")
    end

    test "a team file names agents already here" do
      backend = Fixtures.agent_fixture(%{name: "be"})
      Fixtures.agent_fixture(%{name: "qa"})

      text = """
      ---
      canopy_template: 1
      kind: team
      name: crew
      lead: be
      members:
        - name: be
        - name: qa
          role: test
      ---
      """

      plan = Import.plan([{:file, "crew.md", text}], machine: machine())
      assert Plan.ready?(plan)
      assert {:ok, _} = Import.apply(plan)
      team = Teams.get_by_name("crew")
      assert team.lead_agent_id == backend.id
      assert Map.values(Teams.member_roles(team)) == ["test"]
    end
  end
end
