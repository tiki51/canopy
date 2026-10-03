defmodule CanopyWeb.OnboardingLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.{Agents, Fixtures, Repo, Repositories, Settings, Users}
  alias Canopy.Settings.Setting

  setup :set_mox_global
  setup :verify_on_exit!

  @providers %{
    "providers" => [
      %{
        "id" => "opencode",
        "name" => "OpenCode Zen",
        "models" => %{
          "gpt-5-nano" => %{"cost" => %{"input" => 0.05, "output" => 0.4}},
          "big-pickle" => %{}
        }
      }
    ],
    "default" => %{"opencode" => "gpt-5-nano"}
  }

  # A fresh install: not set up, default name, OpenCode not running.
  setup do
    Repo.update_all(Setting, set: [onboarded_at: nil, user_display_name: "You"])
    stub(OC, :health, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    :ok
  end

  defp put_env(app, key, value) do
    original = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  # Makes `claude` unfindable for the checks that run on their own.
  defp claude_missing do
    config = Application.get_env(:canopy, :claude_code, [])
    put_env(:canopy, :claude_code, Keyword.put(config, :binary, "no-such-claude-binary"))
  end

  defp opencode_running do
    stub(OC, :health, fn _opts -> {:ok, %{"healthy" => true, "version" => "1.18.11"}} end)
    stub(OC, :providers, fn _opts -> {:ok, @providers} end)
  end

  defp fake_claude, do: Application.get_env(:canopy, :claude_code)[:binary]

  # A folder under the project's _build, so inside the home directory.
  defp plain_dir do
    path = Path.join([File.cwd!(), "_build", "test", "tmp", "plain-" <> Fixtures.unique_suffix()])
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "steps" do
    test "/welcome starts at the name step; ?step= picks one; an unknown step is the first",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      assert has_element?(view, "#welcome-name-form")
      assert has_element?(view, "#welcome-step-name[data-state=current]")
      assert has_element?(view, "#welcome-step-done[data-state=upcoming]")
      assert has_element?(view, "#skip-setup")

      {:ok, view, _html} = live(conn, ~p"/welcome?step=team")
      assert has_element?(view, "#welcome-team")
      assert has_element?(view, "#welcome-step-name[data-state=done]")
      assert has_element?(view, "#welcome-step-team[data-state=current]")

      {:ok, view, _html} = live(conn, ~p"/welcome?step=nope")
      assert has_element?(view, "#welcome-name-form")
    end

    test "Back and the step rail move between steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=theme")

      view |> element("#welcome-back") |> render_click()
      assert_patch(view, ~p"/welcome?step=name")

      view |> element("#welcome-step-team a") |> render_click()
      assert_patch(view, ~p"/welcome?step=team")
    end
  end

  describe "name" do
    test "prefills a name already chosen", %{conn: conn} do
      {:ok, _} = Settings.update(%{user_display_name: "Steven"})
      {:ok, view, _html} = live(conn, ~p"/welcome")

      assert has_element?(
               view,
               "#welcome-name-form input[name='setting[user_display_name]'][value='Steven']"
             )
    end

    test "suggests git's user.name while the name is still the default", %{conn: conn} do
      put_env(:canopy, :git_user_name, "Ada Lovelace")
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_async(view)

      assert has_element?(
               view,
               "#welcome-name-form input[name='setting[user_display_name]'][value='Ada Lovelace']"
             )
    end

    test "with no git name the field starts empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_async(view)

      assert has_element?(view, "#welcome-name-form input[placeholder='Your name']")
      refute has_element?(view, "#welcome-name-form input[value='You']")
    end

    test "saves the name, syncs the local user, and moves on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      view |> form("#welcome-name-form", setting: %{user_display_name: ""}) |> render_submit()
      assert has_element?(view, "#welcome-name-form", "can't be blank")

      view
      |> form("#welcome-name-form", setting: %{user_display_name: String.duplicate("a", 81)})
      |> render_submit()

      assert has_element?(view, "#welcome-name-form", "at most 80")
      assert Settings.get().user_display_name == "You"

      view |> form("#welcome-name-form", setting: %{user_display_name: "Ada"}) |> render_submit()
      assert_patch(view, ~p"/welcome?step=theme")

      assert Settings.get().user_display_name == "Ada"
      assert Users.local().display_name == "Ada"
    end
  end

  test "the theme step shows the appearance picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/welcome?step=theme")

    for mode <- ~w(system light dark) do
      assert has_element?(view, "#appearance-mode-#{mode}[data-phx-theme='#{mode}']")
    end

    for id <- ~w(blue-hour moss graphite ember) do
      assert has_element?(view, "#palette-#{id}[role=radio][data-phx-palette='#{id}']")
    end

    view |> element("#welcome-continue") |> render_click()
    assert_patch(view, ~p"/welcome?step=engines")
  end

  describe "engines" do
    test "Claude Code found and logged in shows its version and login", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      assert has_element?(view, "#welcome-claude[data-state=ready]")
      assert has_element?(view, "#welcome-claude-status", "Claude Code 9.9.9")
      assert has_element?(view, "#welcome-claude-status", "fake@example.com")
      refute has_element?(view, "#welcome-claude-path-form")
    end

    test "a claude that is not found asks for its path, and saves one that works",
         %{conn: conn} do
      fake = fake_claude()
      claude_missing()
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      assert has_element?(view, "#welcome-claude[data-state=missing]")
      assert has_element?(view, "#welcome-claude-error", "not found on PATH")

      view
      |> form("#welcome-claude-path-form", claude: %{binary: "no-such-claude-binary"})
      |> render_submit()

      render_async(view)

      assert has_element?(
               view,
               "#welcome-claude-error",
               "no-such-claude-binary not found on PATH"
             )

      assert Settings.get().claude_binary == "claude"

      view
      |> form("#welcome-claude-path-form", claude: %{binary: fake})
      |> render_submit()

      render_async(view)
      assert has_element?(view, "#welcome-claude[data-state=ready]")
      assert Settings.get().claude_binary == fake
    end

    test "OpenCode running shows its version; not running shows how to start it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      assert has_element?(view, "#welcome-opencode[data-state=missing]")
      assert has_element?(view, "#welcome-opencode-status", "opencode serve --port 4096")

      opencode_running()
      view |> element("#welcome-check-engines") |> render_click()
      render_async(view)

      assert has_element?(view, "#welcome-opencode[data-state=ready]")
      assert has_element?(view, "#welcome-opencode-status", "OpenCode 1.18.11")
    end

    test "with no engine ready, Continue still works and no model is offered", %{conn: conn} do
      claude_missing()
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      assert has_element?(view, "#welcome-no-engine")
      refute has_element?(view, "#welcome-default-model")

      view |> form("#welcome-engines-form") |> render_submit()
      assert_patch(view, ~p"/welcome?step=team")
      assert Settings.default_model("claude_code").model_id == nil
    end

    test "only Claude Code: its default model and effort, and the starter agents move to it",
         %{conn: conn} do
      backend = Fixtures.agent_fixture(%{name: "backend"})

      configured =
        Fixtures.agent_fixture(%{
          name: "reviewer",
          model_provider: "opencode",
          model_id: "big-pickle"
        })

      mine = Fixtures.agent_fixture(%{name: "my-own"})

      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      assert has_element?(view, "#welcome-claude-default-model")
      assert has_element?(view, "#welcome-claude-default-effort")
      refute has_element?(view, "#welcome-opencode-default-provider")
      assert has_element?(view, "#welcome-move-starters-block", "Move the 1 starter agent")

      view
      |> form("#welcome-engines-form",
        setting: %{claude_default_model: "sonnet", claude_default_effort: "high"},
        move_starters: "true"
      )
      |> render_submit()

      assert_patch(view, ~p"/welcome?step=team")
      assert Settings.default_model("claude_code").model_id == "sonnet"
      assert Settings.default_effort("claude_code") == "high"

      assert Agents.get!(backend.id).engine == "claude_code"
      assert Agents.get!(configured.id).engine == "opencode"
      assert Agents.get!(mine.id).engine == "opencode"
    end

    test "unticking the move leaves the starter agents alone", %{conn: conn} do
      backend = Fixtures.agent_fixture(%{name: "backend"})
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      view |> form("#welcome-engines-form", move_starters: "false") |> render_submit()
      assert_patch(view, ~p"/welcome?step=team")
      assert Agents.get!(backend.id).engine == "opencode"
    end

    test "only OpenCode: its default is picked from its own list", %{conn: conn} do
      claude_missing()
      opencode_running()
      Fixtures.agent_fixture(%{name: "backend"})
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      refute has_element?(view, "#welcome-claude-default-model")
      refute has_element?(view, "#welcome-move-starters-block")

      assert has_element?(
               view,
               "select#welcome-opencode-default-provider option[value='opencode']"
             )

      view
      |> form("#welcome-engines-form", setting: %{opencode_default_provider: "opencode"})
      |> render_change()

      view
      |> form("#welcome-engines-form",
        setting: %{opencode_default_provider: "opencode", opencode_default_model: "gpt-5-nano"}
      )
      |> render_submit()

      assert_patch(view, ~p"/welcome?step=team")

      assert Settings.default_model("opencode") == %{
               model_provider: "opencode",
               model_id: "gpt-5-nano"
             }
    end

    test "the OpenCode picker stays disabled until OpenCode sends its models", %{conn: conn} do
      stub(OC, :health, fn _opts -> {:ok, %{"healthy" => true, "version" => "1.18.11"}} end)
      {:ok, view, _html} = live(conn, ~p"/welcome?step=engines")
      render_async(view)

      assert has_element?(view, "select#welcome-opencode-default-provider[disabled]")
      assert has_element?(view, "select#welcome-opencode-default-model[disabled]")
    end
  end

  describe "team" do
    test "Balanced is preselected on a fresh install", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=team")
      assert has_element?(view, "#welcome-presets-balanced[aria-checked=true]")
      refute has_element?(view, "#welcome-team-custom")
    end

    test "Careful and Autonomous save their brakes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=team")

      view |> element("#welcome-presets-careful") |> render_click()
      assert has_element?(view, "#welcome-presets-careful[aria-checked=true]")
      view |> form("#welcome-team-form") |> render_submit()
      assert_patch(view, ~p"/welcome?step=repository")

      assert %{serialize_turns: true, chatter_pause: true, chatter_limit: 3} = Settings.get()

      {:ok, view, _html} = live(conn, ~p"/welcome?step=team")
      assert has_element?(view, "#welcome-presets-careful[aria-checked=true]")
      view |> element("#welcome-presets-autonomous") |> render_click()
      view |> form("#welcome-team-form") |> render_submit()

      assert %{serialize_turns: false, chatter_pause: false} = Settings.get()
      refute Settings.serialize_turns?()
      assert Settings.chatter_limit() == nil
    end

    test "Custom shows the controls and validates them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=team")

      view |> element("#welcome-presets-custom") |> render_click()
      assert has_element?(view, "#welcome-team-custom")

      view
      |> form("#welcome-team-form", setting: %{chatter_pause: "true", chatter_limit: "0"})
      |> render_submit()

      assert has_element?(view, "#welcome-team-form", "must be greater than or equal to 1")
      assert Settings.get().chatter_limit == 6

      view
      |> form("#welcome-team-form",
        setting: %{serialize_turns: "true", chatter_pause: "true", chatter_limit: "12"}
      )
      |> render_submit()

      assert_patch(view, ~p"/welcome?step=repository")
      assert Settings.chatter_limit() == 12
    end

    test "a re-run with custom values preselects Custom", %{conn: conn} do
      {:ok, _} = Settings.update(%{chatter_limit: 12})
      {:ok, view, _html} = live(conn, ~p"/welcome?step=team")

      assert has_element?(view, "#welcome-presets-custom[aria-checked=true]")

      assert has_element?(
               view,
               "#welcome-team-form input[name='setting[chatter_limit]'][value='12']"
             )
    end
  end

  describe "repository" do
    test "adds a folder, initialising git, and moves on", %{conn: conn} do
      path = plain_dir()
      {:ok, view, _html} = live(conn, ~p"/welcome?step=repository")

      view
      |> form("#welcome-repository-form", repository: %{path: path, name: "My project"})
      |> render_submit()

      assert_patch(view, ~p"/welcome?step=done")
      assert render(view) =~ "so one was initialised"
      assert %{name: "My project"} = Repositories.get_by_path(path)
      assert File.dir?(Path.join(path, ".git"))
      assert has_element?(view, "#summary-project", "My project")
    end

    test "a relative path is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=repository")

      view
      |> form("#welcome-repository-form", repository: %{path: "code/project"})
      |> render_submit()

      assert has_element?(view, "#welcome-repository-form", "must be an absolute path")
      assert Repositories.list() == []
    end

    test "Skip this step moves on without adding anything", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=repository")

      view |> element("#welcome-skip-repository") |> render_click()
      assert_patch(view, ~p"/welcome?step=done")
      assert Repositories.list() == []
    end

    test "a re-run lists the repositories and continues without a new one", %{conn: conn} do
      repository = Fixtures.repository_fixture(%{name: "existing"})
      {:ok, view, _html} = live(conn, ~p"/welcome?step=repository")

      assert has_element?(view, "#welcome-repositories", "You already have 1")
      assert has_element?(view, "#welcome-repositories", repository.name)

      view |> form("#welcome-repository-form", repository: %{path: ""}) |> render_submit()
      assert_patch(view, ~p"/welcome?step=done")
      assert Repositories.list() == [repository]
    end
  end

  describe "done" do
    test "summarises the choices", %{conn: conn} do
      {:ok, _} = Settings.update(%{user_display_name: "Ada", chatter_limit: 3})
      {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "opus"})
      {:ok, view, _html} = live(conn, ~p"/welcome?step=done")
      render_async(view)

      assert has_element?(view, "#summary-name", "Ada")
      assert has_element?(view, "#summary-appearance [data-palette-name=moss]")
      assert has_element?(view, "#summary-engines", "Claude Code ✓")
      assert has_element?(view, "#summary-engines", "OpenCode ✗")
      assert has_element?(view, "#summary-model", "opus")
      assert has_element?(view, "#summary-pace", "Careful")
      refute has_element?(view, "#skip-setup")
    end

    test "Start a channel finishes setup and opens New channel on the added repository",
         %{conn: conn} do
      path = plain_dir()
      {:ok, view, _html} = live(conn, ~p"/welcome?step=repository")

      view |> form("#welcome-repository-form", repository: %{path: path}) |> render_submit()
      repository = Repositories.get_by_path(path)

      view |> element("#welcome-finish") |> render_click()
      assert_redirect(view, ~p"/channels/new?repository_id=#{repository.id}")
      assert Settings.onboarded?()
    end

    test "without a repository, Start a channel goes home", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=done")

      assert {:error, {:redirect, %{to: "/"}}} =
               view |> element("#welcome-finish") |> render_click()

      assert Settings.onboarded?()
    end

    test "Look around first finishes setup and opens the agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome?step=done")

      view |> element("#welcome-look-around") |> render_click()
      assert_redirect(view, ~p"/agents")
      assert Settings.onboarded?()
    end
  end

  test "Skip setup from any step finishes setup and goes home with a note", %{conn: conn} do
    for step <- ~w(name theme engines team repository) do
      Repo.update_all(Setting, set: [onboarded_at: nil])
      {:ok, view, _html} = live(conn, ~p"/welcome?step=#{step}")

      view |> element("#skip-setup") |> render_click()
      assert %{"info" => "Setup skipped" <> _} = assert_redirect(view, ~p"/")
      assert Settings.onboarded?()
    end
  end
end
