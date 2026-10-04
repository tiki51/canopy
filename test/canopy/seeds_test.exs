defmodule Canopy.SeedsTest do
  use Canopy.DataCase, async: false

  import ExUnit.CaptureIO

  alias Canopy.{Agents, Repo, Seeds, Settings}
  alias Canopy.Settings.Setting
  alias Canopy.Users.User

  test "run/0 creates missing defaults and preserves existing records" do
    capture_io(&Seeds.run/0)

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

    # the starter playbook, with the project manager told how to run one
    assert %{source: "seed", enabled: true} = Canopy.Playbooks.get_by_name("bug-fix")
    assert Agents.get_by_name("project-manager").system_prompt =~ "canopy_playbook_start"

    team = Canopy.Teams.get_by_name("bugfix-team")
    assert team.lead.name == "backend"
    assert Enum.map(team.members, & &1.name) == ~w(backend frontend reviewer test)
    assert {:ok, _} = Canopy.Teams.update(team, %{description: "Ours now"})

    backend = Agents.get_by_name("backend")
    assert {:ok, _} = Agents.update(backend, %{role: "Customized role"})
    assert {:ok, custom_auditor} = Agents.create(%{name: "custom-auditor"})
    assert {:ok, _} = Canopy.Costs.Auditor.assign(custom_auditor.id)

    capture_io(&Seeds.run/0)

    assert Agents.get_by_name("backend").role == "Customized role"
    assert Canopy.Teams.get_by_name("bugfix-team").description == "Ours now"
    assert length(Canopy.Teams.list()) == 1
    assert length(Canopy.Playbooks.list()) == 1
    assert Settings.get().auditor_agent_id == custom_auditor.id
    assert Repo.aggregate(Setting, :count) == 1
    assert Repo.aggregate(User, :count) == 1
  end
end
