defmodule Canopy.SeedsTest do
  use Canopy.DataCase, async: false

  import ExUnit.CaptureIO

  alias Canopy.{Agents, Repo, Seeds, Settings}
  alias Canopy.Settings.Setting
  alias Canopy.Users.User

  test "run/0 creates missing defaults and preserves existing records" do
    capture_io(&Seeds.run/0)

    assert Enum.map(Agents.list(), & &1.name) == [
             "auditor",
             "backend",
             "designer",
             "devops",
             "docs",
             "frontend",
             "fullstack",
             "product-manager",
             "project-manager",
             "researcher",
             "reviewer",
             "test"
           ]

    backend = Agents.get_by_name("backend")
    assert {:ok, _} = Agents.update(backend, %{role: "Customized role"})
    assert {:ok, custom_auditor} = Agents.create(%{name: "custom-auditor"})
    assert {:ok, _} = Canopy.Costs.Auditor.assign(custom_auditor.id)

    capture_io(&Seeds.run/0)

    assert Agents.get_by_name("backend").role == "Customized role"
    assert Settings.get().auditor_agent_id == custom_auditor.id
    assert Repo.aggregate(Setting, :count) == 1
    assert Repo.aggregate(User, :count) == 1
  end
end
