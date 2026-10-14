defmodule Canopy.SeedsTest do
  use Canopy.DataCase, async: false

  import ExUnit.CaptureIO

  import Canopy.Fixtures

  alias Canopy.{Agents, Repo, Seeds, Settings}
  alias Canopy.Settings.Setting
  alias Canopy.Users.User

  test "run/0 creates missing defaults and preserves existing records" do
    assert {:ok, report} = Seeds.run()

    assert report.created ==
             Enum.map(Seeds.agent_names(), &%{kind: :agent, name: &1}) ++
               [
                 %{kind: :team, name: "bugfix-team"},
                 %{kind: :playbook, name: "bug-fix"},
                 %{kind: :playbook, name: "feature-build"}
               ]

    assert report.existing == []
    assert report.skipped == []
    assert report.cost_auditor == {:assigned, "finops"}
    assert report.settings == %{opencode_url: Settings.get().opencode_url}
    assert %{id: _, display_name: _} = report.user

    assert Enum.map(Agents.list(), & &1.name) == [
             "backend",
             "copywriter",
             "designer",
             "devops",
             "docs",
             "finops",
             "frontend",
             "fullstack",
             "product-manager",
             "project-manager",
             "researcher",
             "reviewer",
             "test"
           ]

    assert Enum.sort(Seeds.agent_names()) == Enum.map(Agents.list(), & &1.name)

    # no engine or model of their own: they follow the defaults from Settings
    assert Enum.all?(Agents.list(), &(is_nil(&1.engine) and is_nil(&1.model_id)))

    # a `plan` starter is read-only whichever engine is the default
    pm = Agents.get_by_name("product-manager")
    assert {pm.opencode_agent, pm.permission_mode} == {"plan", "plan"}
    assert Canopy.Agents.Agent.execution_mode(pm) == :plan
    {:ok, setting} = Settings.put_default_engine("claude_code")
    assert Agents.effective_engine(pm, setting) == "claude_code"
    assert Canopy.Agents.Agent.execution_mode(pm) == :plan
    {:ok, _} = Settings.put_default_engine(nil)

    backend = Agents.get_by_name("backend")
    assert {backend.opencode_agent, backend.permission_mode} == {"build", "default"}

    # agents take locks themselves; the project manager never brokers them
    assert Agents.get_by_name("project-manager").system_prompt =~ "Don't assign\nor pass locks"

    # the starter playbooks, with the project manager told how to run one
    assert %{source: "seed", enabled: true} = Canopy.Playbooks.get_by_name("bug-fix")
    assert %{source: "seed", enabled: true} = Canopy.Playbooks.get_by_name("feature-build")
    assert Agents.get_by_name("project-manager").system_prompt =~ "canopy_playbook_start"

    team = Canopy.Teams.get_by_name("bugfix-team")
    assert team.lead.name == "backend"
    assert Enum.map(team.members, & &1.name) == ~w(backend frontend reviewer test)
    assert {:ok, _} = Canopy.Teams.update(team, %{description: "Ours now"})

    backend = Agents.get_by_name("backend")
    assert {:ok, _} = Agents.update(backend, %{role: "Customized role"})
    assert {:ok, custom_auditor} = Agents.create(%{name: "custom-auditor"})
    assert {:ok, _} = Canopy.Costs.Auditor.assign(custom_auditor.id)

    assert {:ok, report} = Seeds.run()
    assert report.created == []
    assert length(report.existing) == length(Seeds.agent_names()) + 3
    assert report.cost_auditor == {:unchanged, "custom-auditor"}

    assert Agents.get_by_name("backend").role == "Customized role"
    assert Canopy.Teams.get_by_name("bugfix-team").description == "Ours now"
    assert length(Canopy.Teams.list()) == 1
    assert length(Canopy.Playbooks.list()) == 2
    assert Settings.get().auditor_agent_id == custom_auditor.id
    assert Repo.aggregate(Setting, :count) == 1
    assert Repo.aggregate(User, :count) == 1
  end

  test "print/1 writes the lines the release smoke test and the Homebrew formula match" do
    output = capture_io(fn -> Seeds.print(Seeds.run()) end)
    user = Canopy.Users.local()

    assert output =~ "settings: opencode_url=#{Settings.get().opencode_url}\n"
    assert output =~ "user: #{user.display_name} (#{user.id})\n"
    # scripts/smoke-release.sh:34 and Formula/canopy.rb:163
    assert output =~ "created agent @backend\n"
    assert output =~ "created team @bugfix-team\n"
    assert output =~ "created playbook bug-fix\n"
    assert output =~ "created playbook feature-build\n"
    assert output =~ "assigned @finops as the cost auditor\n"

    # agents in starter order, then the team, then the playbooks
    lines = String.split(output, "\n", trim: true)
    agent_lines = Enum.filter(lines, &String.starts_with?(&1, "created agent @"))
    assert agent_lines == Enum.map(Seeds.agent_names(), &"created agent @#{&1}")
    assert List.last(lines) == "assigned @finops as the cost auditor"

    output = capture_io(fn -> Seeds.print(Seeds.run()) end)
    # scripts/smoke-release.sh:40 and Formula/canopy.rb:165
    assert output =~ "agent @backend already exists\n"
    assert output =~ "team @bugfix-team already exists\n"
    assert output =~ "playbook bug-fix already exists\n"
    assert output =~ "playbook feature-build already exists\n"
    refute output =~ "cost auditor"
  end

  test "print/1 keeps the playbooks in seed order when only some are new" do
    {:ok, _} = Canopy.Playbooks.create(%{body: Canopy.Playbooks.bug_fix_text(), source: "seed"})

    lines =
      capture_io(fn -> Seeds.print(Seeds.run()) end)
      |> String.split("\n", trim: true)
      |> Enum.filter(&(&1 =~ "playbook"))

    assert lines == ["playbook bug-fix already exists", "created playbook feature-build"]
  end

  describe "a failure" do
    # a team holding a starter agent's name makes that agent's insert fail
    setup do
      team_fixture([agent_fixture()], %{name: "designer"})
      :ok
    end

    test "run/0 keeps what it created and returns it as the partial report" do
      assert {:error, reason, partial} = Seeds.run()
      assert reason =~ "agent @designer"

      before = Enum.take_while(Seeds.agent_names(), &(&1 != "designer"))
      assert before != []
      assert partial.created == Enum.map(before, &%{kind: :agent, name: &1})
      assert partial.cost_auditor == nil
      assert partial.settings && partial.user
      assert Enum.all?(before, &Agents.get_by_name/1)
    end

    test "run_cli!/0 prints what it did and the reason, then raises" do
      output =
        capture_io(fn ->
          assert_raise Seeds.Error, ~r/^seeder stopped: agent @designer/, &Seeds.run_cli!/0
        end)

      assert output =~ "created agent @#{hd(Seeds.agent_names())}\n"
      assert output =~ "seeder stopped: agent @designer"
    end
  end
end
