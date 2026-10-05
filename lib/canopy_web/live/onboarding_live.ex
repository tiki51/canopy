defmodule CanopyWeb.OnboardingLive do
  @moduledoc """
  First-run setup: a stepped modal over the app. Six steps, clicked through
  with *Back* / *Next* or the step indicator: You (display name), Look (mode
  and palette, kept in the browser; the app behind updates as you click),
  Engines (which are ready, the default engine and each engine's default
  model), Pace (a conversation preset), Notifications (kept in the browser,
  like the look) and an optional first project. *Finish setup* on the last
  step shows a summary in the modal; *Skip setup* is always there.

  It is a nested LiveView, rendered by `CanopyWeb.Layouts.app/1` (as
  `live_render(..., id: "setup")`) while `CanopyWeb.Nav` has set the page's
  `:setup` assign: on any page while `Canopy.Settings.onboarded?/0` is false,
  with `?setup=<step>` in the URL (what `/welcome` and its old `?step=` links
  redirect to), or after Settings → *Run setup again* (`"open_setup"`).
  Closing it (Skip, *Look around*, *Start a channel*) asks the page to
  navigate (`{:canopy_setup, :close, opts}` to the parent, handled by `Nav`):
  to the same page, live, so what is behind shows what was chosen, or to New
  channel.

  Every choice saves as it is made (the name debounced, on change or blur), so
  closing halfway keeps what was chosen and *Next* or a jump never loses
  input: each step's form lives in an assign, not only in the DOM. A project
  is added by its own button. Only `onboarded_at` waits for *Finish setup*
  (or *Skip setup*). Esc never closes the modal silently: it asks "Skip
  setup?" in the footer.

  The default engine (`CanopyWeb.EngineComponents.default_engine_choice/1`)
  is preselected from the checks and saved, until the user picks one: Claude
  Code ready, alone or with OpenCode → Claude Code; only OpenCode → OpenCode. The
  starter agents follow the default, so they answer on whichever engine
  works. The default model controls list the default engine first.
  """
  use CanopyWeb, :live_view

  alias Canopy.{Repositories, Settings}
  alias Canopy.Agents.Agent
  alias Canopy.Engine.ClaudeCode
  alias Canopy.OpenCode.{Client, Providers}
  alias Canopy.Repositories.Repository
  alias Canopy.Settings.Presets
  alias CanopyWeb.{AppearanceComponents, EngineComponents, NotifyComponents, PresetComponents}

  @steps [
    %{id: "you", label: "You"},
    %{id: "look", label: "Look"},
    %{id: "engines", label: "Engines"},
    %{id: "pace", label: "Pace"},
    %{id: "notify", label: "Notifications"},
    %{id: "project", label: "Project"}
  ]
  @step_ids Enum.map(@steps, & &1.id)

  # The one-page version's anchors and the first wizard's `?step=` names.
  @step_aliases %{
    "name" => "you",
    "theme" => "look",
    "team" => "pace",
    "notifications" => "notify",
    "repository" => "project",
    "done" => "project"
  }

  # How long a section's "Saved" stays up.
  @saved_ms 2_500

  @team_fields ["serialize_turns", "chatter_pause", "chatter_limit"]
  @claude_fields ["claude_default_model", "claude_default_effort"]
  @opencode_fields ["opencode_default_provider", "opencode_default_model"]

  @claude_guide "https://tiki51.github.io/canopy-site/getting-started/claude-code/"
  @opencode_guide "https://tiki51.github.io/canopy-site/getting-started/opencode/"

  @doc "The setup steps, in order, as `%{id, label}`."
  def steps, do: @steps

  @doc """
  The step a `?setup=` (or old `?step=`) value names, or nil: a step id, or
  one of the names the earlier wizard and one-page versions used.
  """
  def step_for(step) when step in @step_ids, do: step
  def step_for(step) when is_binary(step), do: Map.get(@step_aliases, step)
  def step_for(_step), do: nil

  @impl true
  def mount(_params, session, socket) do
    setting = Settings.get()

    socket =
      socket
      |> assign(:step, step_for(session["step"]) || "you")
      |> assign(:confirm_skip, false)
      |> assign(:finished, false)
      |> assign(:saved, %{})
      |> assign(:setting, setting)
      |> assign(:name_touched, false)
      |> assign(:name_suggestion, nil)
      |> assign(:name_form, name_form(setting))
      |> assign(:claude_check, nil)
      |> assign(:opencode_health, nil)
      |> assign(:providers, [])
      |> assign(:providers_state, :loading)
      |> assign(:engines_form, engines_form(Settings.change(setting)))
      |> assign(:claude_path_form, claude_path_form(""))
      # a default engine picked by the user, before this visit or on it, is
      # never changed by the checks (`preselect_engine/1`)
      |> assign(:engine_picked, Settings.default_engine_chosen?(setting))
      |> assign(:preset, Presets.match(setting))
      |> assign(:team_form, team_form(Settings.change(setting)))
      |> assign(:repository_form, repository_form(Repositories.change(%Repository{})))
      |> assign(:repositories, Repositories.list())
      |> assign(:added_repository, nil)
      |> assign(:repository_note, nil)
      |> assign(:home, System.user_home!())
      |> assign(:release, System.get_env("RELEASE_ROOT") not in [nil, ""])

    socket =
      if connected?(socket) do
        # Checked at once, whatever the step, so the Engines step is ready
        # by the time it is reached.
        socket = check_engines(socket)

        # Still "You": suggest the name git knows, unless the user types first.
        if Settings.user_named?(),
          do: socket,
          else: start_async(socket, :git_name, &git_user_name/0)
      else
        socket
      end

    {:ok, socket}
  end

  # -- Steps ---------------------------------------------------------------------

  @impl true
  def handle_event("go", %{"step" => step}, socket) when step in @step_ids,
    do: {:noreply, go(socket, step)}

  def handle_event("go", _params, socket), do: {:noreply, socket}

  def handle_event("next", _params, socket), do: {:noreply, go(socket, neighbour(socket, 1))}
  def handle_event("back", _params, socket), do: {:noreply, go(socket, neighbour(socket, -1))}

  # Esc asks before anything closes; a second Esc takes the question back.
  # After Finish there is nothing left to skip.
  def handle_event("escape", _params, %{assigns: %{finished: true}} = socket),
    do: {:noreply, socket}

  def handle_event("escape", _params, socket),
    do: {:noreply, update(socket, :confirm_skip, &(not &1))}

  def handle_event("keep_going", _params, socket),
    do: {:noreply, assign(socket, :confirm_skip, false)}

  # -- Skip and finish -----------------------------------------------------------

  def handle_event("skip", _params, socket) do
    {:ok, _} = Settings.mark_onboarded()

    {:noreply, close(socket, flash: "Setup skipped. You can run it any time from Settings.")}
  end

  # A git name still sitting untouched in the field is kept on Finish: it is
  # what the modal showed.
  def handle_event("finish", _params, socket) do
    socket = keep_name_suggestion(socket)
    {:ok, setting} = Settings.mark_onboarded()

    {:noreply,
     socket
     |> assign(:finished, true)
     |> assign(:confirm_skip, false)
     |> assign(:setting, setting)
     |> assign(:repositories, Repositories.list())}
  end

  def handle_event("start_channel", _params, socket) do
    case socket.assigns.added_repository do
      %Repository{id: id} -> {:noreply, close(socket, to: ~p"/channels/new?repository_id=#{id}")}
      nil -> {:noreply, close(socket, to: ~p"/channels/new")}
    end
  end

  def handle_event("look_around", _params, socket), do: {:noreply, close(socket)}

  # -- You -----------------------------------------------------------------------

  def handle_event("save_name", %{"setting" => params}, socket),
    do: {:noreply, socket |> save_name(params) |> elem(0)}

  # Enter in the field: the name is saved and, when it is a name, Next.
  def handle_event("submit_name", %{"setting" => params}, socket) do
    case save_name(socket, params) do
      {socket, :ok} -> {:noreply, go(socket, neighbour(socket, 1))}
      {socket, :error} -> {:noreply, socket}
    end
  end

  # -- Engines -------------------------------------------------------------------

  def handle_event("check_engines", _params, socket), do: {:noreply, check_engines(socket)}

  # A `claude` somewhere off PATH: checked as typed, saved once it answers.
  def handle_event("check_claude_path", %{"claude" => %{"binary" => binary}}, socket) do
    binary = String.trim(binary)

    if binary == "" do
      {:noreply, assign(socket, :claude_path_form, claude_path_form("", "enter a path first"))}
    else
      config_dir = socket.assigns.setting.claude_config_dir

      {:noreply,
       socket
       |> assign(:claude_check, :checking)
       |> assign(:claude_path_form, claude_path_form(binary))
       |> start_async(:claude_path, fn -> {binary, ClaudeCode.check(binary, config_dir)} end)}
    end
  end

  # Each engine's default saves on its own as soon as it is valid, so an
  # OpenCode provider still waiting for its model never holds back a Claude
  # Code change.
  def handle_event("save_engines", params, socket) do
    attrs =
      (params["setting"] || %{})
      |> engine_attrs(socket.assigns)
      |> reset_model_on_new_provider(params["_target"])

    setting = socket.assigns.setting
    providers = socket.assigns.providers

    changed =
      [@claude_fields, @opencode_fields]
      |> Enum.map(&Map.take(attrs, &1))
      |> Enum.filter(fn group ->
        changeset =
          setting
          |> Settings.change(group)
          |> Providers.validate(providers, opencode_fields())

        changeset.errors == [] and changeset.changes != %{}
      end)

    :ok = Enum.each(changed, &save_defaults/1)
    setting = if changed == [], do: setting, else: Settings.get()

    shown =
      setting
      |> Settings.change(attrs)
      |> Providers.validate(providers, opencode_fields())

    shown = if quiet_errors?(shown), do: shown, else: Map.put(shown, :action, :validate)

    socket =
      socket
      |> assign(:setting, setting)
      |> assign(:engines_form, engines_form(shown))

    {:noreply, if(changed == [], do: socket, else: mark_saved(socket, :engines))}
  end

  def handle_event("pick_default_engine", %{"engine" => engine}, socket) do
    case Settings.put_default_engine(engine) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:engine_picked, true)
         |> mark_saved(:engines)}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  # -- Pace ----------------------------------------------------------------------

  # A preset saves at once; Custom only reveals the controls, which save as
  # they change.
  def handle_event("pick_preset", %{"preset" => id}, socket) do
    case Presets.get(id) do
      %{id: preset, attrs: attrs} ->
        {:ok, setting} = Settings.update(attrs)

        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:preset, preset)
         |> assign(:team_form, team_form(Settings.change(setting)))
         |> mark_saved(:pace)}

      nil ->
        {:noreply,
         socket
         |> assign(:preset, :custom)
         |> assign(:team_form, team_form(Settings.change(socket.assigns.setting)))}
    end
  end

  def handle_event("save_team", params, socket) do
    attrs = Map.take(params["setting"] || %{}, @team_fields)
    changeset = Settings.change(socket.assigns.setting, attrs)

    cond do
      not changeset.valid? ->
        {:noreply, assign(socket, :team_form, team_form(Map.put(changeset, :action, :validate)))}

      changeset.changes == %{} ->
        {:noreply, assign(socket, :team_form, team_form(changeset))}

      true ->
        {:ok, setting} = Settings.update(attrs)

        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:team_form, team_form(Settings.change(setting)))
         |> mark_saved(:pace)}
    end
  end

  # -- Project -------------------------------------------------------------------

  def handle_event("validate_repository", %{"repository" => params}, socket) do
    changeset =
      %Repository{}
      |> Repositories.change(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :repository_form, repository_form(changeset))}
  end

  def handle_event("add_repository", %{"repository" => params}, socket) do
    initialised? = Repositories.needs_init?(String.trim(params["path"] || ""))

    case Repositories.create(params) do
      {:ok, repository} ->
        note =
          if initialised?,
            do: " It was not a git repository yet, so one was initialised.",
            else: ""

        {:noreply,
         socket
         |> assign(:added_repository, repository)
         |> assign(:repository_note, "Added #{repository.name}.#{note}")
         |> assign(:repositories, Repositories.list())
         |> assign(:repository_form, repository_form(Repositories.change(%Repository{})))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:repository_note, nil)
         |> assign(:repository_form, repository_form(changeset))}
    end
  end

  # -- Async ---------------------------------------------------------------------

  @impl true
  def handle_async(:git_name, {:ok, name}, socket) when is_binary(name) and name != "" do
    if socket.assigns.name_touched do
      {:noreply, socket}
    else
      changeset = Settings.change(socket.assigns.setting, %{"user_display_name" => name})

      {:noreply,
       socket
       |> assign(:name_suggestion, name)
       |> assign(:name_form, name_form_from(changeset))}
    end
  end

  def handle_async(:git_name, _result, socket), do: {:noreply, socket}

  def handle_async(:claude_check, {:ok, result}, socket),
    do: {:noreply, socket |> assign(:claude_check, result) |> preselect_engine()}

  def handle_async(:claude_check, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :claude_check, {:error, "check crashed: #{inspect(reason)}"})}

  # A path that works is the binary from now on.
  def handle_async(:claude_path, {:ok, {binary, {:ok, _info} = result}}, socket) do
    socket =
      case Settings.update(%{"claude_binary" => binary}) do
        {:ok, setting} -> socket |> assign(:setting, setting) |> mark_saved(:engines)
        {:error, _changeset} -> socket
      end

    {:noreply, socket |> assign(:claude_check, result) |> preselect_engine()}
  end

  def handle_async(:claude_path, {:ok, {_binary, result}}, socket),
    do: {:noreply, assign(socket, :claude_check, result)}

  def handle_async(:claude_path, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :claude_check, {:error, "check crashed: #{inspect(reason)}"})}

  def handle_async(:opencode_health, {:ok, {:ok, %{"healthy" => false}}}, socket),
    do: {:noreply, socket |> assign(:opencode_health, {:error, :unhealthy}) |> preselect_engine()}

  def handle_async(:opencode_health, {:ok, {:ok, body}}, socket),
    do:
      {:noreply,
       socket
       |> assign(:opencode_health, {:ok, is_map(body) && body["version"]})
       |> preselect_engine()}

  def handle_async(:opencode_health, _result, socket),
    do:
      {:noreply, socket |> assign(:opencode_health, {:error, :unreachable}) |> preselect_engine()}

  def handle_async(:providers, {:ok, {:ok, %{providers: [_ | _] = providers}}}, socket),
    do: {:noreply, socket |> assign(:providers, providers) |> assign(:providers_state, :ok)}

  def handle_async(:providers, _result, socket),
    do: {:noreply, socket |> assign(:providers, []) |> assign(:providers_state, :error)}

  @impl true
  def handle_info({:clear_saved, section, ref}, socket) do
    if socket.assigns.saved[section] == ref,
      do: {:noreply, update(socket, :saved, &Map.delete(&1, section))},
      else: {:noreply, socket}
  end

  # -- Helpers -------------------------------------------------------------------

  defp go(socket, step) do
    socket
    |> assign(:step, step)
    |> assign(:confirm_skip, false)
  end

  # The step before (-1) or after (1) the current one, staying in range.
  defp neighbour(socket, offset) do
    index = Enum.find_index(@step_ids, &(&1 == socket.assigns.step)) + offset
    Enum.at(@step_ids, index |> max(0) |> min(length(@step_ids) - 1))
  end

  # The page behind navigates (CanopyWeb.Nav): to the same page, live, so it
  # shows what was chosen, or where the user asked to go. Always nested in a
  # page; mounted on its own it goes home instead.
  defp close(socket, opts \\ []) do
    case socket.parent_pid do
      pid when is_pid(pid) ->
        send(pid, {:canopy_setup, :close, Map.new(opts)})
        socket

      nil ->
        socket
        |> then(&if(opts[:flash], do: put_flash(&1, :info, opts[:flash]), else: &1))
        |> push_navigate(to: opts[:to] || ~p"/")
    end
  end

  defp save_name(socket, params) do
    socket = assign(socket, :name_touched, true)
    checked = name_changeset(socket.assigns.setting, params)

    cond do
      not checked.valid? ->
        {assign(socket, :name_form, name_form_from(Map.put(checked, :action, :validate))), :error}

      not Ecto.Changeset.changed?(checked, :user_display_name) ->
        {assign(socket, :name_form, name_form_from(checked)), :ok}

      true ->
        case Settings.update(Map.take(params, ["user_display_name"])) do
          {:ok, setting} ->
            {socket
             |> assign(:setting, setting)
             |> assign(:name_form, name_form_from(Settings.change(setting)))
             |> mark_saved(:you), :ok}

          {:error, changeset} ->
            {assign(socket, :name_form, name_form_from(changeset)), :error}
        end
    end
  end

  # Both engines (and OpenCode's model list, from the saved URL) at once.
  defp check_engines(socket) do
    url = socket.assigns.setting.opencode_url

    socket
    |> assign(:claude_check, :checking)
    |> assign(:opencode_health, :checking)
    |> assign(:providers_state, :loading)
    |> start_async(:claude_check, fn -> ClaudeCode.check() end)
    |> start_async(:opencode_health, fn -> Client.impl().health(base_url: url) end)
    |> start_async(:providers, fn -> Providers.list(base_url: url) end)
  end

  # A section's "Saved", taken down after a moment unless it saves again.
  defp mark_saved(socket, section) do
    ref = make_ref()
    Process.send_after(self(), {:clear_saved, section, ref}, @saved_ms)
    update(socket, :saved, &Map.put(&1, section, ref))
  end

  defp keep_name_suggestion(%{assigns: %{name_touched: false, name_suggestion: name}} = socket)
       when is_binary(name) do
    with false <- Settings.user_named?(),
         {:ok, setting} <- Settings.update(%{"user_display_name" => name}) do
      assign(socket, :setting, setting)
    else
      _ -> socket
    end
  end

  defp keep_name_suggestion(socket), do: socket

  defp name_form(setting) do
    # "You" is the placeholder name, not one to keep: start from an empty field.
    setting = if Settings.user_named?(), do: setting, else: %{setting | user_display_name: nil}
    name_form_from(Settings.change(setting))
  end

  defp name_form_from(changeset), do: to_form(changeset, id: "welcome-name-form")
  defp engines_form(changeset), do: to_form(changeset, id: "welcome-engines-form")
  defp team_form(changeset), do: to_form(changeset, id: "welcome-team-form")
  defp repository_form(changeset), do: to_form(changeset, id: "welcome-repository-form")

  # A blank name would quietly fall back to the default "You" (Ecto casts an
  # empty value to the field's default), so setup asks for one.
  defp name_changeset(setting, params) do
    changeset = Settings.change(setting, Map.take(params, ["user_display_name"]))

    if String.trim(params["user_display_name"] || "") == "",
      do:
        Ecto.Changeset.add_error(changeset, :user_display_name, "can't be blank",
          validation: :required
        ),
      else: changeset
  end

  defp claude_path_form(binary, error \\ nil) do
    errors = if error, do: [binary: {error, []}], else: []
    to_form(%{"binary" => binary}, as: :claude, id: "welcome-claude-path-form", errors: errors)
  end

  defp git_user_name do
    case Application.fetch_env(:canopy, :git_user_name) do
      {:ok, name} ->
        name

      :error ->
        case System.cmd("git", ["config", "--global", "user.name"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> ""
        end
    end
  rescue
    _ -> ""
  end

  defp opencode_fields, do: {:opencode_default_provider, :opencode_default_model}

  # Only the engines that passed offer a default; OpenCode's selects are
  # disabled (so not submitted) until its model list is in. No provider means
  # OpenCode's own default, whatever the model select still holds.
  defp engine_attrs(params, assigns) do
    claude =
      if claude_ready?(assigns.claude_check),
        do: Map.take(params, @claude_fields),
        else: %{}

    opencode =
      if opencode_ready?(assigns.opencode_health) do
        attrs = Map.take(params, @opencode_fields)

        case Map.fetch(attrs, "opencode_default_provider") do
          {:ok, provider} when provider in [nil, ""] ->
            Map.put(attrs, "opencode_default_model", nil)

          {:ok, _provider} ->
            Map.put_new(attrs, "opencode_default_model", nil)

          :error ->
            attrs
        end
      else
        %{}
      end

    Map.merge(claude, opencode)
  end

  # Another provider's model is never the new provider's: start over.
  defp reset_model_on_new_provider(%{"opencode_default_provider" => _} = attrs, [
         "setting",
         "opencode_default_provider"
       ]),
       do: Map.put(attrs, "opencode_default_model", nil)

  defp reset_model_on_new_provider(attrs, _target), do: attrs

  # A provider picked a moment ago, its model not yet: the select's
  # "Pick a model" says so, without an error.
  defp quiet_errors?(changeset) do
    changeset.errors == [] or
      (Keyword.keys(changeset.errors) == [:opencode_default_model] and
         not blank?(Ecto.Changeset.get_field(changeset, :opencode_default_provider)) and
         blank?(Ecto.Changeset.get_field(changeset, :opencode_default_model)))
  end

  # Through the Default Model API, one engine at a time.
  defp save_defaults(attrs) do
    if Map.has_key?(attrs, "claude_default_model") do
      {:ok, _} =
        Settings.put_default_model("claude_code", %{model_id: attrs["claude_default_model"]})
    end

    if Map.has_key?(attrs, "claude_default_effort") do
      {:ok, _} = Settings.put_default_effort("claude_code", attrs["claude_default_effort"])
    end

    if Map.has_key?(attrs, "opencode_default_provider") do
      {:ok, _} =
        Settings.put_default_model("opencode", %{
          model_provider: attrs["opencode_default_provider"],
          model_id: attrs["opencode_default_model"]
        })
    end

    :ok
  end

  defp claude_ready?(check), do: match?({:ok, %{logged_in: true}}, check)
  defp opencode_ready?(health), do: match?({:ok, _}, health)

  defp checking?(assigns), do: :checking in [assigns.claude_check, assigns.opencode_health]

  # Once both checks are in, the default engine follows what is ready until
  # the user picks one (on this visit or before it): Claude Code ready (alone
  # or with OpenCode) → Claude Code; only OpenCode → OpenCode; neither → left
  # alone.
  # It is saved like every control here, since the starter agents follow the
  # default: on a Mac with only Claude Code they would otherwise sit on an
  # OpenCode that isn't running. A *Check again* re-applies the rule.
  defp preselect_engine(socket) do
    %{claude_check: claude, opencode_health: opencode, setting: setting} = socket.assigns

    pick =
      cond do
        socket.assigns.engine_picked -> nil
        :checking in [claude, opencode] or nil in [claude, opencode] -> nil
        claude_ready?(claude) -> "claude_code"
        opencode_ready?(opencode) -> "opencode"
        true -> nil
      end

    with engine when is_binary(engine) <- pick,
         true <- engine != Settings.default_engine(setting),
         {:ok, setting} <- Settings.put_default_engine(engine) do
      socket |> assign(:setting, setting) |> mark_saved(:engines)
    else
      _ -> socket
    end
  end

  defp blank?(value), do: value in [nil, ""]

  # -- Render --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        steps: @steps,
        index: Enum.find_index(@step_ids, &(&1 == assigns.step)),
        last?: assigns.step == List.last(@step_ids)
      )

    ~H"""
    <%!-- A modal over the app (CanopyWeb.Layouts.app/1 makes #app-shell inert
         while it is open). Not a <dialog>: Chrome closes a modal dialog on a
         repeated Esc whatever its cancel handler says, and setup closes only
         by an explicit choice. The hook traps focus, turns Esc into "Skip
         setup?", lets Enter press the primary button, and moves focus to each
         step as it shows. --%>
    <div
      id="setup-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="setup-title"
      data-step={if @finished, do: "done", else: @step}
      data-skip-question={to_string(@confirm_skip)}
      phx-hook=".SetupDialog"
      class="fixed inset-0 z-50 flex items-stretch justify-center sm:items-center sm:p-6"
    >
      <div
        class="setup-backdrop absolute inset-0 bg-neutral/30 backdrop-blur-[2px] dark:bg-black/50"
        aria-hidden="true"
      >
      </div>

      <%!-- A fixed height from sm up, so it doesn't jump between steps; a
           full-screen sheet below. --%>
      <div
        id="setup-panel"
        class="setup-panel relative flex h-dvh w-full flex-col bg-base-100 text-base-content shadow-2xl sm:h-[min(46rem,calc(100dvh-3rem))] sm:max-w-2xl sm:rounded-2xl sm:ring-1 sm:ring-base-content/10"
      >
        <header class="flex items-center gap-2.5 px-5 pt-[max(1rem,env(safe-area-inset-top))] sm:px-8 sm:pt-6">
          <img
            src={~p"/images/canopy-icon-64.png"}
            alt=""
            width="28"
            height="28"
            class="size-7 rounded-lg shadow-sm"
          />
          <p id="setup-title" class="text-sm font-semibold">Set up Canopy</p>
          <span
            :if={!@finished}
            id="setup-progress"
            class="text-xs text-base-content/55 tabular-nums sm:hidden"
          >
            · {@index + 1} of {length(@steps)}
          </span>
          <button
            :if={!@finished}
            type="button"
            id="skip-setup"
            class="btn btn-ghost btn-sm -mr-2 ml-auto font-normal text-base-content/70"
            phx-click="skip"
          >
            Skip setup
          </button>
        </header>

        <nav :if={!@finished} id="setup-steps" aria-label="Setup steps" class="px-5 pt-5 sm:px-8">
          <ol class="grid grid-cols-6 gap-1.5 sm:gap-2">
            <li :for={{step, i} <- Enum.with_index(@steps)}>
              <button
                type="button"
                id={"setup-step-#{step.id}"}
                phx-click="go"
                phx-value-step={step.id}
                aria-current={if(i == @index, do: "step")}
                data-state={step_state(i, @index)}
                class="group flex w-full cursor-pointer flex-col gap-2 rounded-md py-1.5 text-left focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                <span class={[
                  "block h-1 w-full rounded-full transition-colors duration-300",
                  i <= @index && "bg-primary",
                  i > @index && "bg-base-300 group-hover:bg-base-content/25"
                ]}></span>
                <span class={[
                  "hidden truncate text-xs transition-colors sm:block",
                  i == @index && "font-semibold text-base-content",
                  i < @index && "text-base-content/70 group-hover:text-base-content",
                  i > @index && "text-base-content/50 group-hover:text-base-content/75"
                ]}>
                  {step.label}
                </span>
                <span class="sr-only sm:hidden">{step.label}</span>
              </button>
            </li>
          </ol>
        </nav>

        <div
          id="setup-body"
          class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 pt-7 pb-8 sm:px-8 sm:pt-8"
        >
          <%= if @finished do %>
            <.done
              setting={@setting}
              claude_check={@claude_check}
              opencode_health={@opencode_health}
              added_repository={@added_repository}
              repositories={@repositories}
            />
          <% else %>
            <.step_content {assigns} />
          <% end %>
        </div>

        <footer
          id="setup-footer"
          class="border-t border-base-300/60 px-5 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] sm:px-8 sm:py-4"
        >
          <%= cond do %>
            <% @finished -> %>
              <div class="flex flex-wrap items-center justify-end gap-2 sm:gap-3">
                <button
                  type="button"
                  id="welcome-look-around"
                  class="btn btn-ghost"
                  phx-click="look_around"
                >
                  Look around
                </button>
                <button
                  type="button"
                  id="welcome-start-channel"
                  class="btn btn-primary"
                  phx-click="start_channel"
                >
                  <.icon name="hero-chat-bubble-left-right" class="size-4" /> Start a channel
                </button>
              </div>
            <% @confirm_skip -> %>
              <div
                id="setup-skip-confirm"
                role="group"
                aria-labelledby="setup-skip-question"
                class="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3"
              >
                <p id="setup-skip-question" class="min-w-0 flex-1 text-sm">
                  <span class="font-semibold">Skip setup?</span>
                  <span class="text-base-content/65">What you've chosen so far is kept.</span>
                </p>
                <div class="flex items-center justify-end gap-2">
                  <button
                    type="button"
                    id="setup-keep-going"
                    class="btn btn-ghost btn-sm"
                    phx-click="keep_going"
                    phx-mounted={JS.focus()}
                  >
                    Keep going
                  </button>
                  <button
                    type="button"
                    id="setup-skip-confirmed"
                    class="btn btn-soft btn-warning btn-sm"
                    phx-click="skip"
                  >
                    Skip setup
                  </button>
                </div>
              </div>
            <% true -> %>
              <div class="flex items-center gap-3">
                <button
                  type="button"
                  id="setup-back"
                  class={["btn btn-ghost", @index == 0 && "invisible"]}
                  phx-click="back"
                  disabled={@index == 0}
                >
                  <.icon name="hero-arrow-left-micro" class="size-4" /> Back
                </button>
                <p class="min-w-0 flex-1 text-center text-xs text-base-content/55">
                  <span class="hidden sm:inline">Saved as you go</span>
                </p>
                <%= if @last? do %>
                  <button
                    type="button"
                    id="welcome-finish"
                    class="btn btn-primary"
                    phx-click="finish"
                    data-setup-primary
                  >
                    Finish setup <.icon name="hero-check-micro" class="size-4" />
                  </button>
                <% else %>
                  <button
                    type="button"
                    id="setup-next"
                    class="btn btn-primary"
                    phx-click="next"
                    data-setup-primary
                  >
                    Next <.icon name="hero-arrow-right-micro" class="size-4" />
                  </button>
                <% end %>
              </div>
          <% end %>
        </footer>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SetupDialog">
        const FOCUSABLE =
          "a[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
        // Enter on these keeps its own meaning (submit, toggle, follow).
        const OWN_ENTER = "input, textarea, select, button, a, summary, [role=radio], [role=switch], [contenteditable]"

        export default {
          mounted() {
            const active = document.activeElement
            this.returnTo = active && active !== document.body && active.id ? active.id : null
            this.step = this.el.dataset.step
            // (not data-confirm: phoenix_html turns that into a confirm() box)
            this.question = this.el.dataset.skipQuestion
            this.onKeydown = (e) => this.keydown(e)
            document.addEventListener("keydown", this.onKeydown)
            this.focusStep()
          },

          updated() {
            if (this.el.dataset.step !== this.step) {
              this.step = this.el.dataset.step
              this.focusStep()
            } else if (this.el.dataset.skipQuestion !== this.question && this.el.dataset.skipQuestion === "false") {
              // "Keep going": back to where the question took focus from
              const primary = this.el.querySelector("[data-setup-primary]")
              primary ? primary.focus() : this.focusStep()
            }
            this.question = this.el.dataset.skipQuestion
          },

          destroyed() {
            document.removeEventListener("keydown", this.onKeydown)
            // Closing navigates the page behind; once it is back, focus returns
            // to what had it, or to what opens setup ([data-setup-return],
            // Settings' Run setup again: the inert shell had already taken
            // focus from it when this mounted), if the page has one.
            const id = this.returnTo
            const target = () => {
              const el = (id && document.getElementById(id)) || document.querySelector("[data-setup-return]")
              return el && el.isConnected && !el.closest("[inert]") ? el : null
            }
            // The new page arrives over a few frames, and LiveView may drop
            // focus as it does; keep at it for a moment, until it holds, unless
            // the user has put focus somewhere else by then.
            const until = performance.now() + 1500
            let held = 0
            const restore = () => {
              const el = target()
              const active = document.activeElement
              if (held > 0 && active && active !== document.body && active !== el) return
              if (el && active !== el) el.focus({preventScroll: true})
              held = el && document.activeElement === el ? held + 1 : 0
              if (held < 5 && performance.now() < until) requestAnimationFrame(restore)
            }
            requestAnimationFrame(restore)
          },

          // The step's own field when it has one (the name), else its heading,
          // so a screen reader hears where it is.
          focusStep() {
            const target =
              this.el.querySelector("#setup-body [data-setup-autofocus]") ||
              this.el.querySelector("#setup-body h2[tabindex]")
            if (target) target.focus({preventScroll: true})
          },

          keydown(e) {
            if (e.defaultPrevented || e.isComposing) return
            if (e.key === "Escape") {
              e.preventDefault()
              e.stopPropagation()
              this.pushEvent("escape", {})
            } else if (e.key === "Tab") {
              this.trap(e)
            } else if (e.key === "Enter" && !(e.shiftKey || e.metaKey || e.ctrlKey || e.altKey)) {
              if (e.target.closest && e.target.closest(OWN_ENTER)) return
              const primary = this.el.querySelector("[data-setup-primary]")
              if (primary) {
                e.preventDefault()
                primary.click()
              }
            }
          },

          trap(e) {
            const items = [...this.el.querySelectorAll(FOCUSABLE)].filter((el) => el.getClientRects().length > 0)
            if (items.length === 0) return
            const first = items[0]
            const last = items[items.length - 1]
            const inside = this.el.contains(document.activeElement)
            if (e.shiftKey && (!inside || document.activeElement === first)) {
              e.preventDefault()
              last.focus()
            } else if (!e.shiftKey && (!inside || document.activeElement === last)) {
              e.preventDefault()
              first.focus()
            }
          },
        }
      </script>
    </div>
    """
  end

  defp step_state(i, index) when i < index, do: "done"
  defp step_state(index, index), do: "current"
  defp step_state(_i, _index), do: "upcoming"

  # The current step's section. Each keeps its id (`welcome-<step>`) and its
  # own "Saved".
  defp step_content(%{step: "you"} = assigns) do
    ~H"""
    <.setup_section id="welcome-you" title="Welcome to Canopy" saved={@saved[:you]}>
      <:description>
        A few choices and your AI agents are ready to work as a team. Each one saves as you make
        it, and all of them can be changed later in Settings.
      </:description>
      <.form
        for={@name_form}
        id="welcome-name-form"
        phx-change="save_name"
        phx-submit="submit_name"
        class="max-w-sm"
      >
        <.input
          field={@name_form[:user_display_name]}
          type="text"
          label="What should the agents call you?"
          placeholder="Your name"
          autocomplete="name"
          phx-debounce="600"
          data-setup-autofocus
        />
        <p class="-mt-1 text-xs text-base-content/60">
          Shown on your messages. The agents see it too.
        </p>
      </.form>
    </.setup_section>
    """
  end

  defp step_content(%{step: "look"} = assigns) do
    ~H"""
    <.setup_section id="welcome-look" title="Pick a look">
      <:description>
        Light, dark or the system's, in one of four palettes. Canopy changes behind this as you
        click, and remembers it in this browser.
      </:description>
      <AppearanceComponents.appearance_picker />
    </.setup_section>
    """
  end

  defp step_content(%{step: "engines"} = assigns) do
    ~H"""
    <.engines_section
      saved={@saved[:engines]}
      claude_check={@claude_check}
      opencode_health={@opencode_health}
      opencode_url={@setting.opencode_url}
      setting={@setting}
      providers={@providers}
      providers_state={@providers_state}
      form={@engines_form}
      claude_path_form={@claude_path_form}
      release={@release}
    />
    """
  end

  defp step_content(%{step: "pace"} = assigns) do
    ~H"""
    <.setup_section id="welcome-pace" title="How much agents do on their own" saved={@saved[:pace]}>
      <:description>
        Agents wake each other by mentioning, delegating and handing off. This decides how far
        that goes before you're back in the loop.
      </:description>
      <PresetComponents.preset_cards
        id="welcome-presets"
        selected={@preset}
        event="pick_preset"
        custom
      />
      <.form
        :if={@preset == :custom}
        for={@team_form}
        id="welcome-team-form"
        phx-change="save_team"
        phx-submit="save_team"
        class="mt-3 flex flex-col gap-2 rounded-xl bg-base-200/60 p-4 ring-1 ring-inset ring-base-300/60 [&_.label]:items-start [&_.label]:whitespace-normal"
      >
        <.input
          field={@team_form[:serialize_turns]}
          type="checkbox"
          label="One agent at a time per channel"
        />
        <.input
          field={@team_form[:chatter_pause]}
          type="checkbox"
          label="Pause a channel after agents have taken turns without me"
        />
        <div class="max-w-xs">
          <.input
            field={@team_form[:chatter_limit]}
            type="number"
            min="1"
            max="1000"
            label="Turns before pausing"
            phx-debounce="400"
          />
        </div>
      </.form>
      <p class="mt-4 text-xs text-base-content/60">
        A paused channel shows a Continue button; your next message also resumes it.
      </p>
    </.setup_section>
    """
  end

  # Kept in this browser by notify.js, like the look; the same controls as
  # Settings → Notifications.
  defp step_content(%{step: "notify"} = assigns) do
    ~H"""
    <.setup_section id="welcome-notify" title="Notifications" optional>
      <:description>
        Hear about it when an agent needs you and you're looking elsewhere. Applies to this
        browser; Settings has the details.
      </:description>
      <NotifyComponents.notify_prefs kinds={false} />
    </.setup_section>
    """
  end

  defp step_content(%{step: "project"} = assigns) do
    ~H"""
    <.project_section
      form={@repository_form}
      repositories={@repositories}
      home={@home}
      note={@repository_note}
    />
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :optional, :boolean, default: false
  attr :saved, :any, default: nil, doc: "set while the section's last save is acknowledged"
  slot :description, required: true
  slot :inner_block, required: true

  defp setup_section(assigns) do
    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-title"} class="setup-step">
      <div class="flex items-center gap-2.5">
        <h2
          id={"#{@id}-title"}
          tabindex="-1"
          class="text-xl font-semibold tracking-tight text-balance outline-none sm:text-2xl"
        >
          {@title}
        </h2>
        <span
          :if={@optional}
          class="rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-medium text-base-content/60"
        >
          Optional
        </span>
        <span id={"#{@id}-status"} role="status" aria-live="polite" class="ml-auto shrink-0">
          <span
            :if={@saved}
            id={"#{@id}-saved"}
            data-saved
            class="inline-flex items-center gap-1 text-xs font-medium text-success"
            phx-mounted={
              JS.transition({"ease-out duration-300", "opacity-0 translate-y-0.5", "opacity-100"})
            }
          >
            <.icon name="hero-check-micro" class="size-3.5" /> Saved
          </span>
        </span>
      </div>
      <p class="mt-2 max-w-xl text-sm leading-relaxed text-pretty text-base-content/65">
        {render_slot(@description)}
      </p>
      <div class="mt-7">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :saved, :any, required: true
  attr :claude_check, :any, required: true
  attr :opencode_health, :any, required: true
  attr :opencode_url, :string, required: true
  attr :setting, :any, required: true
  attr :providers, :list, required: true
  attr :providers_state, :atom, required: true
  attr :form, :any, required: true
  attr :claude_path_form, :any, required: true
  attr :release, :boolean, required: true

  defp engines_section(assigns) do
    assigns =
      assigns
      |> assign(:claude_ready, claude_ready?(assigns.claude_check))
      |> assign(:opencode_ready, opencode_ready?(assigns.opencode_health))
      |> assign(:checking, checking?(assigns))
      |> assign(:default_engine, Settings.default_engine(assigns.setting))
      |> assign(:claude_guide, @claude_guide)
      |> assign(:opencode_guide, @opencode_guide)

    ~H"""
    <.setup_section id="welcome-engines" title="Your engines" saved={@saved}>
      <:description>
        Agents do their work through a coding engine installed on this Mac. You need at least one.
      </:description>

      <div class="grid gap-3 sm:grid-cols-2">
        <div
          id="welcome-claude"
          data-state={engine_state(@claude_check, @claude_ready)}
          class="flex flex-col gap-2 rounded-xl bg-base-200/60 p-4 ring-1 ring-inset ring-base-300/60"
        >
          <div class="flex items-center gap-2">
            <.engine_icon state={engine_state(@claude_check, @claude_ready)} />
            <h3 class="text-sm font-semibold">Claude Code</h3>
          </div>
          <div id="welcome-claude-status" class="text-sm text-base-content/80" role="status">
            <%= case @claude_check do %>
              <% value when value in [nil, :checking] -> %>
                <span class="text-base-content/60">Checking…</span>
              <% {:ok, %{logged_in: true} = info} -> %>
                Claude Code {info.version}, logged in{if info.email, do: " as #{info.email}"}.
              <% {:ok, _info} -> %>
                Installed, but not logged in. Run <code class="font-mono">claude</code>
                once in a terminal, then <em>Check again</em>.
              <% {:error, reason} -> %>
                <%= if String.ends_with?(reason, "not found on PATH") do %>
                  Not found. Install it from <a
                    href="https://claude.com/claude-code"
                    target="_blank"
                    class="link link-primary"
                  >
                    claude.com/claude-code</a>.
                <% else %>
                  Claude Code didn't answer.
                <% end %>
                <span id="welcome-claude-error" class="mt-1 block font-mono text-xs text-error">
                  {reason}
                </span>
            <% end %>
          </div>
          <.form
            :if={match?({:error, _}, @claude_check)}
            for={@claude_path_form}
            id="welcome-claude-path-form"
            phx-submit="check_claude_path"
            class="flex flex-col gap-1"
          >
            <div class="flex items-end gap-2">
              <div class="min-w-0 flex-1">
                <.input
                  field={@claude_path_form[:binary]}
                  type="text"
                  id="welcome-claude-binary"
                  label="Installed somewhere else? Path to claude"
                  placeholder="/opt/homebrew/bin/claude"
                  autocomplete="off"
                  spellcheck="false"
                />
              </div>
              <button type="submit" id="welcome-claude-path-check" class="btn btn-soft mb-2">
                Check
              </button>
            </div>
            <p :if={@release} class="text-xs text-base-content/60">
              Running as a background service? Canopy uses your login shell's PATH; set
              <code class="font-mono">CANOPY_PATH</code>
              if it still can't find it.
            </p>
          </.form>
        </div>

        <div
          id="welcome-opencode"
          data-state={engine_state(@opencode_health, @opencode_ready)}
          class="flex flex-col gap-2 rounded-xl bg-base-200/60 p-4 ring-1 ring-inset ring-base-300/60"
        >
          <div class="flex items-center gap-2">
            <.engine_icon state={engine_state(@opencode_health, @opencode_ready)} />
            <h3 class="text-sm font-semibold">OpenCode</h3>
          </div>
          <div id="welcome-opencode-status" class="text-sm text-base-content/80" role="status">
            <%= case @opencode_health do %>
              <% value when value in [nil, :checking] -> %>
                <span class="text-base-content/60">Checking…</span>
              <% {:ok, version} -> %>
                OpenCode{if version, do: " #{version}"} at <code class="font-mono text-xs break-all">{@opencode_url}</code>.
              <% {:error, _reason} -> %>
                Not running at <code class="font-mono text-xs break-all">{@opencode_url}</code>.
                Start it with <code class="font-mono text-xs">opencode serve --port 4096</code>
                and leave it running, then <em>Check again</em>.
                <%!-- Not a link: Settings is behind this modal. --%>
                <span class="mt-1 block text-xs text-base-content/60">
                  Running it somewhere else? Set its URL in Settings → OpenCode server once setup
                  is done.
                </span>
            <% end %>
          </div>
        </div>
      </div>

      <div class="mt-3">
        <button
          type="button"
          id="welcome-check-engines"
          class="btn btn-soft btn-sm"
          phx-click="check_engines"
          disabled={@checking}
        >
          <.icon :if={@checking} name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          <.icon :if={!@checking} name="hero-arrow-path-micro" class="size-4" /> Check again
        </button>
      </div>

      <div id="welcome-default-engine" class="mt-8 flex flex-col gap-3">
        <div>
          <h3 class="text-sm font-semibold">Default engine</h3>
          <p class="mt-0.5 text-xs text-base-content/60">
            Agents without an engine of their own, the starter agents among them, run on this.
            You can still pick one per agent on the Agents page.
          </p>
        </div>
        <EngineComponents.default_engine_choice
          id="welcome-engine-choice"
          selected={@default_engine}
          readiness={
            %{
              "claude_code" => readiness(@claude_check, @claude_ready),
              "opencode" => readiness(@opencode_health, @opencode_ready)
            }
          }
          not_ready={%{"claude_code" => "Not ready", "opencode" => "Not running"}}
        />
      </div>

      <div
        :if={!@checking and !@claude_ready and !@opencode_ready}
        id="welcome-no-engine"
        class="alert alert-soft alert-warning mt-6 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <span>
          No engine is ready yet. You can finish setup now, but agents won't reply until one
          works. Getting started guides:
          <a href={@claude_guide} target="_blank" class="link">Claude Code</a>
          · <a href={@opencode_guide} target="_blank" class="link">OpenCode</a>
        </span>
      </div>

      <.form
        :if={@claude_ready or @opencode_ready}
        for={@form}
        id="welcome-engines-form"
        phx-change="save_engines"
        phx-submit="save_engines"
        class="mt-8"
      >
        <div id="welcome-default-model" class="flex flex-col gap-3">
          <div>
            <h3 class="text-sm font-semibold">Default model for new agents</h3>
            <p class="mt-0.5 text-xs text-base-content/60">
              Agents without their own model use this. You can still pick one per agent on the
              Agents page.
            </p>
          </div>
          <%!-- the default engine's controls first --%>
          <%= for engine <- engines_default_first(@default_engine) do %>
            <div
              :if={engine == "claude_code" and @claude_ready}
              id="welcome-claude-defaults"
              class="grid gap-x-3 sm:grid-cols-2"
            >
              <.input
                field={@form[:claude_default_model]}
                type="select"
                id="welcome-claude-default-model"
                label="Claude Code model"
                prompt="Claude Code's own default"
                options={Agent.claude_models()}
              />
              <.input
                field={@form[:claude_default_effort]}
                type="select"
                id="welcome-claude-default-effort"
                label="Claude Code effort"
                prompt="Claude Code's own default"
                options={Agent.efforts()}
              />
            </div>
            <div
              :if={engine == "opencode" and @opencode_ready}
              id="welcome-opencode-defaults"
              class="grid gap-x-3 sm:grid-cols-2"
            >
              <%= if @providers != [] do %>
                <.input
                  field={@form[:opencode_default_provider]}
                  type="select"
                  id="welcome-opencode-default-provider"
                  label="OpenCode provider"
                  prompt="OpenCode's own default"
                  options={
                    Providers.provider_options(
                      @providers,
                      @form[:opencode_default_provider].value
                    )
                  }
                />
                <.input
                  field={@form[:opencode_default_model]}
                  type="select"
                  id="welcome-opencode-default-model"
                  label="OpenCode model"
                  prompt={
                    if blank?(@form[:opencode_default_provider].value),
                      do: "Pick a provider first",
                      else: "Pick a model"
                  }
                  options={
                    Providers.model_options(
                      @providers,
                      @form[:opencode_default_provider].value,
                      @form[:opencode_default_model].value
                    )
                  }
                  disabled={blank?(@form[:opencode_default_provider].value)}
                />
              <% else %>
                <%!-- Chosen from OpenCode's own list only, as in Settings: a
                   default it cannot run would fail every inheriting agent. --%>
                <.input
                  field={@form[:opencode_default_provider]}
                  type="select"
                  id="welcome-opencode-default-provider"
                  label="OpenCode provider"
                  prompt={
                    if @providers_state == :loading,
                      do: "Loading OpenCode's models…",
                      else: "OpenCode sent no models"
                  }
                  options={List.wrap(@setting.opencode_default_provider)}
                  disabled
                />
                <.input
                  field={@form[:opencode_default_model]}
                  type="select"
                  id="welcome-opencode-default-model"
                  label="OpenCode model"
                  prompt={
                    if @providers_state == :loading,
                      do: "Loading OpenCode's models…",
                      else: "OpenCode sent no models"
                  }
                  options={List.wrap(@setting.opencode_default_model)}
                  disabled
                />
              <% end %>
            </div>
          <% end %>
        </div>
      </.form>
    </.setup_section>
    """
  end

  # The engines with the default first, so its model controls lead.
  defp engines_default_first(default),
    do: [default | List.delete(Canopy.Engine.names(), default)]

  defp readiness(value, _ready) when value in [nil, :checking], do: :checking
  defp readiness(_value, true), do: :ready
  defp readiness(_value, false), do: :not_ready

  defp engine_state(value, _ready) when value in [nil, :checking], do: "checking"
  defp engine_state(_value, true), do: "ready"
  defp engine_state({:ok, _}, false), do: "warning"
  defp engine_state(_value, _ready), do: "missing"

  attr :state, :string, required: true

  defp engine_icon(assigns) do
    ~H"""
    <%= case @state do %>
      <% "checking" -> %>
        <.icon
          name="hero-arrow-path"
          class="size-5 text-base-content/50 motion-safe:animate-spin"
        />
      <% "ready" -> %>
        <.icon name="hero-check-circle" class="size-5 text-success" />
      <% "warning" -> %>
        <.icon name="hero-exclamation-circle" class="size-5 text-warning" />
      <% "missing" -> %>
        <.icon name="hero-x-circle" class="size-5 text-error" />
    <% end %>
    """
  end

  attr :form, :any, required: true
  attr :repositories, :list, required: true
  attr :home, :string, required: true
  attr :note, :string, default: nil

  defp project_section(assigns) do
    ~H"""
    <.setup_section id="welcome-project" title="Your first project" optional>
      <:description>
        Agents work inside a git repository on this Mac. If the folder isn't one yet, Canopy
        runs <code class="font-mono text-xs">git init</code> for you.
      </:description>

      <div
        :if={@repositories != []}
        id="welcome-repositories"
        class="mb-5 rounded-xl bg-base-200/60 p-4 text-sm ring-1 ring-inset ring-base-300/60"
      >
        <p>
          You have {length(@repositories)} already. Add another, or leave it there.
        </p>
        <ul class="mt-2 flex flex-col gap-1 text-xs text-base-content/70">
          <li :for={repository <- @repositories} class="flex min-w-0 items-center gap-2">
            <.icon name="hero-folder-micro" class="size-4 shrink-0" />
            <span class="shrink-0 font-medium text-base-content">{repository.name}</span>
            <span class="min-w-0 truncate font-mono">{repository.path}</span>
          </li>
        </ul>
      </div>

      <.form
        for={@form}
        id="welcome-repository-form"
        phx-change="validate_repository"
        phx-submit="add_repository"
      >
        <div class="grid gap-x-3 sm:grid-cols-[2fr_1fr]">
          <.input
            field={@form[:path]}
            type="text"
            label="Project folder (absolute path)"
            placeholder={Path.join(@home, "code/my-project")}
            autocomplete="off"
            spellcheck="false"
            phx-debounce="300"
          />
          <.input
            field={@form[:name]}
            type="text"
            label="Name (optional)"
            autocomplete="off"
            phx-debounce="300"
          />
        </div>
        <button
          type="submit"
          id="welcome-add-repository"
          class="btn btn-soft mt-1"
          phx-disable-with="Adding…"
        >
          <.icon name="hero-plus-micro" class="size-4" /> Add project
        </button>
      </.form>

      <div
        :if={@note}
        id="welcome-repository-added"
        role="status"
        class="mt-4 flex items-start gap-3 rounded-xl border border-success/30 bg-success/10 p-4 text-sm"
        phx-mounted={JS.transition({"ease-out duration-300", "opacity-0", "opacity-100"})}
      >
        <.icon name="hero-check-circle" class="size-5 shrink-0 text-success" />
        <span>{@note}</span>
      </div>
    </.setup_section>
    """
  end

  attr :setting, :any, required: true
  attr :claude_check, :any, required: true
  attr :opencode_health, :any, required: true
  attr :added_repository, :any, required: true
  attr :repositories, :list, required: true

  defp done(assigns) do
    assigns =
      assigns
      |> assign(:defaults, Settings.default_models())
      |> assign(:claude_effort, Settings.default_effort("claude_code", assigns.setting))
      |> assign(:preset_name, preset_name(Presets.match(assigns.setting)))
      |> assign(:named, assigns.setting.user_display_name not in [nil, "", "You"])

    ~H"""
    <section id="welcome-done" aria-labelledby="welcome-done-title" class="setup-step">
      <div class="flex size-11 items-center justify-center rounded-full bg-success/15 text-success">
        <.icon name="hero-check" class="size-6" />
      </div>
      <h2
        id="welcome-done-title"
        tabindex="-1"
        class="mt-5 text-2xl font-semibold tracking-tight outline-none sm:text-3xl"
      >
        You're set
      </h2>
      <p class="mt-2 text-sm leading-relaxed text-base-content/65">
        Here's what you chose. Each line links to where it lives in Settings.
      </p>

      <ul
        id="welcome-summary"
        class="mt-6 flex flex-col divide-y divide-base-300/70 overflow-hidden rounded-xl bg-base-200/60 text-sm ring-1 ring-inset ring-base-300/60"
      >
        <.summary_line id="summary-name" href={~p"/settings#profile-panel"} icon="hero-user">
          <%= if @named do %>
            You're <strong>{@setting.user_display_name}</strong>.
          <% else %>
            No name yet, so agents call you <strong>You</strong>.
          <% end %>
        </.summary_line>
        <.summary_line id="summary-look" href={~p"/settings#appearance-panel"} icon="hero-swatch">
          <AppearanceComponents.current_appearance id="summary-appearance" />.
        </.summary_line>
        <.summary_line id="summary-engines" href={~p"/settings#claude-panel"} icon="hero-cpu-chip">
          Engines: Claude Code {engine_mark(@claude_check, claude_ready?(@claude_check))},
          OpenCode {engine_mark(@opencode_health, opencode_ready?(@opencode_health))}.
        </.summary_line>
        <.summary_line
          id="summary-default-engine"
          href={~p"/settings#engine-panel"}
          icon="hero-cog-6-tooth"
        >
          Default engine: <strong>{Canopy.Engine.label(Settings.default_engine(@setting))}</strong>.
        </.summary_line>
        <.summary_line id="summary-model" href={~p"/settings#claude-panel"} icon="hero-sparkles">
          Default model: Claude Code <strong>{model_text(@defaults["claude_code"])}</strong>{if @claude_effort,
            do: " (effort #{@claude_effort})"}, OpenCode <strong>{model_text(@defaults["opencode"])}</strong>.
        </.summary_line>
        <.summary_line id="summary-pace" href={~p"/settings#chatter-panel"} icon="hero-hand-raised">
          Agents: <strong>{@preset_name}</strong>.
        </.summary_line>
        <.summary_line
          id="summary-notify"
          href={~p"/settings#notifications-panel"}
          icon="hero-bell"
        >
          Desktop notifications: <NotifyComponents.current_notify id="summary-notify-state" />.
        </.summary_line>
        <.summary_line id="summary-project" href={~p"/repositories"} icon="hero-folder">
          <%= cond do %>
            <% @added_repository -> %>
              Project: <strong>{@added_repository.name}</strong>.
            <% @repositories != [] -> %>
              Projects: <strong>{length(@repositories)}</strong> registered.
            <% true -> %>
              No project yet; add one from Repositories.
          <% end %>
        </.summary_line>
      </ul>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp summary_line(assigns) do
    ~H"""
    <li id={@id}>
      <.link
        navigate={@href}
        class="flex items-center gap-3 px-4 py-3 transition hover:bg-base-300/40"
      >
        <.icon name={@icon} class="size-4 shrink-0 text-base-content/60" />
        <span class="min-w-0 flex-1">{render_slot(@inner_block)}</span>
        <.icon name="hero-chevron-right-micro" class="size-4 shrink-0 text-base-content/40" />
      </.link>
    </li>
    """
  end

  defp engine_mark(value, _ready) when value in [nil, :checking], do: "…"
  defp engine_mark(_value, true), do: "✓"
  defp engine_mark(_value, false), do: "✗"

  defp model_text(%{model_provider: p, model_id: m}) when is_binary(p) and is_binary(m),
    do: "#{p}/#{m}"

  defp model_text(%{model_id: m}) when is_binary(m), do: m
  defp model_text(_default), do: "its own default"

  defp preset_name(:custom), do: "Custom"
  defp preset_name(id), do: Presets.get(id).name
end
