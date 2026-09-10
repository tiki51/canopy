defmodule CanopyWeb.AgentsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.Agents
  alias Canopy.Fixtures
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  @providers %{
    "providers" => [
      %{
        "id" => "opencode",
        "name" => "OpenCode Zen",
        "models" => %{"claude-haiku-4-5" => %{}, "gpt-5-nano" => %{}}
      },
      %{"id" => "openai", "name" => "OpenAI", "models" => %{"gpt-5.4" => %{}}}
    ],
    "default" => %{}
  }

  setup do
    stub(OC, :providers, fn _opts -> {:ok, @providers} end)
    :ok
  end

  test "renders the empty state and the new-agent form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents")

    assert has_element?(view, "#agents-empty")
    assert has_element?(view, "#agent-form")
    # Without a repository there is nothing to ask OpenCode, so no datalist.
    refute has_element?(view, "#opencode-agents")
  end

  test "/agents/:id selects the agent: highlighted row, Message and Edit, sidebar mark", %{
    conn: conn
  } do
    agent = Fixtures.agent_fixture(%{name: "picked#{Fixtures.unique_suffix()}"})
    other = Fixtures.agent_fixture()

    {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
    assert page_title(view) =~ "@" <> agent.name
    assert has_element?(view, "#agent-#{agent.id}[data-selected]")
    refute has_element?(view, "#agent-#{other.id}[data-selected]")
    assert has_element?(view, "#message-agent-#{agent.id}[href='/dm/#{agent.id}']", "Message")
    assert has_element?(view, "#edit-agent-#{agent.id}", "Edit")
    assert has_element?(view, "#sidebar-agent-#{agent.id}[data-active]")
    refute has_element?(view, "#sidebar-agent-#{other.id}[data-active]")

    # Edit from the selected row loads it into the form
    view |> element("#edit-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "#agent-form input[name='agent[name]'][value='#{agent.name}']")

    # an unknown id falls back to the list
    assert {:error, {:live_redirect, %{to: "/agents"}}} = live(conn, ~p"/agents/agt_nope")
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
        opencode_agent: "build"
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

    # picking a provider enables the model select, as in the browser
    view |> form("#agent-form", agent: %{model_provider: "opencode"}) |> render_change()

    view
    |> form("#agent-form",
      agent: %{
        role: "Reviews every diff",
        model_provider: "opencode",
        model_id: "gpt-5-nano"
      }
    )
    |> render_submit()

    assert %{role: "Reviews every diff", model_provider: "opencode"} = Agents.get!(agent.id)
    assert has_element?(view, "#agent-#{agent.id}", "Reviews every diff")
    assert has_element?(view, "#agent-#{agent.id}", "opencode/gpt-5-nano")
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

  describe "model override" do
    test "offers providers and models from OpenCode and validates the pair", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")
      render_async(view)

      assert has_element?(
               view,
               "#agent-form select[name='agent[model_provider]'] option[value='opencode']"
             )

      assert has_element?(
               view,
               "#agent-form select[name='agent[model_provider]'] option[value='openai']"
             )

      # picking a provider fills the model list
      html =
        view
        |> form("#agent-form",
          agent: %{name: "picky", display_name: "Picky", model_provider: "opencode"}
        )
        |> render_change()

      assert html =~ "claude-haiku-4-5"
      assert html =~ "gpt-5-nano"
      refute html =~ "gpt-5.4</option>"

      # saving with a provider but no model is refused
      html =
        view
        |> form("#agent-form",
          agent: %{name: "picky", display_name: "Picky", model_provider: "opencode", model_id: ""}
        )
        |> render_submit()

      assert html =~ "pick a model from opencode"
      assert Agents.get_by_name("picky") == nil

      # a valid pair saves
      view
      |> form("#agent-form",
        agent: %{
          name: "picky",
          display_name: "Picky",
          model_provider: "opencode",
          model_id: "gpt-5-nano"
        }
      )
      |> render_submit()

      assert %{model_provider: "opencode", model_id: "gpt-5-nano"} = Agents.get_by_name("picky")
    end

    test "an existing override for an unconfigured provider is shown and flagged", %{conn: conn} do
      agent =
        Fixtures.agent_fixture(%{
          name: "legacy",
          model_provider: "anthropic",
          model_id: "claude-sonnet-4-5"
        })

      {:ok, view, _html} = live(conn, ~p"/agents")
      render_async(view)

      view |> element("#edit-agent-#{agent.id}") |> render_click()
      html = render(view)
      assert html =~ "anthropic (not configured)"

      html =
        view
        |> form("#agent-form",
          agent: %{model_provider: "anthropic", model_id: "claude-sonnet-4-5"}
        )
        |> render_submit()

      assert html =~ "is not configured in OpenCode"
      assert Agents.get!(agent.id).model_provider == "anthropic"
    end

    test "falls back to text inputs when the provider list is unavailable", %{conn: conn} do
      stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
      {:ok, view, _html} = live(conn, ~p"/agents")
      render_async(view)

      assert has_element?(view, "#agent-form input[name='agent[model_provider]']")
      assert has_element?(view, "#agent-form input[name='agent[model_id]']")
    end
  end
end
