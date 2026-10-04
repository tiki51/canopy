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

  # The page with its engine checks (and git name) in.
  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/welcome")
    render_async(view)
    view
  end

  # Where an element id first appears in rendered html (it must be there).
  defp at(html, id) do
    {position, _length} = :binary.match(html, ~s(id="#{id}"))
    position
  end

  defp finish(view) do
    view |> element("#welcome-finish") |> render_click()
    render_async(view)
  end

  describe "the page" do
    test "every section is on one page, in order, with Skip and Finish and no steps",
         %{conn: conn} do
      view = open(conn)
      html = render(view)

      ids =
        ~w(welcome-you welcome-look welcome-engines welcome-pace welcome-notify welcome-project)

      for id <- ids, do: assert(has_element?(view, "section##{id} h2##{id}-title"))

      positions = Enum.map(ids, fn id -> :binary.match(html, ~s(id="#{id}")) |> elem(0) end)
      assert positions == Enum.sort(positions)

      assert has_element?(view, "#skip-setup")
      assert has_element?(view, "#welcome-finish")
      refute has_element?(view, "#welcome-steps")
      refute has_element?(view, "#welcome-continue")
      refute has_element?(view, "#welcome-back")
    end

    test "an old ?step= link opens the page at the matching section", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/welcome#welcome-pace"}}} =
               live(conn, ~p"/welcome?step=team")

      assert {:error, {:redirect, %{to: "/welcome#welcome-finish-bar"}}} =
               live(conn, ~p"/welcome?step=done")

      assert {:error, {:redirect, %{to: "/welcome"}}} = live(conn, ~p"/welcome?step=nope")
    end

    test "/ sends a fresh install here, and not once setup is finished", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == ~p"/welcome"

      view = open(conn)
      finish(view)

      refute redirected_to(get(build_conn(), ~p"/")) == ~p"/welcome"
    end
  end

  describe "you" do
    test "prefills a name already chosen", %{conn: conn} do
      {:ok, _} = Settings.update(%{user_display_name: "Steven"})
      view = open(conn)

      assert has_element?(
               view,
               "#welcome-name-form input[name='setting[user_display_name]'][value='Steven']"
             )
    end

    test "suggests git's user.name while the name is still the default, kept on Finish",
         %{conn: conn} do
      put_env(:canopy, :git_user_name, "Ada Lovelace")
      view = open(conn)

      assert has_element?(
               view,
               "#welcome-name-form input[name='setting[user_display_name]'][value='Ada Lovelace']"
             )

      # only a suggestion until the page is finished (or the field edited)
      assert Settings.get().user_display_name == "You"

      finish(view)
      assert Settings.get().user_display_name == "Ada Lovelace"
      assert has_element?(view, "#summary-name", "Ada Lovelace")
    end

    test "Skip does not take the git suggestion", %{conn: conn} do
      put_env(:canopy, :git_user_name, "Ada Lovelace")
      view = open(conn)

      view |> element("#skip-setup") |> render_click()
      assert Settings.get().user_display_name == "You"
    end

    test "with no git name the field starts empty", %{conn: conn} do
      view = open(conn)

      assert has_element?(view, "#welcome-name-form input[placeholder='Your name']")
      refute has_element?(view, "#welcome-name-form input[value='You']")
    end

    test "saves as it changes, syncs the local user, and says Saved", %{conn: conn} do
      view = open(conn)
      refute has_element?(view, "#welcome-you-saved")

      view |> form("#welcome-name-form", setting: %{user_display_name: ""}) |> render_change()
      assert has_element?(view, "#welcome-name-form", "can't be blank")

      view
      |> form("#welcome-name-form", setting: %{user_display_name: String.duplicate("a", 81)})
      |> render_change()

      assert has_element?(view, "#welcome-name-form", "at most 80")
      assert Settings.get().user_display_name == "You"
      refute has_element?(view, "#welcome-you-saved")

      view |> form("#welcome-name-form", setting: %{user_display_name: "Ada"}) |> render_change()

      assert Settings.get().user_display_name == "Ada"
      assert Users.local().display_name == "Ada"
      assert has_element?(view, "#welcome-you-status #welcome-you-saved[data-saved]")
      refute has_element?(view, "#welcome-name-form", "can't be blank")
    end

    test "Saved goes away after a moment", %{conn: conn} do
      view = open(conn)
      view |> form("#welcome-name-form", setting: %{user_display_name: "Ada"}) |> render_change()
      assert has_element?(view, "#welcome-you-saved")

      # the timer's message, sent early; an older timer's is ignored
      send(view.pid, {:clear_saved, :you, make_ref()})
      assert has_element?(view, "#welcome-you-saved")

      %{saved: %{you: ref}} = :sys.get_state(view.pid).socket.assigns
      send(view.pid, {:clear_saved, :you, ref})
      refute has_element?(view, "#welcome-you-saved")
    end

    test "the name survives without any Continue: other sections, then Finish", %{conn: conn} do
      view = open(conn)

      view
      |> form("#welcome-name-form", setting: %{user_display_name: "Priya"})
      |> render_change()

      view |> element("#welcome-presets-careful") |> render_click()
      finish(view)

      assert Settings.get().user_display_name == "Priya"
      assert has_element?(view, "#summary-name", "You're Priya.")
    end

    test "leaving midway keeps the name", %{conn: conn} do
      view = open(conn)

      view
      |> form("#welcome-name-form", setting: %{user_display_name: "Priya"})
      |> render_submit()

      # a new visit shows it
      view = open(conn)

      assert has_element?(
               view,
               "#welcome-name-form input[name='setting[user_display_name]'][value='Priya']"
             )
    end

    test "Finish without a name says so instead of calling you You", %{conn: conn} do
      view = open(conn)
      finish(view)
      assert has_element?(view, "#summary-name", "No name yet")
    end
  end

  test "the look section shows the appearance picker", %{conn: conn} do
    view = open(conn)

    for mode <- ~w(system light dark) do
      assert has_element?(
               view,
               "#welcome-look #appearance-mode-#{mode}[data-phx-theme='#{mode}']"
             )
    end

    for id <- ~w(blue-hour moss graphite ember) do
      assert has_element?(
               view,
               "#welcome-look #palette-#{id}[role=radio][data-phx-palette='#{id}']"
             )
    end
  end

  describe "engines" do
    test "both checks start with the page; Claude Code found and logged in shows its login",
         %{conn: conn} do
      test_pid = self()

      stub(OC, :health, fn _opts ->
        send(test_pid, {:health, self()})

        receive do
          :answer -> {:error, {:transport, %{reason: :econnrefused}}}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/welcome")
      assert_receive {:health, task}
      assert has_element?(view, "#welcome-opencode[data-state=checking]")
      assert has_element?(view, "#welcome-check-engines[disabled]")

      send(task, :answer)
      render_async(view)
      assert has_element?(view, "#welcome-opencode[data-state=missing]")

      assert has_element?(view, "#welcome-claude[data-state=ready]")
      assert has_element?(view, "#welcome-claude-status", "Claude Code 9.9.9")
      assert has_element?(view, "#welcome-claude-status", "fake@example.com")
      refute has_element?(view, "#welcome-claude-path-form")
    end

    test "a claude that is not found asks for its path, and saves one that works",
         %{conn: conn} do
      fake = fake_claude()
      claude_missing()
      view = open(conn)

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
      assert has_element?(view, "#welcome-engines-saved")
    end

    test "OpenCode running shows its version; not running shows how to start it",
         %{conn: conn} do
      view = open(conn)

      assert has_element?(view, "#welcome-opencode[data-state=missing]")
      assert has_element?(view, "#welcome-opencode-status", "opencode serve --port 4096")

      opencode_running()
      view |> element("#welcome-check-engines") |> render_click()
      render_async(view)

      assert has_element?(view, "#welcome-opencode[data-state=ready]")
      assert has_element?(view, "#welcome-opencode-status", "OpenCode 1.18.11")
    end

    test "with no engine ready, a warning and no model; Finish still works", %{conn: conn} do
      claude_missing()
      view = open(conn)

      assert has_element?(view, "#welcome-no-engine")
      refute has_element?(view, "#welcome-default-model")

      finish(view)
      assert Settings.onboarded?()
      assert Settings.default_model("claude_code").model_id == nil
    end

    test "Claude Code's default model and effort save as they change", %{conn: conn} do
      view = open(conn)

      assert has_element?(view, "#welcome-claude-default-model")
      refute has_element?(view, "#welcome-opencode-default-provider")

      view
      |> form("#welcome-engines-form", setting: %{claude_default_model: "sonnet"})
      |> render_change()

      assert Settings.default_model("claude_code").model_id == "sonnet"
      assert has_element?(view, "#welcome-engines-saved")

      view
      |> form("#welcome-engines-form",
        setting: %{claude_default_model: "sonnet", claude_default_effort: "high"}
      )
      |> render_change()

      assert Settings.default_effort("claude_code") == "high"
    end

    test "only Claude Code ready: it is preselected as the default and saved; starters follow",
         %{conn: conn} do
      backend = Fixtures.agent_fixture(%{name: "backend"})
      mine = Fixtures.agent_fixture(%{name: "my-own", engine: "opencode"})
      assert Agents.effective_engine(backend) == "opencode"

      view = open(conn)

      assert has_element?(view, "#welcome-engine-choice-claude_code[aria-checked=true]")
      assert has_element?(view, "#welcome-engine-choice-claude_code[data-ready=ready]", "Ready")

      assert has_element?(
               view,
               "#welcome-engine-choice-opencode[aria-checked=false][data-ready=not_ready]",
               "Not running"
             )

      assert Settings.get().default_engine == "claude_code"
      assert Agents.effective_engine(Agents.get!(backend.id)) == "claude_code"
      assert Agents.get!(backend.id).engine == nil
      assert Agents.get!(mine.id).engine == "opencode"
      assert has_element?(view, "#welcome-engines-saved")
      refute has_element?(view, "#welcome-move-starters")
    end

    test "only OpenCode ready: OpenCode stays the default, nothing is written", %{conn: conn} do
      claude_missing()
      opencode_running()
      view = open(conn)

      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
      assert has_element?(view, "#welcome-engine-choice-claude_code[data-ready=not_ready]")
      assert Settings.get().default_engine == nil
      assert Settings.default_engine() == "opencode"
    end

    test "both ready: OpenCode unless the user picks; a pick saves and outlasts Check again",
         %{conn: conn} do
      opencode_running()
      view = open(conn)

      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
      assert Settings.get().default_engine == nil
      # the default engine's model controls come first
      html = view |> element("#welcome-default-model") |> render()
      assert at(html, "welcome-opencode-defaults") < at(html, "welcome-claude-defaults")

      view |> element("#welcome-engine-choice-claude_code") |> render_click()

      assert Settings.get().default_engine == "claude_code"
      assert has_element?(view, "#welcome-engine-choice-claude_code[aria-checked=true]")
      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=false]")
      assert has_element?(view, "#welcome-engines-saved")
      html = view |> element("#welcome-default-model") |> render()
      assert at(html, "welcome-claude-defaults") < at(html, "welcome-opencode-defaults")

      view |> element("#welcome-check-engines") |> render_click()
      render_async(view)
      assert Settings.get().default_engine == "claude_code"
    end

    test "until the user picks, Check again re-applies the rule", %{conn: conn} do
      view = open(conn)
      assert Settings.get().default_engine == "claude_code"

      opencode_running()
      view |> element("#welcome-check-engines") |> render_click()
      render_async(view)

      assert Settings.get().default_engine == "opencode"
      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
    end

    test "a default engine chosen before is kept, whatever the checks say", %{conn: conn} do
      {:ok, _} = Settings.put_default_engine("opencode")
      view = open(conn)

      assert has_element?(view, "#welcome-claude[data-state=ready]")
      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
      assert Settings.get().default_engine == "opencode"
    end

    test "with only OpenCode running, its default comes from its own list",
         %{conn: conn} do
      claude_missing()
      opencode_running()
      view = open(conn)

      refute has_element?(view, "#welcome-claude-default-model")

      assert has_element?(
               view,
               "select#welcome-opencode-default-provider option[value='opencode']"
             )

      # a provider alone waits for its model, without an error
      view
      |> form("#welcome-engines-form", setting: %{opencode_default_provider: "opencode"})
      |> render_change(%{"_target" => ["setting", "opencode_default_provider"]})

      assert Settings.default_model("opencode").model_provider == nil
      refute has_element?(view, "#welcome-engines-form", "pick a model")
      refute has_element?(view, "#welcome-engines-saved")

      assert has_element?(
               view,
               "select#welcome-opencode-default-model:not([disabled]) option[value='gpt-5-nano']"
             )

      view
      |> form("#welcome-engines-form",
        setting: %{opencode_default_provider: "opencode", opencode_default_model: "gpt-5-nano"}
      )
      |> render_change(%{"_target" => ["setting", "opencode_default_model"]})

      assert Settings.default_model("opencode") == %{
               model_provider: "opencode",
               model_id: "gpt-5-nano"
             }

      assert has_element?(view, "#welcome-engines-saved")
    end

    test "a Claude Code change saves while an OpenCode provider still waits for its model",
         %{conn: conn} do
      opencode_running()
      view = open(conn)

      view
      |> form("#welcome-engines-form",
        setting: %{opencode_default_provider: "opencode", claude_default_model: "opus"}
      )
      |> render_change(%{"_target" => ["setting", "claude_default_model"]})

      assert Settings.default_model("claude_code").model_id == "opus"
      assert Settings.default_model("opencode").model_provider == nil
    end

    test "the OpenCode picker stays disabled until OpenCode sends its models", %{conn: conn} do
      stub(OC, :health, fn _opts -> {:ok, %{"healthy" => true, "version" => "1.18.11"}} end)
      view = open(conn)

      assert has_element?(view, "select#welcome-opencode-default-provider[disabled]")
      assert has_element?(view, "select#welcome-opencode-default-model[disabled]")
      assert has_element?(view, "#welcome-opencode-default-provider", "OpenCode sent no models")
    end
  end

  describe "pace" do
    test "Balanced is preselected on a fresh install", %{conn: conn} do
      view = open(conn)
      assert has_element?(view, "#welcome-presets-balanced[aria-checked=true]")
      refute has_element?(view, "#welcome-team-form")
    end

    test "a preset saves as it is clicked", %{conn: conn} do
      view = open(conn)

      view |> element("#welcome-presets-careful") |> render_click()
      assert has_element?(view, "#welcome-presets-careful[aria-checked=true]")
      assert has_element?(view, "#welcome-pace-saved")
      assert %{serialize_turns: true, chatter_pause: true, chatter_limit: 3} = Settings.get()

      view |> element("#welcome-presets-autonomous") |> render_click()
      assert %{serialize_turns: false, chatter_pause: false} = Settings.get()
      refute Settings.serialize_turns?()
      assert Settings.chatter_limit() == nil

      # a new visit shows it
      view = open(conn)
      assert has_element?(view, "#welcome-presets-autonomous[aria-checked=true]")
    end

    test "Custom reveals the controls, which validate and save as they change",
         %{conn: conn} do
      view = open(conn)

      view |> element("#welcome-presets-custom") |> render_click()
      assert has_element?(view, "#welcome-team-form")
      refute has_element?(view, "#welcome-pace-saved")

      view
      |> form("#welcome-team-form", setting: %{chatter_pause: "true", chatter_limit: "0"})
      |> render_change()

      assert has_element?(view, "#welcome-team-form", "must be greater than or equal to 1")
      assert Settings.get().chatter_limit == 6

      view
      |> form("#welcome-team-form",
        setting: %{serialize_turns: "true", chatter_pause: "true", chatter_limit: "12"}
      )
      |> render_change()

      assert Settings.chatter_limit() == 12
      assert has_element?(view, "#welcome-pace-saved")
      assert has_element?(view, "#welcome-presets-custom[aria-checked=true]")
    end

    test "a re-run with custom values preselects Custom", %{conn: conn} do
      {:ok, _} = Settings.update(%{chatter_limit: 12})
      view = open(conn)

      assert has_element?(view, "#welcome-presets-custom[aria-checked=true]")

      assert has_element?(
               view,
               "#welcome-team-form input[name='setting[chatter_limit]'][value='12']"
             )
    end
  end

  test "offers the desktop notifications switch, kept in the browser", %{conn: conn} do
    view = open(conn)

    assert has_element?(view, "#welcome-notify #notify-prefs[phx-update='ignore']")
    assert has_element?(view, "#welcome-notify #notify-enabled[role='switch']")
    # the details stay in Settings
    refute has_element?(view, "#welcome-notify #notify-kinds")
  end

  describe "project" do
    test "Add project adds a folder, initialising git, and says so inline", %{conn: conn} do
      path = plain_dir()
      view = open(conn)

      view
      |> form("#welcome-repository-form", repository: %{path: path, name: "My project"})
      |> render_submit()

      assert has_element?(view, "#welcome-repository-added", "Added My project.")
      assert has_element?(view, "#welcome-repository-added", "so one was initialised")
      assert has_element?(view, "#welcome-repositories", "My project")
      assert %{name: "My project"} = Repositories.get_by_path(path)
      assert File.dir?(Path.join(path, ".git"))

      # the form is ready for another
      refute has_element?(view, "#welcome-repository-form input[value='#{path}']")

      finish(view)
      assert has_element?(view, "#summary-project", "My project")
    end

    test "a relative path is refused inline", %{conn: conn} do
      view = open(conn)

      view
      |> form("#welcome-repository-form", repository: %{path: "code/project"})
      |> render_submit()

      assert has_element?(view, "#welcome-repository-form", "must be an absolute path")
      refute has_element?(view, "#welcome-repository-added")
      assert Repositories.list() == []
    end

    test "is optional: Finish without one adds nothing", %{conn: conn} do
      view = open(conn)
      finish(view)

      assert Repositories.list() == []
      assert has_element?(view, "#summary-project", "No project yet")
    end

    test "a re-run lists the repositories already there", %{conn: conn} do
      repository = Fixtures.repository_fixture(%{name: "existing"})
      view = open(conn)

      assert has_element?(view, "#welcome-repositories", "You have 1 already")
      assert has_element?(view, "#welcome-repositories", repository.name)

      finish(view)
      assert has_element?(view, "#summary-project", "1")
      assert Repositories.list() == [repository]
    end
  end

  describe "finish" do
    test "marks setup done and summarises the choices in place of the sections",
         %{conn: conn} do
      {:ok, _} = Settings.update(%{user_display_name: "Ada", chatter_limit: 3})
      {:ok, _} = Settings.put_default_model("claude_code", %{model_id: "opus"})
      view = open(conn)
      refute has_element?(view, "#welcome-done")

      finish(view)
      assert Settings.onboarded?()

      assert has_element?(view, "#welcome-done-title[tabindex='-1']")
      assert has_element?(view, "#summary-name", "Ada")
      assert has_element?(view, "#summary-appearance [data-palette-name=moss]")
      assert has_element?(view, "#summary-engines", "Claude Code ✓")
      assert has_element?(view, "#summary-engines", "OpenCode ✗")
      # only Claude Code was ready, so it became the default
      assert has_element?(view, "#summary-default-engine", "Claude Code")
      assert has_element?(view, "#summary-model", "opus")
      assert has_element?(view, "#summary-pace", "Careful")
      # on or off is the browser's to say (<html data-notify>, set by notify.js)
      assert has_element?(view, "#summary-notify #summary-notify-state")

      refute has_element?(view, "#welcome-you")
      refute has_element?(view, "#skip-setup")
      refute has_element?(view, "#welcome-finish")
    end

    test "Start a channel opens New channel on the added repository", %{conn: conn} do
      path = plain_dir()
      view = open(conn)

      view |> form("#welcome-repository-form", repository: %{path: path}) |> render_submit()
      repository = Repositories.get_by_path(path)

      finish(view)
      view |> element("#welcome-start-channel") |> render_click()
      assert_redirect(view, ~p"/channels/new?repository_id=#{repository.id}")
    end

    test "without a repository, Start a channel goes home", %{conn: conn} do
      view = open(conn)
      finish(view)

      assert {:error, {:redirect, %{to: "/"}}} =
               view |> element("#welcome-start-channel") |> render_click()
    end

    test "Look around first opens the agents", %{conn: conn} do
      view = open(conn)
      finish(view)

      view |> element("#welcome-look-around") |> render_click()
      assert_redirect(view, ~p"/agents")
    end
  end

  test "Skip setup finishes setup and goes home with a note", %{conn: conn} do
    view = open(conn)

    view |> element("#skip-setup") |> render_click()
    assert %{"info" => "Setup skipped" <> _} = assert_redirect(view, ~p"/")
    assert Settings.onboarded?()
  end
end
