defmodule CanopyWeb.AgentsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.Agents
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  test "renders the empty state and the new-agent form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents")

    assert has_element?(view, "#agents-empty")
    assert has_element?(view, "#agent-form")
    # Without a repository there is nothing to ask OpenCode, so no datalist.
    refute has_element?(view, "#opencode-agents")
  end

  test "creates an agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents")

    view
    |> form("#agent-form",
      agent: %{
        name: "Backend",
        display_name: "Backend engineer",
        role: "Owns the Phoenix backend",
        system_prompt: "You are the backend engineer.",
        opencode_agent: "build",
        model_provider: "",
        model_id: ""
      }
    )
    |> render_submit()

    assert %{display_name: "Backend engineer", role: "Owns the Phoenix backend", model_id: nil} =
             agent = Agents.get_by_name("backend")

    assert has_element?(view, "#agent-#{agent.id}", "@backend")
    assert has_element?(view, "#sidebar-agent-#{agent.id}")
    refute has_element?(view, "#agents-empty")
  end

  test "shows validation errors inline", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents")

    view
    |> form("#agent-form", agent: %{name: "has spaces"})
    |> render_submit()

    assert has_element?(view, "#agent-form", "must be lowercase letters")
    assert Agents.list() == []
  end

  test "edits an existing agent", %{conn: conn} do
    agent = Fixtures.agent_fixture(%{name: "reviewer", role: "Reviews"})
    {:ok, view, _html} = live(conn, ~p"/agents")

    view |> element("#edit-agent-#{agent.id}") |> render_click()

    assert has_element?(view, "#agent-form-panel", "Edit @reviewer")
    assert has_element?(view, "#agent-form input[name='agent[name]'][value='reviewer']")

    view
    |> form("#agent-form",
      agent: %{
        role: "Reviews every diff",
        model_provider: "anthropic",
        model_id: "claude-sonnet-4"
      }
    )
    |> render_submit()

    assert %{role: "Reviews every diff", model_provider: "anthropic"} = Agents.get!(agent.id)
    assert has_element?(view, "#agent-#{agent.id}", "Reviews every diff")
    assert has_element?(view, "#agent-#{agent.id}", "anthropic/claude-sonnet-4")
    # Back to the create form afterwards.
    assert has_element?(view, "#agent-form-panel", "New agent")
  end

  test "cancel leaves edit mode", %{conn: conn} do
    agent = Fixtures.agent_fixture()
    {:ok, view, _html} = live(conn, ~p"/agents")

    view |> element("#edit-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "#cancel-edit")

    view |> element("#cancel-edit") |> render_click()
    refute has_element?(view, "#cancel-edit")
    assert has_element?(view, "#agent-form-panel", "New agent")
  end

  test "deactivates and reactivates an agent", %{conn: conn} do
    agent = Fixtures.agent_fixture(%{name: "sleepy"})
    {:ok, view, _html} = live(conn, ~p"/agents")

    view |> element("#deactivate-agent-#{agent.id}") |> render_click()

    refute Agents.get!(agent.id).active
    refute has_element?(view, "#active-agents #agent-#{agent.id}")
    refute has_element?(view, "#sidebar-agent-#{agent.id}")
    assert has_element?(view, "#toggle-inactive", "1 deactivated")

    view |> element("#toggle-inactive") |> render_click()
    assert has_element?(view, "#inactive-agents #agent-#{agent.id}", "@sleepy")

    view |> element("#reactivate-agent-#{agent.id}") |> render_click()

    assert Agents.get!(agent.id).active
    assert has_element?(view, "#active-agents #agent-#{agent.id}")
    assert has_element?(view, "#sidebar-agent-#{agent.id}")
  end

  test "fills the OpenCode agent datalist from the server when a repository exists", %{conn: conn} do
    repository = Fixtures.repository_fixture()

    stub(OC, :agents, fn dir, _opts ->
      assert dir == repository.path
      {:ok, [%{"name" => "plan"}, %{"name" => "build"}, %{"mode" => "no-name"}]}
    end)

    {:ok, view, _html} = live(conn, ~p"/agents")
    render_async(view)

    assert has_element?(view, "#opencode-agents option[value='build']")
    assert has_element?(view, "#opencode-agents option[value='plan']")

    assert has_element?(
             view,
             "#agent-form input[name='agent[opencode_agent]'][list='opencode-agents']"
           )
  end

  test "falls back to a plain input when the OpenCode server is unreachable", %{conn: conn} do
    Fixtures.repository_fixture()
    stub(OC, :agents, fn _dir, _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)

    {:ok, view, _html} = live(conn, ~p"/agents")
    render_async(view)

    refute has_element?(view, "#opencode-agents")
    assert has_element?(view, "#agent-form input[name='agent[opencode_agent]']")
  end
end
