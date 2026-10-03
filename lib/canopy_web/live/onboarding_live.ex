defmodule CanopyWeb.OnboardingLive do
  @moduledoc """
  First-run setup at `/welcome`: one scrolling page with the display name, the
  look (kept in the browser), which engines are ready and the default model for
  each, how much agents may do on their own (a conversation preset), whether
  this browser shows desktop notifications (kept in the browser, like the
  look), and an optional first repository. `/` sends a fresh install here until
  setup is finished or skipped (`Canopy.Settings.onboarded?/0`); Settings →
  *Run setup again* comes back any time.

  Every choice saves as it is made (the name debounced, on change or blur), so
  leaving the page halfway keeps what was chosen; a project is added by its own
  button. Only `onboarded_at` waits for *Finish setup* (or *Skip setup*), after
  which the page shows a summary in place of the sections.

  The old wizard's `?step=` links redirect to the page, at the matching section.
  """
  use CanopyWeb, :live_view

  alias Canopy.{Agents, Repositories, Seeds, Settings}
  alias Canopy.Agents.Agent
  alias Canopy.Engine.ClaudeCode
  alias Canopy.OpenCode.{Client, Providers}
  alias Canopy.Repositories.Repository
  alias Canopy.Settings.Presets
  alias CanopyWeb.{AppearanceComponents, NotifyComponents, PresetComponents}

  @step_anchors %{
    "name" => "welcome-you",
    "theme" => "welcome-look",
    "engines" => "welcome-engines",
    "team" => "welcome-pace",
    "repository" => "welcome-project",
    "done" => "welcome-finish-bar"
  }

  # How long a section's "Saved" stays up.
  @saved_ms 2_500

  @team_fields ["serialize_turns", "chatter_pause", "chatter_limit"]
  @claude_fields ["claude_default_model", "claude_default_effort"]
  @opencode_fields ["opencode_default_provider", "opencode_default_model"]

  @claude_guide "https://tiki51.github.io/canopy-site/getting-started/claude-code/"
  @opencode_guide "https://tiki51.github.io/canopy-site/getting-started/opencode/"

  @impl true
  def mount(%{"step" => step}, _session, socket) do
    to =
      case Map.fetch(@step_anchors, step) do
        {:ok, anchor} -> ~p"/welcome" <> "#" <> anchor
        :error -> ~p"/welcome"
      end

    {:ok, redirect(socket, to: to)}
  end

  def mount(_params, _session, socket) do
    setting = Settings.get()

    socket =
      socket
      |> assign(:page_title, "Welcome")
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
      |> assign(:starter_count, starter_count())
      |> assign(:moved_count, nil)
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

  # -- Skip and finish -----------------------------------------------------------

  @impl true
  def handle_event("skip", _params, socket) do
    {:ok, _} = Settings.mark_onboarded()

    {:noreply,
     socket
     |> put_flash(:info, "Setup skipped. You can run it any time from Settings.")
     |> redirect(to: ~p"/")}
  end

  # A git name still sitting untouched in the field is kept on Finish: it is
  # what the page showed.
  def handle_event("finish", _params, socket) do
    socket = keep_name_suggestion(socket)
    {:ok, setting} = Settings.mark_onboarded()

    {:noreply,
     socket
     |> assign(:finished, true)
     |> assign(:setting, setting)
     |> assign(:repositories, Repositories.list())}
  end

  def handle_event("start_channel", _params, socket) do
    case socket.assigns.added_repository do
      %Repository{id: id} ->
        {:noreply, push_navigate(socket, to: ~p"/channels/new?repository_id=#{id}")}

      nil ->
        {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  def handle_event("look_around", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/agents")}

  # -- You -----------------------------------------------------------------------

  def handle_event("save_name", %{"setting" => params}, socket) do
    socket = assign(socket, :name_touched, true)
    checked = name_changeset(socket.assigns.setting, params)

    cond do
      not checked.valid? ->
        {:noreply,
         assign(socket, :name_form, name_form_from(Map.put(checked, :action, :validate)))}

      not Ecto.Changeset.changed?(checked, :user_display_name) ->
        {:noreply, assign(socket, :name_form, name_form_from(checked))}

      true ->
        case Settings.update(Map.take(params, ["user_display_name"])) do
          {:ok, setting} ->
            {:noreply,
             socket
             |> assign(:setting, setting)
             |> assign(:name_form, name_form_from(Settings.change(setting)))
             |> mark_saved(:you)}

          {:error, changeset} ->
            {:noreply, assign(socket, :name_form, name_form_from(changeset))}
        end
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

  def handle_event("move_starters", _params, socket) do
    if offer_move?(socket.assigns) do
      {:ok, moved} = Agents.move_to_engine(Seeds.agent_names(), "opencode", "claude_code")

      {:noreply,
       socket
       |> assign(:moved_count, moved)
       |> assign(:starter_count, starter_count())
       |> mark_saved(:engines)}
    else
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
    do: {:noreply, assign(socket, :claude_check, result)}

  def handle_async(:claude_check, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :claude_check, {:error, "check crashed: #{inspect(reason)}"})}

  # A path that works is the binary from now on.
  def handle_async(:claude_path, {:ok, {binary, {:ok, _info} = result}}, socket) do
    socket =
      case Settings.update(%{"claude_binary" => binary}) do
        {:ok, setting} -> socket |> assign(:setting, setting) |> mark_saved(:engines)
        {:error, _changeset} -> socket
      end

    {:noreply, assign(socket, :claude_check, result)}
  end

  def handle_async(:claude_path, {:ok, {_binary, result}}, socket),
    do: {:noreply, assign(socket, :claude_check, result)}

  def handle_async(:claude_path, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :claude_check, {:error, "check crashed: #{inspect(reason)}"})}

  def handle_async(:opencode_health, {:ok, {:ok, %{"healthy" => false}}}, socket),
    do: {:noreply, assign(socket, :opencode_health, {:error, :unhealthy})}

  def handle_async(:opencode_health, {:ok, {:ok, body}}, socket),
    do: {:noreply, assign(socket, :opencode_health, {:ok, is_map(body) && body["version"]})}

  def handle_async(:opencode_health, _result, socket),
    do: {:noreply, assign(socket, :opencode_health, {:error, :unreachable})}

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

  # Only Claude Code works, and some starter agents still sit on OpenCode with
  # no model: they would never answer.
  defp offer_move?(assigns) do
    claude_ready?(assigns.claude_check) and match?({:error, _}, assigns.opencode_health) and
      assigns.starter_count > 0
  end

  defp starter_count, do: Agents.movable_count(Seeds.agent_names(), "opencode")

  defp blank?(value), do: value in [nil, ""]

  defp agents_word(1), do: "agent"
  defp agents_word(_n), do: "agents"

  # -- Render --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.focus flash={@flash}>
      <:actions :if={!@finished}>
        <button type="button" id="skip-setup" class="btn btn-ghost btn-sm" phx-click="skip">
          Skip setup
        </button>
      </:actions>

      <%= if @finished do %>
        <.done
          setting={@setting}
          claude_check={@claude_check}
          opencode_health={@opencode_health}
          added_repository={@added_repository}
          repositories={@repositories}
        />
      <% else %>
        <div id="welcome-intro">
          <h1 class="text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
            Welcome to Canopy
          </h1>
          <p class="mt-3 max-w-xl text-base leading-relaxed text-pretty text-base-content/70">
            A few choices and your AI agents are ready to work as a team. Each one saves as you
            make it, and all of them can be changed later in Settings.
          </p>
        </div>

        <.setup_section id="welcome-you" title="You" saved={@saved[:you]}>
          <:description>Shown on your messages. The agents see it too.</:description>
          <.form
            for={@name_form}
            id="welcome-name-form"
            phx-change="save_name"
            phx-submit="save_name"
            class="max-w-sm"
          >
            <.input
              field={@name_form[:user_display_name]}
              type="text"
              label="What should the agents call you?"
              placeholder="Your name"
              autocomplete="name"
              phx-debounce="600"
            />
          </.form>
        </.setup_section>

        <.setup_section id="welcome-look" title="Look">
          <:description>
            Light, dark or the system's, in one of four palettes. It applies as you click and
            is kept in this browser.
          </:description>
          <AppearanceComponents.appearance_picker />
        </.setup_section>

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
          starter_count={@starter_count}
          moved_count={@moved_count}
          release={@release}
        />

        <.setup_section
          id="welcome-pace"
          title="How much agents do on their own"
          saved={@saved[:pace]}
        >
          <:description>
            Agents wake each other by mentioning, delegating and handing off. This decides how
            far that goes before you're back in the loop.
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
            class="mt-3 flex flex-col gap-2 rounded-xl border border-base-300 p-4 [&_.label]:whitespace-normal [&_.label]:items-start"
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

        <%!-- Kept in this browser by notify.js, like the look; the same
             controls as Settings → Notifications. --%>
        <.setup_section id="welcome-notify" title="Notifications" optional>
          <:description>
            Hear about it when an agent needs you and you're looking elsewhere. Applies to this
            browser; Settings has the details.
          </:description>
          <NotifyComponents.notify_prefs kinds={false} />
        </.setup_section>

        <.project_section
          form={@repository_form}
          repositories={@repositories}
          home={@home}
          note={@repository_note}
        />
      <% end %>

      <:footer :if={!@finished}>
        <div id="welcome-finish-bar" class="flex items-center justify-between gap-4">
          <p class="min-w-0 text-sm text-base-content/60">
            <span class="sm:hidden">Saved as you go.</span>
            <span class="hidden sm:inline">Your choices are saved as you go.</span>
          </p>
          <button type="button" id="welcome-finish" class="btn btn-primary" phx-click="finish">
            Finish setup <.icon name="hero-arrow-right-micro" class="size-4" />
          </button>
        </div>
      </:footer>
    </Layouts.focus>
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
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class="scroll-mt-8 border-t border-base-300/70 py-10 first-of-type:mt-10 sm:py-12"
    >
      <div class="flex items-center gap-2.5">
        <h2 id={"#{@id}-title"} class="text-lg font-semibold tracking-tight">{@title}</h2>
        <span
          :if={@optional}
          class="rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-medium text-base-content/60"
        >
          Optional
        </span>
        <span id={"#{@id}-status"} role="status" aria-live="polite" class="ml-auto">
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
      <p class="mt-1 max-w-xl text-sm leading-relaxed text-pretty text-base-content/65">
        {render_slot(@description)}
      </p>
      <div class="mt-6">
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
  attr :starter_count, :integer, required: true
  attr :moved_count, :any, required: true
  attr :release, :boolean, required: true

  defp engines_section(assigns) do
    assigns =
      assigns
      |> assign(:claude_ready, claude_ready?(assigns.claude_check))
      |> assign(:opencode_ready, opencode_ready?(assigns.opencode_health))
      |> assign(:checking, checking?(assigns))
      |> assign(:offer_move, offer_move?(assigns))
      |> assign(:claude_guide, @claude_guide)
      |> assign(:opencode_guide, @opencode_guide)

    ~H"""
    <.setup_section id="welcome-engines" title="Engines" saved={@saved}>
      <:description>
        Agents do their work through a coding engine installed on this Mac. You need at least one.
      </:description>

      <div class="grid gap-3 sm:grid-cols-2">
        <div
          id="welcome-claude"
          data-state={engine_state(@claude_check, @claude_ready)}
          class="flex flex-col gap-2 rounded-xl border border-base-300 bg-base-200 p-4"
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
          class="flex flex-col gap-2 rounded-xl border border-base-300 bg-base-200 p-4"
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
                <span class="mt-1 block text-xs text-base-content/60">
                  Running it somewhere else? Change the URL in <.link
                    navigate={~p"/settings"}
                    class="link link-primary"
                  >Settings</.link>.
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

      <div
        :if={@moved_count}
        id="welcome-moved-starters"
        class="mt-6 flex items-start gap-3 rounded-xl border border-success/30 bg-success/10 p-4 text-sm"
      >
        <.icon name="hero-check-circle" class="size-5 shrink-0 text-success" />
        <span>
          Moved {@moved_count} starter {agents_word(@moved_count)} to Claude Code. They keep
          asking before they edit files.
        </span>
      </div>

      <div
        :if={@offer_move}
        id="welcome-move-starters-block"
        class="mt-6 flex flex-col gap-3 rounded-xl border border-base-300 p-4 sm:flex-row sm:items-center"
      >
        <p class="min-w-0 flex-1 text-sm text-base-content/80">
          {@starter_count} starter {agents_word(@starter_count)} {if @starter_count == 1,
            do: "is",
            else: "are"} set up for OpenCode, which isn't running. Move {if @starter_count == 1,
            do: "it",
            else: "them"} so they can answer; they keep asking
          before they edit files.
        </p>
        <button
          type="button"
          id="welcome-move-starters"
          class="btn btn-soft btn-sm shrink-0"
          phx-click="move_starters"
        >
          Move the {@starter_count} starter {agents_word(@starter_count)} to Claude Code
        </button>
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
          <div :if={@claude_ready} class="grid gap-x-3 sm:grid-cols-2">
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
          <div :if={@opencode_ready} class="grid gap-x-3 sm:grid-cols-2">
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
        </div>
      </.form>
    </.setup_section>
    """
  end

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
        class="mb-5 rounded-xl border border-base-300 bg-base-200 p-4 text-sm"
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
    <section id="welcome-done" aria-labelledby="welcome-done-title">
      <div class="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
        <.icon name="hero-check" class="size-6" />
      </div>
      <h1
        id="welcome-done-title"
        tabindex="-1"
        phx-mounted={JS.focus()}
        class="mt-5 text-3xl font-semibold tracking-tight outline-none sm:text-4xl"
      >
        You're set
      </h1>
      <p class="mt-3 text-base leading-relaxed text-base-content/70">
        Here's what you chose. Each line links to where it lives in Settings.
      </p>

      <ul
        id="welcome-summary"
        class="mt-8 flex flex-col divide-y divide-base-300 rounded-xl border border-base-300 bg-base-200 text-sm"
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

      <div class="mt-8 flex flex-wrap items-center gap-3 pb-12">
        <button
          type="button"
          id="welcome-start-channel"
          class="btn btn-primary"
          phx-click="start_channel"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" /> Start a channel
        </button>
        <button type="button" id="welcome-look-around" class="btn btn-ghost" phx-click="look_around">
          Look around first
        </button>
      </div>
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
