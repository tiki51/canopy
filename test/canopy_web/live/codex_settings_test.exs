defmodule CanopyWeb.CodexSettingsTest do
  @moduledoc """
  Codex in Settings, first-run setup and the agent form: the panel and its
  check, the model and effort lists from `test/support/fake_codex.sh`, the
  third engine card, and the Codex fields of an agent.
  """
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Agents, Fixtures, Settings}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  @models %{
    "data" => [
      %{
        "model" => "gpt-5-codex",
        "displayName" => "GPT-5 Codex",
        "supportedReasoningEfforts" => [
          %{"reasoningEffort" => "low"},
          %{"reasoningEffort" => "medium"},
          %{"reasoningEffort" => "high"},
          %{"reasoningEffort" => "xhigh"}
        ],
        "defaultReasoningEffort" => "medium",
        "isDefault" => true
      },
      %{
        "model" => "gpt-5-codex-mini",
        "displayName" => "GPT-5 Codex Mini",
        "supportedReasoningEfforts" => [
          %{"reasoningEffort" => "low"},
          %{"reasoningEffort" => "medium"}
        ],
        "defaultReasoningEffort" => "low",
        "isDefault" => false
      }
    ],
    "nextCursor" => nil
  }

  setup do
    stub(OC, :providers, fn _opts -> {:ok, %{"providers" => [], "default" => %{}}} end)
    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
    stub(OC, :health, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    path = Path.join(System.tmp_dir!(), "codex-models-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(@models))
    put_env("FAKE_CODEX_MODELS", path)
    on_exit(fn -> File.rm(path) end)
    %{models_path: path}
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp option_values(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> List.first()))
  end

  # The form starts on the saved binary ("codex"); tests run the fake.
  defp check(view) do
    view
    |> form("#codex-form", setting: %{codex_binary: Canopy.Engine.Codex.binary_name()})
    |> render_change()

    view |> element("#check-codex") |> render_click()
    # the check, then the model list it starts
    render_async(view, 5_000)
    render_async(view, 5_000)
  end

  defp position(html, id), do: :binary.match(html, ~s(id="#{id}")) |> elem(0)

  describe "Settings" do
    test "the panels run Claude Code, Codex, OpenCode, and so do the default engine cards", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert position(html, "claude-panel") < position(html, "codex-panel")
      assert position(html, "codex-panel") < position(html, "opencode-panel")

      cards =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#default-engine-choice [role=radio]")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert cards == ~w(default-engine-choice-claude_code default-engine-choice-codex
                         default-engine-choice-opencode)

      # found on PATH, not checked on mount
      assert has_element?(view, ~s(#default-engine-choice-codex[data-ready="installed"]))
    end

    test "Check Codex: signed in with ChatGPT (Pro), and the card reads Ready", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      check(view)

      assert has_element?(view, "#codex-check-result", "signed in with ChatGPT (Pro)")
      assert has_element?(view, ~s(#default-engine-choice-codex[data-ready="ready"]), "Ready")
    end

    test "Check Codex with an API key", %{conn: conn} do
      put_env("FAKE_CODEX_ACCOUNT", "api_key")
      {:ok, view, _html} = live(conn, ~p"/settings")

      check(view)

      assert has_element?(view, "#codex-check-result", "signed in with an API key")
    end

    test "Check Codex signed out: run codex login, and the card says Not signed in", %{
      conn: conn
    } do
      put_env("FAKE_CODEX_ACCOUNT", "none")
      {:ok, view, _html} = live(conn, ~p"/settings")

      check(view)

      assert has_element?(view, "#codex-check-result", "not signed in: run")
      assert has_element?(view, "#codex-check-result code", "codex login")

      assert has_element?(
               view,
               ~s(#default-engine-choice-codex [title="Run codex login in a terminal"]),
               "Not signed in"
             )
    end

    test "Check Codex: not found, blank, and too old", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#codex-form", setting: %{codex_binary: "/no/such/codex"})
      |> render_change()

      view |> element("#check-codex") |> render_click()
      render_async(view, 5_000)
      assert has_element?(view, "#codex-check-result .text-error")
      assert has_element?(view, "#default-engine-choice-codex", "Not found")

      view |> form("#codex-form", setting: %{codex_binary: ""}) |> render_change()
      view |> element("#check-codex") |> render_click()
      assert has_element?(view, "#codex-check-result", "enter the binary first")
      assert has_element?(view, "#default-engine-choice-codex", "Not set")

      # a copy of its own: versions are cached per binary
      old = Path.join(System.tmp_dir!(), "old-codex-#{System.unique_integer([:positive])}")
      File.cp!(Canopy.Engine.Codex.binary_name(), old)
      File.chmod!(old, 0o755)
      on_exit(fn -> File.rm(old) end)
      put_env("FAKE_CODEX_VERSION", "0.150.0")

      view |> form("#codex-form", setting: %{codex_binary: old}) |> render_change()

      view |> element("#check-codex") |> render_click()
      render_async(view, 5_000)
      assert has_element?(view, "#codex-check-result", "older than")
      assert has_element?(view, "#default-engine-choice-codex", "Check failed")
    end

    test "Check Codex lists the models of the binary it checked, not the saved one", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 5_000)
      refute has_element?(view, "#codex-models-unavailable")

      view
      |> form("#codex-form", setting: %{codex_binary: "/no/such/codex"})
      |> render_change()

      view |> element("#check-codex") |> render_click()
      render_async(view, 5_000)
      render_async(view, 5_000)

      assert has_element?(view, "#codex-models-unavailable", "/no/such/codex")
    end

    test "the model lists come from Codex, and the efforts follow the model", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 5_000)

      assert option_values(view, "#codex-default-model") == [
               "",
               "gpt-5-codex",
               "gpt-5-codex-mini"
             ]

      # no model chosen: Codex's own default model's efforts and default
      assert option_values(view, "#codex-default-effort") == [
               "",
               "low",
               "medium",
               "high",
               "xhigh"
             ]

      assert has_element?(view, "#codex-default-effort option[value='']", "Default (medium)")

      view
      |> form("#codex-form", setting: %{codex_default_model: "gpt-5-codex-mini"})
      |> render_change()

      assert option_values(view, "#codex-default-effort") == ["", "low", "medium"]
      assert has_element?(view, "#codex-light-model option[value='']", "No light model")
    end

    test "an effort the model doesn't offer is an error, and Save refuses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 5_000)

      view
      |> form("#codex-form",
        setting: %{codex_default_model: "gpt-5-codex", codex_default_effort: "xhigh"}
      )
      |> render_change()

      view
      |> form("#codex-form", setting: %{codex_default_model: "gpt-5-codex-mini"})
      |> render_change()

      assert has_element?(view, "#codex-form", "gpt-5-codex-mini doesn't offer xhigh")
      # still selectable, so the select doesn't silently submit something else
      assert "xhigh" in option_values(view, "#codex-default-effort")

      view |> form("#codex-form") |> render_submit()
      assert Settings.get().codex_default_model == nil
    end

    test "saving a default model says how many agents use it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 5_000)

      view
      |> form("#codex-form", setting: %{codex_default_model: "gpt-5-codex-mini"})
      |> render_submit()

      assert render(view) =~ "Saved."
      assert Settings.get().codex_default_model == "gpt-5-codex-mini"
      assert has_element?(view, "#codex-model-usage")
      assert has_element?(view, "#codex-effort-usage")
    end

    test "a model list that fails keeps the saved value and says why", %{conn: conn} do
      {:ok, _} = Settings.update(%{"codex_default_model" => "gpt-5-codex"})
      put_env("FAKE_CODEX_MODELS", "fail")
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_async(view, 5_000)

      assert has_element?(view, "#codex-models-unavailable", "Couldn't read Codex's models")
      assert has_element?(view, "#codex-default-model[disabled]")
      assert option_values(view, "#codex-default-model") == ["", "gpt-5-codex"]
    end

    test "Use the default for all clears Codex agents' own model", %{conn: conn} do
      %{agent: agent} = Fixtures.scenario()
      {:ok, _} = Agents.update(agent, %{engine: "codex", model_id: "gpt-5-codex"})

      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#codex-model-usage-inherit") |> render_click()

      assert render(view) =~ "1 Codex agent now uses the default model."
      assert Agents.get!(agent.id).model_id == nil
    end
  end

  describe "the agent form" do
    setup do
      %{agent: agent} = Fixtures.scenario()
      {:ok, agent} = Agents.update(agent, %{engine: "codex", permission_mode: "default"})
      %{agent: agent}
    end

    test "the engine select runs Default, Claude Code, Codex, OpenCode", %{
      conn: conn,
      agent: agent
    } do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert option_values(view, "#agent-engine-select") == [
               "",
               "claude_code",
               "codex",
               "opencode"
             ]
    end

    test "the page header follows the engine select before saving", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert has_element?(view, "header p", "Codex's own instructions still apply.")

      for {engine, text} <- [
            {"opencode", "OpenCode's own agent prompt still applies."},
            {"claude_code", "Claude Code's own system prompt still applies."}
          ] do
        view |> form("#agent-form", agent: %{engine: engine}) |> render_change()
        assert has_element?(view, "header p", text)
        refute has_element?(view, "header p", "Codex's own")
      end
    end

    test "on Default, the page header uses the default engine's line", %{conn: conn, agent: agent} do
      {:ok, _} = Settings.put_default_engine("codex")
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")

      view |> form("#agent-form", agent: %{engine: "opencode"}) |> render_change()
      view |> form("#agent-form", agent: %{engine: ""}) |> render_change()
      assert has_element?(view, "header p", "Codex's own instructions still apply.")
    end

    test "a Codex agent gets Model, Effort and Permissions, and nothing OpenCode's or Claude's",
         %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view, 5_000)

      assert option_values(view, "#codex-model") == ["", "gpt-5-codex", "gpt-5-codex-mini"]
      assert has_element?(view, "#codex-model option[value='']", "Codex's own default")
      assert option_values(view, "#codex-permission-mode") == ["default", "acceptEdits", "plan"]
      assert has_element?(view, "#codex-permission-mode", "Ask only outside the sandbox")

      assert has_element?(
               view,
               "#codex-permissions-help",
               "reads; a command outside the sandbox asks, once at a time"
             )

      refute has_element?(view, "#opencode-agents")
      refute has_element?(view, "#claude-allowed-tools")
      refute has_element?(view, "#claude-model")
      refute render(view) =~ "OpenCode agent"
      assert has_element?(view, "#codex-light-model")
    end

    test "the effort follows the model, own or default", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view, 5_000)

      assert option_values(view, "#codex-effort") == ["", "low", "medium", "high", "xhigh"]

      view |> form("#agent-form", agent: %{model_id: "gpt-5-codex-mini"}) |> render_change()
      assert option_values(view, "#codex-effort") == ["", "low", "medium"]
    end

    test "with no model list, Effort offers Codex's efforts, not Claude Code's", %{
      conn: conn,
      agent: agent
    } do
      put_env("FAKE_CODEX_MODELS", "fail")
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view, 5_000)

      codex = ["" | Canopy.Agents.Agent.efforts("codex")]
      assert "ultra" in codex
      assert option_values(view, "#codex-effort") == codex
      refute has_element?(view, "#codex-effort[disabled]")
      assert option_values(view, "#codex-light-effort") == codex

      view |> form("#agent-form", agent: %{effort: "ultra"}) |> render_submit()
      assert Agents.get!(agent.id).effort == "ultra"
    end

    test "a failed model list stays put while editing, until try again", %{
      conn: conn,
      agent: agent,
      models_path: models_path
    } do
      put_env("FAKE_CODEX_MODELS", "fail")
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view, 5_000)
      assert has_element?(view, "#codex-models-unavailable")

      # Codex is now fine, but a keystroke doesn't ask it again
      System.put_env("FAKE_CODEX_MODELS", models_path)
      view |> form("#agent-form", agent: %{role: "Writes code"}) |> render_change()
      render_async(view, 5_000)
      assert has_element?(view, "#codex-models-unavailable")
      refute has_element?(view, "#codex-effort[disabled]")

      view |> element("#codex-models-retry") |> render_click()
      render_async(view, 5_000)
      refute has_element?(view, "#codex-models-unavailable")
      assert option_values(view, "#codex-model") == ["", "gpt-5-codex", "gpt-5-codex-mini"]
    end

    test "saving stores the model and permission mode", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      render_async(view, 5_000)

      view
      |> form("#agent-form",
        agent: %{model_id: "gpt-5-codex", effort: "high", permission_mode: "plan"}
      )
      |> render_submit()

      agent = Agents.get!(agent.id)

      assert {agent.model_id, agent.effort, agent.permission_mode} ==
               {"gpt-5-codex", "high", "plan"}
    end

    test "the list reads Codex · ask first, and About gives the permission's name", %{
      conn: conn,
      agent: agent
    } do
      {:ok, view, _html} = live(conn, ~p"/agents")
      assert has_element?(view, "#engine-#{agent.id}", "Codex")
      assert has_element?(view, "#engine-#{agent.id}", "· ask first")
      refute has_element?(view, "#engine-#{agent.id}", "build")

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#agent-permissions", "ask first")
      refute render(view) =~ "OpenCode agent"
    end

    test "the model picker has a Codex section, and an empty state when Codex is away", %{
      conn: conn,
      agent: agent
    } do
      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element("#model-#{agent.id}") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#model-picker-codex", "GPT-5 Codex Mini")
      assert has_element?(view, "#model-option-default", "Whatever Codex is set to use")

      put_env("FAKE_CODEX_MODELS", "fail")
      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element("#model-#{agent.id}") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#model-picker-empty", "Codex didn't answer")

      empty =
        Path.join(System.tmp_dir!(), "codex-none-#{System.unique_integer([:positive])}.json")

      File.write!(empty, Jason.encode!(%{"data" => [], "nextCursor" => nil}))
      on_exit(fn -> File.rm(empty) end)
      System.put_env("FAKE_CODEX_MODELS", empty)
      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element("#model-#{agent.id}") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#model-picker-empty", "Codex listed none")
    end
  end

  describe "first-run setup" do
    test "checks Codex too, and offers its defaults", %{conn: conn} do
      {:ok, page, _html} = live(conn, ~p"/repositories?setup=engines")
      setup = find_live_child(page, "setup")
      render_async(setup, 5_000)

      assert has_element?(setup, ~s(#welcome-codex[data-state="ready"]), "signed in with ChatGPT")
      assert has_element?(setup, "#welcome-engine-choice-codex")
      assert has_element?(setup, "#welcome-codex-default-model")
    end

    test "a model list that fails says why", %{conn: conn} do
      put_env("FAKE_CODEX_MODELS", "fail")
      {:ok, page, _html} = live(conn, ~p"/repositories?setup=engines")
      setup = find_live_child(page, "setup")
      # the check, then the model list it starts
      render_async(setup, 5_000)
      render_async(setup, 5_000)

      assert has_element?(setup, ~s(#welcome-codex[data-state="ready"]))

      assert has_element?(
               setup,
               "#welcome-codex-models-unavailable",
               "Couldn't read Codex's models"
             )

      assert has_element?(setup, "#welcome-codex-default-model[disabled]")
    end
  end
end
