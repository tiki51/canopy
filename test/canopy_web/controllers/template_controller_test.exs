defmodule CanopyWeb.TemplateControllerTest do
  use CanopyWeb.ConnCase, async: false

  alias Canopy.{Memory, Playbooks}
  alias Canopy.Fixtures
  alias Canopy.Templates.{AgentTemplate, Bundle}

  test "an agent downloads as <name>.md with strict headers", %{conn: conn} do
    agent = Fixtures.agent_fixture(%{name: "exported", system_prompt: "Exported prompt."})
    {:ok, _} = Memory.put(agent.id, "A private note.")

    conn = get(conn, ~p"/agents/#{agent.id}/export")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^attachment; filename="exported.md"; filename\*=UTF-8''exported.md$/
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert {:ok, template} = AgentTemplate.decode(conn.resp_body)
    assert template.system_prompt == "Exported prompt."
    refute conn.resp_body =~ "A private note."
  end

  test "memory comes only with memory=1", %{conn: conn} do
    agent = Fixtures.agent_fixture(%{name: "remembers"})
    {:ok, _} = Memory.put(agent.id, "A private note.")

    body = conn |> get(~p"/agents/#{agent.id}/export?memory=1") |> response(200)
    assert {:ok, %{memory: "A private note."}} = AgentTemplate.decode(body)
  end

  test "an unknown id is a 404", %{conn: conn} do
    assert conn |> get(~p"/agents/agt_nope/export") |> response(404)
    assert build_conn() |> get(~p"/teams/tm_nope/export") |> response(404)
    assert build_conn() |> get(~p"/playbooks/pb_nope/export") |> response(404)
    assert build_conn() |> get(~p"/agents/export?#{[ids: ["agt_nope"]]}") |> response(404)
  end

  test "selected agents download as one zip", %{conn: conn} do
    a = Fixtures.agent_fixture(%{name: "sel-a"})
    b = Fixtures.agent_fixture(%{name: "sel-b"})

    conn = get(conn, ~p"/agents/export?#{[ids: [a.id, b.id]]}")
    assert get_resp_header(conn, "content-type") == ["application/zip"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="canopy-agents.zip")
    assert {:ok, %{files: files}} = Bundle.read(conn.resp_body)
    assert Enum.map(files, &elem(&1, 0)) == ["agents/sel-a.md", "agents/sel-b.md"]
  end

  test "a team downloads with its members, and its playbooks when asked", %{conn: conn} do
    lead = Fixtures.agent_fixture(%{name: "t-lead"})
    team = Fixtures.team_fixture([lead], %{name: "exteam"})

    text =
      Playbooks.bug_fix_text()
      |> String.replace("name: bug-fix", "name: exteam-fix")
      |> String.replace("team: bugfix-team", "team: exteam")

    {:ok, playbook} = Playbooks.create(%{body: text})

    conn = get(conn, ~p"/teams/#{team.id}/export")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="exteam.canopy.zip")
    assert {:ok, %{files: files}} = Bundle.read(conn.resp_body)
    assert Enum.map(files, &elem(&1, 0)) == ["agents/t-lead.md", "teams/exteam.md"]

    body = build_conn() |> get(~p"/teams/#{team.id}/export?playbooks=1") |> response(200)
    assert {:ok, %{files: files}} = Bundle.read(body)
    assert {"playbooks/exteam-fix.md", ^text} = List.keyfind(files, "playbooks/exteam-fix.md", 0)

    conn = get(build_conn(), ~p"/playbooks/#{playbook.id}/export")
    assert conn.resp_body == text
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="exteam-fix.md")
  end
end
