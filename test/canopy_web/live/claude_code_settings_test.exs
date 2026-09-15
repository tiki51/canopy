defmodule CanopyWeb.ClaudeCodeSettingsTest do
  @moduledoc "The Claude Code branch of the agent form and the Claude Code settings panel."
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.DataCase, only: [errors_on: 1]

  alias Canopy.{Agents, Fixtures, Settings}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(OC, :providers, fn _opts -> {:ok, %{"providers" => [], "default" => %{}}} end)
    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
    :ok
  end

  describe "the agent form" do
    test "switching the engine to Claude Code swaps the OpenCode fields for its own", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/agents/new")

      assert has_element?(view, "#opencode-agents")
      refute has_element?(view, "#claude-permission-mode")

      view |> form("#agent-form", agent: %{engine: "claude_code"}) |> render_change()

      assert has_element?(view, "#claude-model")
      assert has_element?(view, "#claude-effort")
      assert has_element?(view, "#claude-permission-mode")
      assert has_element?(view, "#claude-allowed-tools")
      refute has_element?(view, "#opencode-agents")
    end

    test "creates a Claude Code agent with model, effort, permissions, and tools", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/new")
      view |> form("#agent-form", agent: %{engine: "claude_code"}) |> render_change()

      # the model and effort are selects, and nothing is saved until all three are chosen
      assert has_element?(view, "select#claude-model option[value='fable']")
      assert has_element?(view, "select#claude-effort option[value='xhigh']")

      view
      |> form("#agent-form",
        agent: %{name: "coder", display_name: "Coder", engine: "claude_code"}
      )
      |> render_submit()

      assert has_element?(view, "#agent-form", "can't be blank")
      refute Agents.get_by_name("coder")

      view
      |> form("#agent-form",
        agent: %{
          name: "coder",
          display_name: "Coder",
          role: "Writes code",
          engine: "claude_code",
          model_id: "haiku",
          effort: "low",
          permission_mode: "acceptEdits",
          allowed_tools: "Read\nBash(git *)"
        }
      )
      |> render_submit()

      agent = Agents.get_by_name("coder")
      assert agent.engine == "claude_code"
      assert agent.model_id == "haiku"
      assert agent.effort == "low"
      assert agent.permission_mode == "acceptEdits"
      assert Agents.Agent.allowed_tools_list(agent) == ["Read", "Bash(git *)"]

      # no provider is needed for a Claude Code model, and the page names the engine
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-engine", "Claude Code")
      assert render(view) =~ "acceptEdits · effort low"
      refute has_element?(view, "#agent-model-price")
    end

    test "the list shows the engine badge and no model picker for Claude Code agents", %{
      conn: conn
    } do
      agent =
        Fixtures.agent_fixture(%{
          name: "listed-claude",
          engine: "claude_code",
          model_id: "sonnet"
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, "span#model-#{agent.id}", "sonnet")
      refute has_element?(view, "button#model-#{agent.id}")
      assert has_element?(view, "[title='Claude Code · default']", "claude")
    end

    test "rejects a permission mode Canopy does not offer" do
      assert {:error, changeset} =
               Agents.create(%{
                 name: "bypass",
                 engine: "claude_code",
                 permission_mode: "bypassPermissions"
               })

      assert %{permission_mode: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} =
               Agents.create(%{name: "eff", engine: "claude_code", effort: "ultra"})

      assert %{effort: ["is invalid"]} = errors_on(changeset)

      # all three Claude Code settings are required, and the model must be an alias
      assert {:error, changeset} =
               Agents.create(%{
                 name: "blank",
                 engine: "claude_code",
                 effort: "",
                 allowed_tools: " "
               })

      assert %{model_id: ["can't be blank"], effort: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Agents.create(%{
                 name: "full-id",
                 engine: "claude_code",
                 model_id: "claude-opus-5",
                 effort: "high"
               })

      assert %{model_id: [message]} = errors_on(changeset)
      assert message =~ "fable, opus, sonnet, haiku"

      assert {:ok, agent} =
               Agents.create(%{
                 name: "ok",
                 engine: "claude_code",
                 model_id: "opus",
                 effort: "max",
                 allowed_tools: " "
               })

      assert agent.allowed_tools == nil

      # OpenCode agents are untouched by the rule
      assert {:ok, _} = Agents.create(%{name: "oc", engine: "opencode"})
    end
  end

  describe "the settings panel" do
    test "shows the current values and saves them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "#claude-panel")

      assert has_element?(
               view,
               "#claude-form input[name='setting[claude_binary]'][value='claude']"
             )

      view
      |> form("#claude-form",
        setting: %{
          claude_binary: "/opt/bin/claude",
          claude_config_dir: "/srv/agents",
          claude_max_budget_usd: "2.5"
        }
      )
      |> render_submit()

      setting = Settings.get()
      assert setting.claude_binary == "/opt/bin/claude"
      assert setting.claude_config_dir == "/srv/agents"
      assert setting.claude_max_budget_usd == 2.5

      view
      |> form("#claude-form", setting: %{claude_config_dir: "", claude_max_budget_usd: ""})
      |> render_submit()

      assert Settings.get().claude_config_dir == nil
      assert Settings.get().claude_max_budget_usd == nil
    end

    test "keeps the binary on a blank submit and rejects a non-positive cap", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      # a blank binary is ignored: the stored name stays
      view |> form("#claude-form", setting: %{claude_binary: " "}) |> render_submit()
      assert Settings.get().claude_binary == "claude"

      view
      |> form("#claude-form", setting: %{claude_binary: "claude", claude_max_budget_usd: "0"})
      |> render_submit()

      assert has_element?(view, "#claude-form", "must be greater than 0")
    end

    test "the check runs the binary in the form and reports version and login", %{conn: conn} do
      fake = Path.expand("../../support/fake_claude.sh", __DIR__)
      {:ok, view, _html} = live(conn, ~p"/settings")

      config_dir = Path.join(System.tmp_dir!(), "canopy-claude-check")

      view
      |> form("#claude-form", setting: %{claude_binary: fake, claude_config_dir: config_dir})
      |> render_change()

      view |> element("#check-claude") |> render_click()
      render_async(view)

      assert has_element?(view, "#claude-check-result", "9.9.9")
      assert has_element?(view, "#claude-check-result", "logged in (max) as fake@example.com")
    end

    test "the check reports a missing binary", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#claude-form", setting: %{claude_binary: "no-such-claude-binary"})
      |> render_change()

      view |> element("#check-claude") |> render_click()
      render_async(view)
      assert has_element?(view, "#claude-check-result", "not found on PATH")
    end
  end
end
