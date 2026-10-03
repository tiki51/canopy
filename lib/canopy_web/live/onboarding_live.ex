defmodule CanopyWeb.OnboardingLive do
  @moduledoc """
  First-run setup at `/welcome`: the display name, the look (kept in the
  browser), which engines are ready and the default model for each, how much
  agents may do on their own (a conversation preset), and the first
  repository. `/` sends a fresh install here until setup is finished or
  skipped (`Canopy.Settings.onboarded?/0`); Settings → *Run setup again*
  comes back any time.

  The step is URL state (`?step=name|theme|engines|team|repository|done`), and
  each *Continue* saves its own step, so closing the tab halfway keeps what was
  chosen. Only `onboarded_at` waits for the end (or for *Skip setup*).
  """
  use CanopyWeb, :live_view

  alias Canopy.{Agents, Repositories, Seeds, Settings}
  alias Canopy.Agents.Agent
  alias Canopy.Engine.ClaudeCode
  alias Canopy.OpenCode.{Client, Providers}
  alias Canopy.Repositories.Repository
  alias Canopy.Settings.Presets
  alias CanopyWeb.{AppearanceComponents, PresetComponents}

  @steps [
    %{id: "name", label: "You"},
    %{id: "theme", label: "Look"},
    %{id: "engines", label: "Engines"},
    %{id: "team", label: "Pace"},
    %{id: "repository", label: "Project"},
    %{id: "done", label: "Done"}
  ]
  @step_ids Enum.map(@steps, & &1.id)

  @claude_guide "https://tiki51.github.io/canopy-site/getting-started/claude-code/"
  @opencode_guide "https://tiki51.github.io/canopy-site/getting-started/opencode/"

  @impl true
  def mount(_params, _session, socket) do
    setting = Settings.get()

    socket =
      socket
      |> assign(:page_title, "Welcome")
      |> assign(:steps, Enum.map(@steps, &Map.put(&1, :path, step_path(&1.id))))
      |> assign(:step, "name")
      |> assign(:setting, setting)
      |> assign(:name_touched, false)
      |> assign(:name_form, name_form(setting))
      |> assign(:claude_check, nil)
      |> assign(:opencode_health, nil)
      |> assign(:providers, [])
      |> assign(:providers_state, :loading)
      |> assign(:engines_form, to_form(Settings.change(setting), id: "welcome-engines-form"))
      |> assign(:claude_path_form, claude_path_form(""))
      |> assign(:move_starters, true)
      |> assign(:starter_count, 0)
      |> assign(:preset, Presets.match(setting))
      |> assign(:team_form, to_form(Settings.change(setting), id: "welcome-team-form"))
      |> assign(:repository_form, repository_form(Repositories.change(%Repository{})))
      |> assign(:repositories, Repositories.list())
      |> assign(:added_repository, nil)
      |> assign(:home, System.user_home!())
      |> assign(:release, System.get_env("RELEASE_ROOT") not in [nil, ""])

    # Still "You": suggest the name git knows, unless the user types first.
    socket =
      if connected?(socket) and not Settings.user_named?(),
        do: start_async(socket, :git_name, &git_user_name/0),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    step = if params["step"] in @step_ids, do: params["step"], else: "name"
    {:noreply, socket |> assign(:step, step) |> enter_step(step)}
  end

  # The engines are checked the first time a step needs them (both at once);
  # *Check again* repeats it.
  defp enter_step(socket, step) when step in ["engines", "done"] do
    socket =
      socket
      |> assign(:setting, Settings.get())
      |> assign(:starter_count, starter_count())

    if connected?(socket) and is_nil(socket.assigns.claude_check) and
         is_nil(socket.assigns.opencode_health),
       do: check_engines(socket),
       else: socket
  end

  defp enter_step(socket, "repository"), do: assign(socket, :repositories, Repositories.list())
  defp enter_step(socket, _step), do: assign(socket, :setting, Settings.get())

  # -- Skip and finish -----------------------------------------------------------

  @impl true
  def handle_event("skip", _params, socket) do
    {:ok, _} = Settings.mark_onboarded()

    {:noreply,
     socket
     |> put_flash(:info, "Setup skipped. You can run it any time from Settings.")
     |> redirect(to: ~p"/")}
  end

  def handle_event("finish", _params, socket) do
    {:ok, _} = Settings.mark_onboarded()

    case socket.assigns.added_repository do
      %Repository{id: id} ->
        {:noreply, push_navigate(socket, to: ~p"/channels/new?repository_id=#{id}")}

      nil ->
        {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  def handle_event("look_around", _params, socket) do
    {:ok, _} = Settings.mark_onboarded()
    {:noreply, push_navigate(socket, to: ~p"/agents")}
  end

  # -- Name ----------------------------------------------------------------------

  def handle_event("validate_name", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> name_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:name_touched, true)
     |> assign(:name_form, to_form(changeset, id: "welcome-name-form"))}
  end

  def handle_event("save_name", %{"setting" => params}, socket) do
    checked = name_changeset(socket.assigns.setting, params)

    result =
      if checked.valid?,
        do: Settings.update(Map.take(params, ["user_display_name"])),
        else: {:error, Map.put(checked, :action, :update)}

    case result do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:name_touched, true)
         |> assign(:name_form, name_form(setting))
         |> push_patch(to: step_path("theme"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :name_form, to_form(changeset, id: "welcome-name-form"))}
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

  def handle_event("validate_engines", params, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(engine_attrs(params["setting"] || %{}, socket.assigns))
      |> Providers.validate(socket.assigns.providers, opencode_fields())
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:engines_form, to_form(changeset, id: "welcome-engines-form"))
     |> assign(:move_starters, truthy?(params["move_starters"]))}
  end

  def handle_event("save_engines", params, socket) do
    attrs = engine_attrs(params["setting"] || %{}, socket.assigns)

    checked =
      socket.assigns.setting
      |> Settings.change(attrs)
      |> Providers.validate(socket.assigns.providers, opencode_fields())

    if checked.errors == [] do
      :ok = save_defaults(attrs)

      moved =
        if offer_move?(socket.assigns) and truthy?(params["move_starters"]) do
          {:ok, n} = Agents.move_to_engine(Seeds.agent_names(), "opencode", "claude_code")
          n
        else
          0
        end

      setting = Settings.get()

      socket =
        socket
        |> assign(:setting, setting)
        |> assign(:starter_count, starter_count())
        |> assign(:engines_form, to_form(Settings.change(setting), id: "welcome-engines-form"))
        |> push_patch(to: step_path("team"))

      {:noreply,
       if(moved > 0,
         do:
           put_flash(
             socket,
             :info,
             "Moved #{moved} starter #{if moved == 1, do: "agent", else: "agents"} to Claude Code."
           ),
         else: socket
       )}
    else
      {:noreply,
       assign(
         socket,
         :engines_form,
         to_form(Map.put(checked, :action, :update), id: "welcome-engines-form")
       )}
    end
  end

  # -- Team ----------------------------------------------------------------------

  def handle_event("pick_preset", %{"preset" => id}, socket) do
    preset =
      case Presets.get(id) do
        %{id: preset} -> preset
        nil -> :custom
      end

    {:noreply, assign(socket, :preset, preset)}
  end

  @team_fields ["serialize_turns", "chatter_pause", "chatter_limit"]

  def handle_event("validate_team", params, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params["setting"] || %{}, @team_fields))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :team_form, to_form(changeset, id: "welcome-team-form"))}
  end

  def handle_event("save_team", params, socket) do
    attrs =
      case socket.assigns.preset do
        :custom -> Map.take(params["setting"] || %{}, @team_fields)
        id -> Presets.get(id).attrs
      end

    case Settings.update(attrs) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:preset, Presets.match(setting))
         |> assign(:team_form, to_form(Settings.change(setting), id: "welcome-team-form"))
         |> push_patch(to: step_path("repository"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :team_form, to_form(changeset, id: "welcome-team-form"))}
    end
  end

  # -- Repository ----------------------------------------------------------------

  def handle_event("validate_repository", %{"repository" => params}, socket) do
    changeset =
      %Repository{}
      |> Repositories.change(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :repository_form, repository_form(changeset))}
  end

  # A blank path moves on when there is a repository already (a re-run).
  def handle_event("save_repository", %{"repository" => params}, socket) do
    path = String.trim(params["path"] || "")

    if path == "" and socket.assigns.repositories != [] do
      {:noreply, push_patch(socket, to: step_path("done"))}
    else
      initialised? = Repositories.needs_init?(path)

      case Repositories.create(params) do
        {:ok, repository} ->
          note =
            if initialised?,
              do: " It was not a git repository yet, so one was initialised.",
              else: ""

          {:noreply,
           socket
           |> assign(:added_repository, repository)
           |> assign(:repositories, Repositories.list())
           |> assign(:repository_form, repository_form(Repositories.change(%Repository{})))
           |> put_flash(:info, "Added #{repository.name}.#{note}")
           |> push_patch(to: step_path("done"))}

        {:error, changeset} ->
          {:noreply, assign(socket, :repository_form, repository_form(changeset))}
      end
    end
  end

  # -- Async ---------------------------------------------------------------------

  @impl true
  def handle_async(:git_name, {:ok, name}, socket) when is_binary(name) and name != "" do
    if socket.assigns.name_touched do
      {:noreply, socket}
    else
      changeset = Settings.change(socket.assigns.setting, %{"user_display_name" => name})
      {:noreply, assign(socket, :name_form, to_form(changeset, id: "welcome-name-form"))}
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
        {:ok, setting} -> assign(socket, :setting, setting)
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

  # -- Helpers -------------------------------------------------------------------

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

  defp step_path(step), do: ~p"/welcome?step=#{step}"

  defp name_form(setting) do
    # "You" is the placeholder name, not one to keep: start from an empty field.
    setting = if Settings.user_named?(), do: setting, else: %{setting | user_display_name: nil}
    to_form(Settings.change(setting), id: "welcome-name-form")
  end

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

  defp repository_form(changeset), do: to_form(changeset, id: "welcome-repository-form")

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
        do: Map.take(params, ["claude_default_model", "claude_default_effort"]),
        else: %{}

    opencode =
      if opencode_ready?(assigns.opencode_health) do
        attrs = Map.take(params, ["opencode_default_provider", "opencode_default_model"])

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

  defp truthy?(value), do: value in [true, "true", "on"]

  defp blank?(value), do: value in [nil, ""]

  # -- Render --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.focus flash={@flash} steps={@steps} current={@step}>
      <:actions :if={@step != "done"}>
        <button type="button" id="skip-setup" class="btn btn-ghost btn-sm" phx-click="skip">
          Skip setup
        </button>
      </:actions>

      <%= case @step do %>
        <% "name" -> %>
          <.name_step form={@name_form} />
        <% "theme" -> %>
          <.theme_step />
        <% "engines" -> %>
          <.engines_step
            claude_check={@claude_check}
            opencode_health={@opencode_health}
            opencode_url={@setting.opencode_url}
            setting={@setting}
            providers={@providers}
            providers_state={@providers_state}
            form={@engines_form}
            claude_path_form={@claude_path_form}
            move_starters={@move_starters}
            starter_count={@starter_count}
            release={@release}
          />
        <% "team" -> %>
          <.team_step form={@team_form} preset={@preset} />
        <% "repository" -> %>
          <.repository_step form={@repository_form} repositories={@repositories} home={@home} />
        <% "done" -> %>
          <.done_step
            setting={@setting}
            claude_check={@claude_check}
            opencode_health={@opencode_health}
            added_repository={@added_repository}
            repositories={@repositories}
          />
      <% end %>

      <:footer :if={@step != "done"}>
        <.link
          :if={previous_step(@step)}
          patch={step_path(previous_step(@step))}
          id="welcome-back"
          class="btn btn-ghost"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> Back
        </.link>
        <span :if={!previous_step(@step)}></span>
        <div class="flex items-center gap-2">
          <.link
            :if={@step == "repository"}
            patch={step_path("done")}
            id="welcome-skip-repository"
            class="btn btn-ghost"
          >
            Skip this step
          </.link>
          <.continue_button step={@step} />
        </div>
      </:footer>
    </Layouts.focus>
    """
  end

  defp previous_step(step) do
    index = Enum.find_index(@step_ids, &(&1 == step))
    if index > 0, do: Enum.at(@step_ids, index - 1)
  end

  attr :step, :string, required: true

  # Steps with a form submit it (and move on from its save); the theme step has
  # nothing to save.
  defp continue_button(%{step: "theme"} = assigns) do
    ~H"""
    <.button patch={step_path("engines")} variant="primary" id="welcome-continue">
      Continue <.icon name="hero-arrow-right-micro" class="size-4" />
    </.button>
    """
  end

  defp continue_button(assigns) do
    ~H"""
    <.button type="submit" form={"welcome-#{@step}-form"} variant="primary" id="welcome-continue">
      Continue <.icon name="hero-arrow-right-micro" class="size-4" />
    </.button>
    """
  end

  attr :title, :string, required: true
  slot :inner_block

  defp step_heading(assigns) do
    ~H"""
    <div class="mb-6">
      <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
      <div :if={@inner_block != []} class="mt-2 text-sm leading-relaxed text-base-content/70">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :form, :any, required: true

  defp name_step(assigns) do
    ~H"""
    <section id="welcome-name">
      <.step_heading title="Welcome to Canopy">
        Canopy is where your AI agents work as a team: they talk in channels, hand work to each
        other, and check in with you. A few questions and you're ready. Everything here can be
        changed later in Settings.
      </.step_heading>
      <.form
        for={@form}
        id="welcome-name-form"
        phx-change="validate_name"
        phx-submit="save_name"
        class="max-w-md"
      >
        <.input
          field={@form[:user_display_name]}
          type="text"
          label="What should the agents call you?"
          placeholder="Your name"
          autocomplete="name"
          phx-debounce="200"
        />
        <p class="-mt-1 text-xs text-base-content/60">Shown on your messages. Agents see it too.</p>
      </.form>
    </section>
    """
  end

  defp theme_step(assigns) do
    ~H"""
    <section id="welcome-theme">
      <.step_heading title="Pick a look">
        Applies instantly in this browser. The sun/moon switch in the left rail changes it later.
      </.step_heading>
      <AppearanceComponents.appearance_picker />
    </section>
    """
  end

  attr :claude_check, :any, required: true
  attr :opencode_health, :any, required: true
  attr :opencode_url, :string, required: true
  attr :setting, :any, required: true
  attr :providers, :list, required: true
  attr :providers_state, :atom, required: true
  attr :form, :any, required: true
  attr :claude_path_form, :any, required: true
  attr :move_starters, :boolean, required: true
  attr :starter_count, :integer, required: true
  attr :release, :boolean, required: true

  defp engines_step(assigns) do
    assigns =
      assigns
      |> assign(:claude_ready, claude_ready?(assigns.claude_check))
      |> assign(:opencode_ready, opencode_ready?(assigns.opencode_health))
      |> assign(:checking, checking?(assigns))
      |> assign(:offer_move, offer_move?(assigns))
      |> assign(:claude_guide, @claude_guide)
      |> assign(:opencode_guide, @opencode_guide)

    ~H"""
    <section id="welcome-engines">
      <.step_heading title="Your engines">
        Agents do their work through a coding engine installed on this Mac. You need at least one.
      </.step_heading>

      <div class="grid gap-3 sm:grid-cols-2">
        <div
          id="welcome-claude"
          data-state={engine_state(@claude_check, @claude_ready)}
          class="flex flex-col gap-2 rounded-xl border border-base-300 bg-base-200 p-4"
        >
          <div class="flex items-center gap-2">
            <.engine_icon state={engine_state(@claude_check, @claude_ready)} />
            <h2 class="text-sm font-semibold">Claude Code</h2>
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
            <h2 class="text-sm font-semibold">OpenCode</h2>
          </div>
          <div id="welcome-opencode-status" class="text-sm text-base-content/80" role="status">
            <%= case @opencode_health do %>
              <% value when value in [nil, :checking] -> %>
                <span class="text-base-content/60">Checking…</span>
              <% {:ok, version} -> %>
                OpenCode{if version, do: " #{version}"} at <code class="font-mono text-xs">{@opencode_url}</code>.
              <% {:error, _reason} -> %>
                Not running at <code class="font-mono text-xs">{@opencode_url}</code>.
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
        for={@form}
        id="welcome-engines-form"
        phx-change="validate_engines"
        phx-submit="save_engines"
        class="mt-6"
      >
        <div
          :if={@claude_ready or @opencode_ready}
          id="welcome-default-model"
          class="flex flex-col gap-3 rounded-xl border border-base-300 p-4"
        >
          <div>
            <h2 class="text-sm font-semibold">Default model for new agents</h2>
            <p class="mt-0.5 text-xs text-base-content/60">
              Agents without their own model use this. You can still pick a model per agent on
              the Agents page.
            </p>
          </div>
          <div :if={@claude_ready} class="grid gap-3 sm:grid-cols-2">
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
          <div :if={@opencode_ready} class="grid gap-3 sm:grid-cols-2">
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
          <div :if={@offer_move} id="welcome-move-starters-block">
            <.input
              type="checkbox"
              id="welcome-move-starters"
              name="move_starters"
              value={@move_starters}
              label={"Move the #{@starter_count} starter #{if @starter_count == 1, do: "agent", else: "agents"} to Claude Code"}
            />
            <p class="-mt-1 text-xs text-base-content/60">
              They are set up for OpenCode, which isn't running. Only starter agents still on
              OpenCode with no model of their own move; they keep asking before they edit files.
            </p>
          </div>
        </div>
      </.form>
    </section>
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
  attr :preset, :atom, required: true

  defp team_step(assigns) do
    ~H"""
    <section id="welcome-team">
      <.step_heading title="How much should agents do on their own?">
        Agents wake each other: by @-mentioning, by delegating, by handing work off. These
        controls decide how far that goes before you're back in the loop.
      </.step_heading>

      <PresetComponents.preset_cards
        id="welcome-presets"
        selected={@preset}
        event="pick_preset"
        custom
      />

      <.form
        for={@form}
        id="welcome-team-form"
        phx-change="validate_team"
        phx-submit="save_team"
        class="mt-4"
      >
        <div
          :if={@preset == :custom}
          id="welcome-team-custom"
          class="flex flex-col gap-2 rounded-xl border border-base-300 p-4"
        >
          <.input
            field={@form[:serialize_turns]}
            type="checkbox"
            label="One agent at a time per channel"
          />
          <.input
            field={@form[:chatter_pause]}
            type="checkbox"
            label="Pause a channel after agents have taken turns without me"
          />
          <div class="max-w-xs">
            <.input
              field={@form[:chatter_limit]}
              type="number"
              min="1"
              max="1000"
              label="Turns before pausing"
            />
          </div>
        </div>
      </.form>

      <p class="mt-4 text-xs text-base-content/60">
        A paused channel shows a Continue button; your next message also resumes it.
      </p>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :repositories, :list, required: true
  attr :home, :string, required: true

  defp repository_step(assigns) do
    ~H"""
    <section id="welcome-repository">
      <.step_heading title="Add your first project">
        Agents work inside a git repository on this Mac. Point Canopy at a project folder; if it
        isn't a git repo yet, Canopy runs <code class="font-mono">git init</code> for you.
      </.step_heading>

      <div
        :if={@repositories != []}
        id="welcome-repositories"
        class="mb-4 rounded-xl border border-base-300 bg-base-200 p-4 text-sm"
      >
        <p>
          You already have {length(@repositories)}. Add another or continue.
        </p>
        <ul class="mt-2 flex flex-col gap-1 text-xs text-base-content/70">
          <li :for={repository <- @repositories} class="flex items-center gap-2">
            <.icon name="hero-folder-micro" class="size-4 shrink-0" />
            <span class="font-medium text-base-content">{repository.name}</span>
            <span class="min-w-0 truncate font-mono">{repository.path}</span>
          </li>
        </ul>
      </div>

      <.form
        for={@form}
        id="welcome-repository-form"
        phx-change="validate_repository"
        phx-submit="save_repository"
        class="grid gap-3 sm:grid-cols-[2fr_1fr]"
      >
        <.input
          field={@form[:path]}
          type="text"
          label="Project folder (absolute path)"
          placeholder={Path.join(@home, "code/my-project")}
          autocomplete="off"
          spellcheck="false"
        />
        <.input
          field={@form[:name]}
          type="text"
          label="Name (optional)"
          autocomplete="off"
        />
      </.form>
    </section>
    """
  end

  attr :setting, :any, required: true
  attr :claude_check, :any, required: true
  attr :opencode_health, :any, required: true
  attr :added_repository, :any, required: true
  attr :repositories, :list, required: true

  defp done_step(assigns) do
    assigns =
      assigns
      |> assign(:defaults, Settings.default_models())
      |> assign(:claude_effort, Settings.default_effort("claude_code", assigns.setting))
      |> assign(:preset_name, preset_name(Presets.match(assigns.setting)))

    ~H"""
    <section id="welcome-done">
      <.step_heading title="You're set">
        Here's what you chose. Each line links to where it lives in Settings.
      </.step_heading>

      <ul
        id="welcome-summary"
        class="flex flex-col divide-y divide-base-300 rounded-xl border border-base-300 bg-base-200 text-sm"
      >
        <.summary_line id="summary-name" href={~p"/settings#profile-panel"} icon="hero-user">
          You're <strong>{@setting.user_display_name}</strong>.
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

      <div class="mt-8 flex flex-wrap items-center gap-3">
        <button type="button" id="welcome-finish" class="btn btn-primary" phx-click="finish">
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
