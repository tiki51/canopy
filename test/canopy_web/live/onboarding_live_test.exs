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

  # The page behind (any page; repositories is home on an empty install) and
  # the setup modal over it, with its engine checks (and git name) in.
  defp open_page(conn, path \\ ~p"/repositories") do
    {:ok, page, _html} = live(conn, path)
    setup = find_live_child(page, "setup")
    assert setup, "expected the setup modal on #{path}"
    render_async(setup)
    {page, setup}
  end

  defp open(conn, path \\ ~p"/repositories") do
    {_page, setup} = open_page(conn, path)
    setup
  end

  # Opens the modal at a step, through the step indicator.
  defp open_at(conn, step) do
    setup = open(conn)
    go(setup, step)
    setup
  end

  defp go(setup, step), do: setup |> element("#setup-step-#{step}") |> render_click()

  defp current(setup) do
    setup
    |> element("#setup-steps [aria-current=step]")
    |> render()
    |> then(fn html ->
      [_, id] = Regex.run(~r/id="setup-step-([a-z]+)"/, html)
      id
    end)
  end

  # Where an element id first appears in rendered html (it must be there).
  defp at(html, id) do
    {position, _length} = :binary.match(html, ~s(id="#{id}"))
    position
  end

  defp finish(setup) do
    go(setup, "project")
    setup |> element("#welcome-finish") |> render_click()
    render_async(setup)
  end

  describe "the modal" do
    test "opens over the app on first run, on whatever page, as a dialog", %{conn: conn} do
      for path <- [~p"/repositories", ~p"/agents", ~p"/settings", ~p"/costs"] do
        {page, setup} = open_page(conn, path)

        assert has_element?(page, "#app-shell[inert] #sidebar")

        assert has_element?(
                 setup,
                 "#setup-dialog[role=dialog][aria-modal=true][aria-labelledby=setup-title]"
               )

        assert has_element?(setup, "#setup-title", "Set up Canopy")
        assert has_element?(setup, "#welcome-you")
        assert has_element?(setup, "#skip-setup")
      end
    end

    test "/ lands on the normal home, with the modal over it", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == ~p"/repositories"
      setup = open(conn, ~p"/repositories")
      assert has_element?(setup, "#welcome-you")
    end

    test "is not there once setup is finished or skipped", %{conn: conn} do
      {:ok, _} = Settings.mark_onboarded()

      for path <- [~p"/repositories", ~p"/agents", ~p"/settings"] do
        {:ok, page, _html} = live(conn, path)
        refute find_live_child(page, "setup")
        refute has_element?(page, "#app-shell[inert]")
      end
    end

    test "Settings → Run setup again opens it from the start", %{conn: conn} do
      {:ok, _} = Settings.mark_onboarded()
      {:ok, page, _html} = live(conn, ~p"/settings")

      page |> element("#run-setup") |> render_click()
      setup = find_live_child(page, "setup")
      render_async(setup)

      assert current(setup) == "you"
      assert has_element?(page, "#app-shell[inert]")
    end

    test "/welcome, and its old ?step= links, open it at the step", %{conn: conn} do
      {:ok, _} = Settings.mark_onboarded()
      assert redirected_to(get(conn, ~p"/welcome?step=team")) == ~p"/?setup=pace"
      assert redirected_to(get(build_conn(), ~p"/?setup=pace")) == ~p"/repositories?setup=pace"

      setup = open(build_conn(), ~p"/repositories?setup=pace")
      assert current(setup) == "pace"
      assert has_element?(setup, "#welcome-pace")
    end

    test "closing it drops ?setup= from the page it returns to", %{conn: conn} do
      {page, setup} = open_page(conn, ~p"/agents?setup=engines")
      assert current(setup) == "engines"

      setup |> element("#skip-setup") |> render_click()
      assert_redirect(page, ~p"/agents")
    end
  end

  describe "steps" do
    test "Next and Back walk the six steps in order", %{conn: conn} do
      setup = open(conn)

      assert has_element?(setup, "#setup-back[disabled]")
      assert has_element?(setup, "#setup-progress", "1 of 6")

      for {step, n} <- Enum.with_index(~w(you look engines pace notify project), 1) do
        assert current(setup) == step
        assert has_element?(setup, "#setup-progress", "#{n} of 6")

        assert has_element?(
                 setup,
                 "section#welcome-#{step} h2#welcome-#{step}-title[tabindex='-1']"
               )

        # only the current step is shown
        assert Enum.count(LazyHTML.query(LazyHTML.from_fragment(render(setup)), "section")) == 1
        if step != "project", do: setup |> element("#setup-next") |> render_click()
      end

      # the last step finishes instead
      refute has_element?(setup, "#setup-next")
      assert has_element?(setup, "#welcome-finish[data-setup-primary]")
      assert has_element?(setup, "#setup-step-you[data-state=done]")
      assert has_element?(setup, "#setup-step-project[data-state=current]")

      setup |> element("#setup-back") |> render_click()
      assert current(setup) == "notify"
      assert has_element?(setup, "#setup-step-project[data-state=upcoming]")
    end

    test "Back and Next keep what was typed, saved or not", %{conn: conn} do
      setup = open(conn)

      setup
      |> form("#welcome-name-form", setting: %{user_display_name: "Priya"})
      |> render_change()

      setup |> element("#setup-next") |> render_click()
      setup |> element("#setup-back") |> render_click()

      assert has_element?(
               setup,
               "#welcome-name-form input[name='setting[user_display_name]'][value='Priya']"
             )

      # a name that can't be saved yet waits in the field, with its error
      long = String.duplicate("a", 81)
      setup |> form("#welcome-name-form", setting: %{user_display_name: long}) |> render_change()
      setup |> element("#setup-next") |> render_click()
      setup |> element("#setup-back") |> render_click()
      assert has_element?(setup, "#welcome-name-form input[value='#{long}']")
      assert has_element?(setup, "#welcome-name-form", "at most 80")
      assert Settings.get().user_display_name == "Priya"
    end

    test "jumping on the indicator keeps everything, the name among it", %{conn: conn} do
      setup = open(conn)

      setup
      |> form("#welcome-name-form", setting: %{user_display_name: "Priya"})
      |> render_change()

      go(setup, "project")

      setup
      |> form("#welcome-repository-form", repository: %{path: "/half/typed"})
      |> render_change()

      go(setup, "pace")
      setup |> element("#welcome-presets-careful") |> render_click()

      go(setup, "you")
      assert has_element?(setup, "#welcome-name-form input[value='Priya']")
      go(setup, "project")
      assert has_element?(setup, "#welcome-repository-form input[value='/half/typed']")
      go(setup, "pace")
      assert has_element?(setup, "#welcome-presets-careful[aria-checked=true]")

      finish(setup)
      assert has_element?(setup, "#summary-name", "You're Priya.")
      refute has_element?(setup, "#summary-name", "You're You")
    end

    test "Enter in the name field saves it and moves on", %{conn: conn} do
      setup = open(conn)

      setup
      |> form("#welcome-name-form", setting: %{user_display_name: "Ada"})
      |> render_submit()

      assert Settings.get().user_display_name == "Ada"
      assert current(setup) == "look"

      # a blank name stays put, saying why
      go(setup, "you")
      setup |> form("#welcome-name-form", setting: %{user_display_name: ""}) |> render_submit()
      assert current(setup) == "you"
      assert has_element?(setup, "#welcome-name-form", "can't be blank")
    end

    test "the name field is what the step focuses; the other steps their heading",
         %{conn: conn} do
      setup = open(conn)
      assert has_element?(setup, "#welcome-name-form input[data-setup-autofocus]")
      assert has_element?(setup, "#setup-dialog[data-step=you][phx-hook]")

      go(setup, "engines")
      assert has_element?(setup, "#setup-dialog[data-step=engines]")
      refute has_element?(setup, "[data-setup-autofocus]")
    end
  end

  describe "Esc and Skip" do
    test "Esc asks before skipping, and never closes on its own", %{conn: conn} do
      {page, setup} = open_page(conn)

      render_hook(setup, "escape", %{})
      assert has_element?(setup, "#setup-skip-confirm", "Skip setup?")
      assert has_element?(setup, "#setup-keep-going")
      refute has_element?(setup, "#setup-next")
      assert find_live_child(page, "setup")
      refute Settings.onboarded?()

      # a second Esc takes the question back, as does Keep going
      render_hook(setup, "escape", %{})
      refute has_element?(setup, "#setup-skip-confirm")
      assert has_element?(setup, "#setup-next")

      render_hook(setup, "escape", %{})
      setup |> element("#setup-keep-going") |> render_click()
      refute has_element?(setup, "#setup-skip-confirm")
      refute Settings.onboarded?()
      assert find_live_child(page, "setup")
    end

    test "the confirmed skip finishes setup and closes the modal", %{conn: conn} do
      {page, setup} = open_page(conn)

      render_hook(setup, "escape", %{})
      setup |> element("#setup-skip-confirmed") |> render_click()

      assert %{"info" => "Setup skipped" <> _} = assert_redirect(page, ~p"/repositories")
      assert Settings.onboarded?()
    end

    test "Skip setup finishes setup and returns to the page with a note", %{conn: conn} do
      {page, setup} = open_page(conn, ~p"/agents")
      go(setup, "engines")

      setup |> element("#skip-setup") |> render_click()
      assert %{"info" => "Setup skipped" <> _} = assert_redirect(page, ~p"/agents")
      assert Settings.onboarded?()

      {:ok, page, _html} = live(build_conn(), ~p"/agents")
      refute find_live_child(page, "setup")
    end

    test "Skip does not take the git suggestion", %{conn: conn} do
      put_env(:canopy, :git_user_name, "Ada Lovelace")
      setup = open(conn)

      setup |> element("#skip-setup") |> render_click()
      assert Settings.get().user_display_name == "You"
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

    test "the name survives without pressing Next: other steps, then Finish", %{conn: conn} do
      view = open(conn)

      view
      |> form("#welcome-name-form", setting: %{user_display_name: "Priya"})
      |> render_change()

      go(view, "pace")
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

  test "the look step shows the appearance picker", %{conn: conn} do
    view = open_at(conn, "look")

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

      {:ok, page, _html} = live(conn, ~p"/repositories")
      view = find_live_child(page, "setup")
      # checked as the modal opens, whatever the step
      assert_receive {:health, task}
      go(view, "engines")
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
      view = open_at(conn, "engines")

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
      view = open_at(conn, "engines")

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
      view = open_at(conn, "engines")

      assert has_element?(view, "#welcome-no-engine")
      refute has_element?(view, "#welcome-default-model")

      finish(view)
      assert Settings.onboarded?()
      assert Settings.default_model("claude_code").model_id == nil
    end

    test "Claude Code's default model and effort save as they change", %{conn: conn} do
      view = open_at(conn, "engines")

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

      view = open_at(conn, "engines")

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
      view = open_at(conn, "engines")

      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
      assert has_element?(view, "#welcome-engine-choice-claude_code[data-ready=not_ready]")
      assert Settings.get().default_engine == nil
      assert Settings.default_engine() == "opencode"
    end

    test "both ready: Claude Code unless the user picks; a pick saves and outlasts Check again",
         %{conn: conn} do
      opencode_running()
      view = open_at(conn, "engines")

      assert has_element?(view, "#welcome-engine-choice-claude_code[aria-checked=true]")
      assert Settings.get().default_engine == "claude_code"
      # the default engine's model controls come first
      html = view |> element("#welcome-default-model") |> render()
      assert at(html, "welcome-claude-defaults") < at(html, "welcome-opencode-defaults")

      view |> element("#welcome-engine-choice-opencode") |> render_click()

      assert Settings.get().default_engine == "opencode"
      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
      assert has_element?(view, "#welcome-engine-choice-claude_code[aria-checked=false]")
      assert has_element?(view, "#welcome-engines-saved")
      html = view |> element("#welcome-default-model") |> render()
      assert at(html, "welcome-opencode-defaults") < at(html, "welcome-claude-defaults")

      view |> element("#welcome-check-engines") |> render_click()
      render_async(view)
      assert Settings.get().default_engine == "opencode"
    end

    test "until the user picks, Check again re-applies the rule", %{conn: conn} do
      binary = fake_claude()
      claude_missing()
      opencode_running()
      view = open_at(conn, "engines")
      assert Settings.default_engine() == "opencode"

      config = Application.get_env(:canopy, :claude_code)
      Application.put_env(:canopy, :claude_code, Keyword.put(config, :binary, binary))
      view |> element("#welcome-check-engines") |> render_click()
      render_async(view)

      assert Settings.get().default_engine == "claude_code"
      assert has_element?(view, "#welcome-engine-choice-claude_code[aria-checked=true]")
    end

    test "a default engine chosen before is kept, whatever the checks say", %{conn: conn} do
      {:ok, _} = Settings.put_default_engine("opencode")
      view = open_at(conn, "engines")

      assert has_element?(view, "#welcome-claude[data-state=ready]")
      assert has_element?(view, "#welcome-engine-choice-opencode[aria-checked=true]")
      assert Settings.get().default_engine == "opencode"
    end

    test "with only OpenCode running, its default comes from its own list",
         %{conn: conn} do
      claude_missing()
      opencode_running()
      view = open_at(conn, "engines")

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
      view = open_at(conn, "engines")

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
      view = open_at(conn, "engines")

      assert has_element?(view, "select#welcome-opencode-default-provider[disabled]")
      assert has_element?(view, "select#welcome-opencode-default-model[disabled]")
      assert has_element?(view, "#welcome-opencode-default-provider", "OpenCode sent no models")
    end
  end

  describe "pace" do
    test "Balanced is preselected on a fresh install", %{conn: conn} do
      view = open_at(conn, "pace")
      assert has_element?(view, "#welcome-presets-balanced[aria-checked=true]")
      refute has_element?(view, "#welcome-team-form")
    end

    test "a preset saves as it is clicked", %{conn: conn} do
      view = open_at(conn, "pace")

      view |> element("#welcome-presets-careful") |> render_click()
      assert has_element?(view, "#welcome-presets-careful[aria-checked=true]")
      assert has_element?(view, "#welcome-pace-saved")
      assert %{serialize_turns: true, chatter_pause: true, chatter_limit: 3} = Settings.get()

      view |> element("#welcome-presets-autonomous") |> render_click()
      assert %{serialize_turns: false, chatter_pause: false} = Settings.get()
      refute Settings.serialize_turns?()
      assert Settings.chatter_limit() == nil

      # a new visit shows it
      view = open_at(conn, "pace")
      assert has_element?(view, "#welcome-presets-autonomous[aria-checked=true]")
    end

    test "Custom reveals the controls, which validate and save as they change",
         %{conn: conn} do
      view = open_at(conn, "pace")

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
      view = open_at(conn, "pace")

      assert has_element?(view, "#welcome-presets-custom[aria-checked=true]")

      assert has_element?(
               view,
               "#welcome-team-form input[name='setting[chatter_limit]'][value='12']"
             )
    end
  end

  test "offers the desktop notifications switch, kept in the browser", %{conn: conn} do
    view = open_at(conn, "notify")

    assert has_element?(view, "#welcome-notify #notify-prefs[phx-update='ignore']")
    assert has_element?(view, "#welcome-notify #notify-enabled[role='switch']")
    # the details stay in Settings
    refute has_element?(view, "#welcome-notify #notify-kinds")
  end

  describe "project" do
    test "Add project adds a folder, initialising git, and says so inline", %{conn: conn} do
      path = plain_dir()
      view = open_at(conn, "project")

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
      view = open_at(conn, "project")

      view
      |> form("#welcome-repository-form", repository: %{path: "code/project"})
      |> render_submit()

      assert has_element?(view, "#welcome-repository-form", "must be an absolute path")
      refute has_element?(view, "#welcome-repository-added")
      assert Repositories.list() == []
    end

    test "is optional: Finish without one adds nothing", %{conn: conn} do
      view = open_at(conn, "project")
      finish(view)

      assert Repositories.list() == []
      assert has_element?(view, "#summary-project", "No project yet")
    end

    test "a re-run lists the repositories already there", %{conn: conn} do
      repository = Fixtures.repository_fixture(%{name: "existing"})
      view = open_at(conn, "project")

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
      assert has_element?(view, "#setup-dialog[data-step=done]")
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
      refute has_element?(view, "#setup-steps")
      refute has_element?(view, "#skip-setup")
      refute has_element?(view, "#welcome-finish")
      # Esc has nothing left to ask
      render_hook(view, "escape", %{})
      refute has_element?(view, "#setup-skip-confirm")
    end

    test "Start a channel opens New channel on the added repository", %{conn: conn} do
      path = plain_dir()
      {page, view} = open_page(conn)
      go(view, "project")

      view |> form("#welcome-repository-form", repository: %{path: path}) |> render_submit()
      repository = Repositories.get_by_path(path)

      finish(view)
      view |> element("#welcome-start-channel") |> render_click()
      assert_redirect(page, ~p"/channels/new?repository_id=#{repository.id}")
    end

    test "without a repository, Start a channel opens New channel", %{conn: conn} do
      {page, view} = open_page(conn)
      finish(view)

      view |> element("#welcome-start-channel") |> render_click()
      assert_redirect(page, ~p"/channels/new")
    end

    test "Look around closes the modal on the page it was over", %{conn: conn} do
      {page, view} = open_page(conn, ~p"/agents")
      finish(view)

      view |> element("#welcome-look-around") |> render_click()
      assert_redirect(page, ~p"/agents")

      {:ok, page, _html} = live(build_conn(), ~p"/agents")
      refute find_live_child(page, "setup")
    end
  end
end
