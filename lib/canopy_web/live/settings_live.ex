defmodule CanopyWeb.SettingsLive do
  @moduledoc """
  Settings: the default engine agents without one of their own run on (with
  which engines are ready and how many agents follow it), the OpenCode server
  URL (with a connection check), the Claude Code
  binary (with a version and login check), the `gh` binary GitHub watches use
  (with the same check), each engine's default model (and
  Claude Code's default effort) with how many agents use it, each engine's
  light model for model routing (experimental), the local user's display name,
  appearance (light/dark mode and colour palette, kept in the browser), the
  collaboration preamble every agent is given, and the MCP section (identity
  plugin source, endpoint URL, token).
  """
  use CanopyWeb, :live_view

  alias Canopy.{Agents, MCP}
  alias Canopy.Agents.Agent
  alias Canopy.OpenCode.{Client, Providers}
  alias Canopy.Runtime.Prompts
  alias Canopy.Settings
  alias Canopy.Settings.Presets
  alias CanopyWeb.{AppearanceComponents, EngineComponents, NotifyComponents, PresetComponents}

  @opencode_default_fields {:opencode_default_provider, :opencode_default_model}
  @opencode_light_fields {:opencode_light_provider, :opencode_light_model}

  @impl true
  def mount(_params, _session, socket) do
    setting = Settings.get()
    if connected?(socket), do: Settings.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:providers, [])
     |> assign(:providers_state, :loading)
     |> then(&if(connected?(&1), do: load_providers(&1), else: &1))
     |> assign_usage()
     |> assign(:setting, setting)
     |> assign(:opencode_form, to_form(Settings.change(setting), id: "opencode-form"))
     |> assign(:claude_form, to_form(Settings.change(setting), id: "claude-form"))
     |> assign(:claude_check, nil)
     |> assign(:claude_found, claude_found?())
     |> assign(:gh_form, to_form(Settings.change(setting), id: "gh-form"))
     |> assign(:gh_check, nil)
     |> assign(:profile_form, to_form(Settings.change(setting), id: "profile-form"))
     |> assign(:chatter_form, to_form(Settings.change(setting), id: "chatter-form"))
     |> assign(:prompt_form, prompt_form(setting))
     |> assign(:draft_url, setting.opencode_url)
     |> assign(:health, nil)
     |> assign(:token_visible, false)
     |> assign(:plugin_path, MCP.global_plugin_path())
     |> assign(:plugin_source, MCP.plugin_source())
     |> assign(:mcp_url, MCP.url())
     |> assign(:mcp_name, MCP.registration_name())
     |> assign(:files_dir, Canopy.Documents.Store.dir())
     |> assign(:files_limit, Canopy.Documents.max_bytes())
     |> assign(:files_count, Canopy.Documents.count())
     |> assign(:files_bytes, Canopy.Documents.total_bytes())}
  end

  @impl true
  def handle_event("validate_opencode", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(opencode_attrs(params))
      |> validate_default(socket.assigns.providers)
      |> Map.put(:action, :validate)

    url = String.trim(params["opencode_url"] || "")

    {:noreply,
     socket
     |> assign(:opencode_form, to_form(changeset, id: "opencode-form"))
     |> assign(:draft_url, url)
     |> assign(:health, if(url == socket.assigns.draft_url, do: socket.assigns.health))}
  end

  # The default model is checked against the provider list; while OpenCode is
  # away its selects are disabled, so they are not submitted and keep their value.
  def handle_event("save_opencode", %{"setting" => params}, socket) do
    attrs = opencode_attrs(params)

    checked =
      socket.assigns.setting
      |> Settings.change(attrs)
      |> validate_default(socket.assigns.providers)

    result =
      if checked.errors == [],
        do: Settings.update(attrs),
        else: {:error, Map.put(checked, :action, :update)}

    case result do
      {:ok, setting} ->
        url_changed? = setting.opencode_url != socket.assigns.setting.opencode_url

        socket =
          socket
          |> assign(:setting, setting)
          |> assign(:draft_url, setting.opencode_url)
          |> assign(:opencode_form, to_form(Settings.change(setting), id: "opencode-form"))
          |> assign_usage()
          |> put_flash(:info, opencode_saved(checked))

        {:noreply, if(url_changed?, do: load_providers(socket), else: socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :opencode_form, to_form(changeset, id: "opencode-form"))}
    end
  end

  # Agents on the default start a fresh session on the new engine at their
  # next wake in each channel (the channel compares the session's engine).
  def handle_event("pick_default_engine", %{"engine" => engine}, socket) do
    before = Settings.default_engine(socket.assigns.setting)

    case Settings.put_default_engine(engine) do
      {:ok, setting} ->
        socket = socket |> assign(:setting, setting) |> assign_usage()

        message =
          if engine == before,
            do: "#{Canopy.Engine.label(engine)} is the default engine.",
            else: default_engine_saved(engine, socket.assigns.engine_usage.default)

        {:noreply, put_flash(socket, :info, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change the default engine.")}
    end
  end

  # Clears every active agent's own engine, after the confirmation on the button.
  def handle_event("inherit_default_engine", _params, socket) do
    {:ok, count} = Agents.inherit_default_engine()

    message =
      if count == 1,
        do: "1 agent now uses the default engine.",
        else: "#{count} agents now use the default engine."

    {:noreply, socket |> assign_usage() |> put_flash(:info, message)}
  end

  # Clears every active agent's own model (or effort) on that engine, after
  # the confirmation on the button.
  def handle_event("inherit_default", %{"engine" => engine, "kind" => kind}, socket)
      when engine in ["claude_code", "opencode"] and kind in ["model", "effort"] do
    {:ok, count} =
      if kind == "model",
        do: Agents.inherit_default_model(engine),
        else: Agents.inherit_default_effort(engine)

    message =
      if count == 1,
        do: "1 #{Canopy.Engine.label(engine)} agent now uses the default #{kind}.",
        else: "#{count} #{Canopy.Engine.label(engine)} agents now use the default #{kind}."

    {:noreply, socket |> assign_usage() |> put_flash(:info, message)}
  end

  @claude_fields [
    "claude_binary",
    "claude_config_dir",
    "claude_max_budget_usd",
    "claude_default_model",
    "claude_default_effort",
    "claude_light_model",
    "claude_light_effort"
  ]

  def handle_event("validate_claude", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, @claude_fields))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:claude_form, to_form(changeset, id: "claude-form"))
     |> assign(:claude_check, nil)}
  end

  def handle_event("save_claude", %{"setting" => params}, socket) do
    attrs = Map.take(params, @claude_fields)
    changeset = Settings.change(socket.assigns.setting, attrs)

    case Settings.update(attrs) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:claude_form, to_form(Settings.change(setting), id: "claude-form"))
         |> assign_usage()
         |> put_flash(:info, claude_saved(changeset))}

      {:error, changeset} ->
        {:noreply, assign(socket, :claude_form, to_form(changeset, id: "claude-form"))}
    end
  end

  # Runs the binary named in the form (saved or not): version and login state.
  def handle_event("check_claude", _params, socket) do
    binary = socket.assigns.claude_form[:claude_binary].value |> to_string() |> String.trim()
    config_dir = socket.assigns.claude_form[:claude_config_dir].value

    if binary == "" do
      {:noreply, assign(socket, :claude_check, {:error, "enter the binary first"})}
    else
      {:noreply,
       socket
       |> assign(:claude_check, :checking)
       |> start_async(:claude_check, fn -> Canopy.Engine.ClaudeCode.check(binary, config_dir) end)}
    end
  end

  def handle_event("validate_gh", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, ["gh_binary"]))
      |> Map.put(:action, :validate)

    {:noreply,
     socket |> assign(:gh_form, to_form(changeset, id: "gh-form")) |> assign(:gh_check, nil)}
  end

  def handle_event("save_gh", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, ["gh_binary"])) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:gh_form, to_form(Settings.change(setting), id: "gh-form"))
         |> put_flash(:info, "Saved the gh binary; watches use it from their next check.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :gh_form, to_form(changeset, id: "gh-form"))}
    end
  end

  # Runs the saved binary: version and login state.
  def handle_event("check_gh", _params, socket) do
    {:noreply,
     socket
     |> assign(:gh_check, :checking)
     |> start_async(:gh_check, fn -> Canopy.GitHub.status() end)}
  end

  def handle_event("check_connection", _params, socket) do
    url = socket.assigns.draft_url

    if url == "" do
      {:noreply, assign(socket, :health, {:error, "enter a server URL first"})}
    else
      {:noreply,
       socket
       |> assign(:health, :checking)
       |> start_async(:health, fn -> Client.impl().health(base_url: url) end)}
    end
  end

  def handle_event("validate_profile", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, ["user_display_name"]))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset, id: "profile-form"))}
  end

  def handle_event("save_profile", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, ["user_display_name"])) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:profile_form, to_form(Settings.change(setting), id: "profile-form"))
         |> put_flash(:info, "Display name saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, id: "profile-form"))}
    end
  end

  @chatter_fields [
    "chatter_pause",
    "chatter_limit",
    "serialize_turns",
    "interrupt_on_mention",
    "question_wait_minutes",
    "lock_hold_minutes"
  ]

  def handle_event("validate_chatter", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(Map.take(params, @chatter_fields))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :chatter_form, to_form(changeset, id: "chatter-form"))}
  end

  def handle_event("save_chatter", %{"setting" => params}, socket) do
    case Settings.update(Map.take(params, @chatter_fields)) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:chatter_form, to_form(Settings.change(setting), id: "chatter-form"))
         |> put_flash(:info, chatter_saved(setting))}

      {:error, changeset} ->
        {:noreply, assign(socket, :chatter_form, to_form(changeset, id: "chatter-form"))}
    end
  end

  # A preset card saves its brakes at once.
  def handle_event("apply_preset", %{"preset" => id}, socket) do
    case Presets.get(id) do
      nil ->
        {:noreply, socket}

      preset ->
        case Settings.update(preset.attrs) do
          {:ok, setting} ->
            {:noreply,
             socket
             |> assign(:setting, setting)
             |> assign(:chatter_form, to_form(Settings.change(setting), id: "chatter-form"))
             |> put_flash(:info, "#{preset.name} preset saved. #{chatter_saved(setting)}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not apply the #{preset.name} preset.")}
        end
    end
  end

  def handle_event("validate_prompt", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change(prompt_attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :prompt_form, to_form(changeset, id: "prompt-form"))}
  end

  def handle_event("save_prompt", %{"setting" => params}, socket) do
    case Settings.update(prompt_attrs(params)) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:prompt_form, prompt_form(setting))
         |> put_flash(:info, prompt_saved(setting))}

      {:error, changeset} ->
        {:noreply, assign(socket, :prompt_form, to_form(changeset, id: "prompt-form"))}
    end
  end

  def handle_event("reset_prompt", _params, socket) do
    case Settings.update(%{"collaboration_prompt" => nil}) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> assign(:prompt_form, prompt_form(setting))
         |> put_flash(:info, "Collaboration prompt reset to the one Canopy ships.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not reset the prompt.")}
    end
  end

  def handle_event("toggle_token", _params, socket) do
    {:noreply, update(socket, :token_visible, &(!&1))}
  end

  def handle_event("rotate_token", _params, socket) do
    case Settings.rotate_mcp_token() do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting, setting)
         |> put_flash(
           :info,
           "MCP token rotated. OpenCode is re-registered automatically the next time an agent is prompted."
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not rotate the MCP token.")}
    end
  end

  @impl true
  def handle_info({:settings, :default_models_changed}, socket) do
    {:noreply, socket |> assign(:setting, Settings.get()) |> assign_usage()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A server that just answered may have been started since the page loaded:
  # its models make the default selects usable.
  @impl true
  def handle_async(:health, {:ok, result}, socket) do
    health = normalize_health(result)

    socket =
      if match?({:ok, _}, health) and socket.assigns.providers_state != :ok and
           socket.assigns.draft_url == socket.assigns.setting.opencode_url,
         do: load_providers(socket),
         else: socket

    {:noreply, assign(socket, :health, health)}
  end

  def handle_async(:providers, {:ok, {:ok, %{providers: [_ | _] = providers}}}, socket),
    do: {:noreply, socket |> assign(:providers, providers) |> assign(:providers_state, :ok)}

  def handle_async(:providers, _other, socket),
    do: {:noreply, socket |> assign(:providers, []) |> assign(:providers_state, :error)}

  def handle_async(:claude_check, {:ok, result}, socket),
    do: {:noreply, assign(socket, :claude_check, result)}

  def handle_async(:gh_check, {:ok, result}, socket),
    do: {:noreply, assign(socket, :gh_check, result)}

  def handle_async(:gh_check, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :gh_check, {:error, "check crashed: #{inspect(reason)}"})}

  def handle_async(:claude_check, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :claude_check, {:error, "check crashed: #{inspect(reason)}"})}

  def handle_async(:health, {:exit, reason}, socket) do
    {:noreply, assign(socket, :health, {:error, "check crashed: #{inspect(reason)}"})}
  end

  defp normalize_health({:ok, %{} = body}) do
    healthy = Map.get(body, "healthy", true)
    version = Map.get(body, "version")

    if healthy,
      do: {:ok, version},
      else: {:error, "server reports unhealthy" <> if(version, do: " (#{version})", else: "")}
  end

  defp normalize_health({:ok, _other}), do: {:ok, nil}
  defp normalize_health({:error, reason}), do: {:error, describe_error(reason)}

  defp describe_error({:transport, %{reason: :econnrefused}}),
    do: "connection refused. Is `opencode serve` running?"

  defp describe_error({:transport, %{reason: :nxdomain}}), do: "host not found"
  defp describe_error({:transport, %{reason: :timeout}}), do: "timed out"

  defp describe_error({:transport, %{reason: reason}}),
    do: "connection failed (#{inspect(reason)})"

  defp describe_error({:transport, reason}), do: "connection failed (#{inspect(reason)})"
  defp describe_error({:http, status, _body}), do: "server answered HTTP #{status}"
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  # The URL, plus the default model when its selects were submitted. No
  # provider means OpenCode's own default, whatever the (disabled, so maybe
  # unsubmitted) model select still holds.
  defp opencode_attrs(params) do
    params
    |> Map.take([
      "opencode_url",
      "opencode_default_provider",
      "opencode_default_model",
      "opencode_light_provider",
      "opencode_light_model"
    ])
    |> pair_model("opencode_default_provider", "opencode_default_model")
    |> pair_model("opencode_light_provider", "opencode_light_model")
  end

  defp pair_model(attrs, provider_key, model_key) do
    case Map.fetch(attrs, provider_key) do
      {:ok, provider} when provider in [nil, ""] -> Map.put(attrs, model_key, nil)
      {:ok, _provider} -> Map.put_new(attrs, model_key, nil)
      :error -> attrs
    end
  end

  # Only a default being changed is checked against OpenCode's list: one that
  # stopped working shows "(not configured)" but must not block saving the URL.
  defp validate_default(changeset, providers) do
    Enum.reduce([@opencode_default_fields, @opencode_light_fields], changeset, fn {p, m} =
                                                                                    fields,
                                                                                  acc ->
      if Ecto.Changeset.changed?(acc, p) or Ecto.Changeset.changed?(acc, m),
        do: Providers.validate(acc, providers, fields),
        else: acc
    end)
  end

  # From the saved server URL.
  defp load_providers(socket) do
    socket
    |> assign(:providers_state, :loading)
    |> start_async(:providers, fn -> Providers.list() end)
  end

  defp assign_usage(socket) do
    socket
    |> assign(:engine_usage, Agents.engine_usage())
    |> assign(:usage, %{
      "claude_code" => %{
        model: Agents.model_usage("claude_code"),
        effort: Agents.effort_usage("claude_code")
      },
      "opencode" => %{model: Agents.model_usage("opencode")}
    })
  end

  defp engine_usage_text(%{default: default, own: own}) do
    "#{default} #{agents_word(default)} #{if default == 1, do: "uses", else: "use"} the default · " <>
      "#{own} #{if own == 1, do: "has its", else: "have their"} own"
  end

  defp default_engine_saved(engine, n) do
    who =
      if n == 1,
        do: "1 agent on the default starts",
        else: "#{n} agents on the default start"

    "#{Canopy.Engine.label(engine)} is the default engine. #{who} a fresh #{Canopy.Engine.label(engine)} session at their next turn in each channel; memory and channel history carry over."
  end

  # Whether each engine is ready, for the default engine cards: the last
  # check when there was one, else what the page knows without asking
  # (OpenCode's model list; whether the `claude` binary is on PATH, which
  # says nothing about the login, so it reads "Installed").
  defp engine_readiness(assigns) do
    claude =
      case assigns.claude_check do
        {:ok, %{logged_in: true}} -> :ready
        {:ok, _} -> :not_ready
        {:error, _} -> :not_ready
        :checking -> :checking
        nil -> if assigns.claude_found, do: :installed, else: :not_ready
      end

    opencode =
      case {assigns.health, assigns.providers_state} do
        {{:ok, _}, _} -> :ready
        {{:error, _}, _} -> :not_ready
        {_, :ok} -> :ready
        {_, :loading} -> :checking
        {_, _} -> :not_ready
      end

    %{"claude_code" => claude, "opencode" => opencode}
  end

  defp engine_not_ready(assigns) do
    claude =
      case assigns.claude_check do
        {:ok, _} -> "Not logged in"
        {:error, "enter the binary first"} -> "Not set"
        {:error, reason} when is_binary(reason) -> "Not ready"
        _ -> "Not found"
      end

    %{"claude_code" => claude, "opencode" => "Not running"}
  end

  defp claude_found? do
    not is_nil(System.find_executable(Canopy.Engine.ClaudeCode.binary_name()))
  rescue
    _ -> false
  end

  defp opencode_saved(changeset) do
    if Ecto.Changeset.changed?(changeset, :opencode_default_provider) or
         Ecto.Changeset.changed?(changeset, :opencode_default_model),
       do: default_saved("opencode", "model"),
       else: "OpenCode settings saved."
  end

  defp claude_saved(changeset) do
    cond do
      Ecto.Changeset.changed?(changeset, :claude_default_model) ->
        default_saved("claude_code", "model")

      Ecto.Changeset.changed?(changeset, :claude_default_effort) ->
        default_saved("claude_code", "effort")

      Ecto.Changeset.changed?(changeset, :claude_light_model) or
          Ecto.Changeset.changed?(changeset, :claude_light_effort) ->
        "Saved. Routed agents without a light model of their own use it from their next light turn."

      true ->
        "Claude Code settings saved."
    end
  end

  defp default_saved(engine, kind) do
    usage = if kind == "model", do: Agents.model_usage(engine), else: Agents.effort_usage(engine)
    n = usage.default

    if n == 1,
      do: "Saved. 1 agent uses the default #{kind} from its next turn.",
      else: "Saved. #{n} agents use the default #{kind} from their next turn."
  end

  defp agents_word(1), do: "agent"
  defp agents_word(_), do: "agents"

  # The last 4 characters only, as everywhere a masked token shows.
  defp mask_token(token), do: Canopy.MCP.Redact.token(token)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      repositories={@repositories}
      agents={@agents}
      dms={@dms}
      unread={@unread}
      threads_unread={@threads_unread}
      attention={@attention}
      schedule_counts={@schedule_counts}
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
      palette={@palette}
    >
      <Layouts.page
        title="Settings"
        subtitle="Engines, your name, appearance, notifications, and the MCP bridge"
      >
        <:actions>
          <.link navigate={~p"/welcome"} id="run-setup" class="btn btn-soft btn-sm">
            <.icon name="hero-sparkles" class="size-4" /> Run setup again
          </.link>
        </:actions>
        <Layouts.panel
          id="engine-panel"
          title="Default engine"
          description="Agents without an engine of their own run on this; set one per agent on its edit form to override. Changing it starts those agents on a fresh session on the new engine at their next turn in each channel."
        >
          <div class="flex flex-col gap-3">
            <EngineComponents.default_engine_choice
              id="default-engine-choice"
              selected={Settings.default_engine(@setting)}
              readiness={engine_readiness(assigns)}
              not_ready={engine_not_ready(assigns)}
            />
            <div
              id="engine-usage"
              class="flex flex-wrap items-center gap-x-2 text-xs text-base-content/60"
            >
              <span>{engine_usage_text(@engine_usage)}</span>
              <button
                :if={@engine_usage.own > 0}
                type="button"
                id="engine-usage-inherit"
                class="btn btn-ghost btn-xs text-primary"
                phx-click="inherit_default_engine"
                data-canopy-confirm={"Clear the engine set on #{@engine_usage.own} #{agents_word(@engine_usage.own)}, so they run on the default (#{Canopy.Engine.label(Settings.default_engine(@setting))})? An agent that changes engine this way also drops its own model, and starts a fresh session at its next turn."}
                data-canopy-confirm-title="Use the default engine for all?"
                data-canopy-confirm-label="Use the default"
              >
                Use the default for all
              </button>
            </div>
          </div>
        </Layouts.panel>

        <Layouts.panel
          id="opencode-panel"
          title="OpenCode server"
          description="Canopy talks to one `opencode serve` instance and passes each repository as the directory. Agents without a model of their own run on the default model, from their next turn."
        >
          <.form
            for={@opencode_form}
            id="opencode-form"
            phx-change="validate_opencode"
            phx-submit="save_opencode"
            class="flex flex-col gap-3"
          >
            <.input
              field={@opencode_form[:opencode_url]}
              type="url"
              label="Server URL"
              placeholder="http://127.0.0.1:4096"
              autocomplete="off"
            />
            <div id="opencode-default" class="grid gap-3 sm:grid-cols-2">
              <%= if @providers != [] do %>
                <.input
                  field={@opencode_form[:opencode_default_provider]}
                  type="select"
                  id="opencode-default-provider"
                  label="Default provider"
                  prompt="OpenCode's own default"
                  options={
                    Providers.provider_options(
                      @providers,
                      @opencode_form[:opencode_default_provider].value
                    )
                  }
                />
                <.input
                  field={@opencode_form[:opencode_default_model]}
                  type="select"
                  id="opencode-default-model"
                  label="Default model"
                  prompt={
                    if blank?(@opencode_form[:opencode_default_provider].value),
                      do: "Pick a provider first",
                      else: "Pick a model"
                  }
                  options={
                    Providers.model_options(
                      @providers,
                      @opencode_form[:opencode_default_provider].value,
                      @opencode_form[:opencode_default_model].value
                    )
                  }
                  disabled={blank?(@opencode_form[:opencode_default_provider].value)}
                />
              <% else %>
                <%!-- No free text: a default OpenCode cannot run would fail every
                     inheriting agent, so it is chosen from the server's list. --%>
                <.input
                  field={@opencode_form[:opencode_default_provider]}
                  type="select"
                  id="opencode-default-provider"
                  label="Default provider"
                  prompt={unavailable_prompt(@providers_state)}
                  options={List.wrap(@setting.opencode_default_provider)}
                  disabled
                />
                <.input
                  field={@opencode_form[:opencode_default_model]}
                  type="select"
                  id="opencode-default-model"
                  label="Default model"
                  prompt={unavailable_prompt(@providers_state)}
                  options={List.wrap(@setting.opencode_default_model)}
                  disabled
                />
              <% end %>
            </div>
            <div id="opencode-light" class="grid gap-3 sm:grid-cols-2">
              <%= if @providers != [] do %>
                <.input
                  field={@opencode_form[:opencode_light_provider]}
                  type="select"
                  id="opencode-light-provider"
                  label="Light provider (routing, experimental)"
                  prompt="No light model"
                  options={
                    Providers.provider_options(
                      @providers,
                      @opencode_form[:opencode_light_provider].value
                    )
                  }
                />
                <.input
                  field={@opencode_form[:opencode_light_model]}
                  type="select"
                  id="opencode-light-model"
                  label="Light model"
                  prompt={
                    if blank?(@opencode_form[:opencode_light_provider].value),
                      do: "Pick a provider first",
                      else: "Pick a model"
                  }
                  options={
                    Providers.model_options(
                      @providers,
                      @opencode_form[:opencode_light_provider].value,
                      @opencode_form[:opencode_light_model].value
                    )
                  }
                  disabled={blank?(@opencode_form[:opencode_light_provider].value)}
                />
              <% else %>
                <.input
                  field={@opencode_form[:opencode_light_provider]}
                  type="select"
                  id="opencode-light-provider"
                  label="Light provider (routing, experimental)"
                  prompt={unavailable_prompt(@providers_state)}
                  options={List.wrap(@setting.opencode_light_provider)}
                  disabled
                />
                <.input
                  field={@opencode_form[:opencode_light_model]}
                  type="select"
                  id="opencode-light-model"
                  label="Light model"
                  prompt={unavailable_prompt(@providers_state)}
                  options={List.wrap(@setting.opencode_light_model)}
                  disabled
                />
              <% end %>
            </div>
            <p
              :if={@providers == [] and @providers_state == :error}
              id="opencode-default-unavailable"
              class="-mt-1 text-xs text-warning"
            >
              Start OpenCode to choose a model: run <code class="font-mono">opencode serve</code>, then
              press <em>Check connection</em>.
            </p>
            <p
              :if={opencode_default_price(@setting, @providers)}
              id="opencode-default-price"
              class="-mt-1 text-xs text-base-content/60"
            >
              {opencode_default_price(@setting, @providers)}
            </p>
            <.default_usage
              id="opencode-model-usage"
              engine="opencode"
              kind="model"
              usage={@usage["opencode"].model}
            />
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" id="save-opencode">Save</.button>
              <button
                type="button"
                id="check-connection"
                class="btn btn-soft"
                phx-click="check_connection"
                disabled={@health == :checking}
              >
                <.icon
                  :if={@health == :checking}
                  name="hero-arrow-path"
                  class="size-4 motion-safe:animate-spin"
                />
                <.icon :if={@health != :checking} name="hero-signal" class="size-4" />
                Check connection
              </button>
              <.health_result health={@health} />
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="claude-panel"
          title="Claude Code"
        >
          <:subtitle>
            Agents on the Claude Code engine run <code>claude -p</code>
            on this machine, one process per turn, using your Claude login.
          </:subtitle>
          <.form
            for={@claude_form}
            id="claude-form"
            phx-change="validate_claude"
            phx-submit="save_claude"
            class="flex flex-col gap-3"
          >
            <div class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@claude_form[:claude_binary]}
                type="text"
                label="Binary (name on PATH or a path)"
                placeholder="claude"
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@claude_form[:claude_config_dir]}
                type="text"
                label="Config directory (optional)"
                placeholder="~/.claude (your own login)"
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@claude_form[:claude_max_budget_usd]}
                type="number"
                step="0.01"
                min="0"
                label="Spend cap per turn, USD (optional)"
                placeholder="none"
              />
            </div>
            <div class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@claude_form[:claude_default_model]}
                type="select"
                id="claude-default-model"
                label="Default model"
                prompt="Claude Code's own default"
                options={Agent.claude_models()}
              />
              <.input
                field={@claude_form[:claude_default_effort]}
                type="select"
                id="claude-default-effort"
                label="Default effort"
                prompt="Claude Code's own default"
                options={Agent.efforts()}
              />
            </div>
            <div id="claude-light" class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@claude_form[:claude_light_model]}
                type="select"
                id="claude-light-model"
                label="Light model (routing, experimental)"
                prompt="No light model"
                options={Agent.claude_models()}
              />
              <.input
                field={@claude_form[:claude_light_effort]}
                type="select"
                id="claude-light-effort"
                label="Light effort"
                prompt="Claude Code picks"
                options={Agent.efforts()}
              />
            </div>
            <div class="flex flex-col gap-1">
              <.default_usage
                id="claude-model-usage"
                engine="claude_code"
                kind="model"
                usage={@usage["claude_code"].model}
              />
              <.default_usage
                id="claude-effort-usage"
                engine="claude_code"
                kind="effort"
                usage={@usage["claude_code"].effort}
              />
            </div>
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" id="save-claude">Save</.button>
              <button type="button" id="check-claude" class="btn btn-soft" phx-click="check_claude">
                Check Claude Code
              </button>
              <.claude_check_result check={@claude_check} />
            </div>
            <p class="text-xs text-base-content/60">
              Agents without a model or effort of their own use the defaults, from their next
              turn; set one per agent on its edit form to override. The light model is used
              only by agents with model routing turned on (experimental, unverified until the
              Phase 0 spike; every agent starts with it off).
              Leave the config directory empty to use your own Claude Code login and settings
              (your personal MCP servers are still kept out of agent sessions; the repository's
              <code class="font-mono">.mcp.json</code>
              servers are loaded). Point it at a
              directory of its own to isolate agents; run <code class="font-mono">claude</code>
              once with <code class="font-mono">CLAUDE_CONFIG_DIR</code>
              set to log in there.
            </p>
          </.form>
        </Layouts.panel>

        <Layouts.panel id="gh-panel" title="GitHub">
          <:subtitle>
            GitHub watches (agents create them with <code>canopy_watch_create</code>) read GitHub
            through your <code>gh</code> CLI and its login; Canopy stores no token.
          </:subtitle>
          <.form
            for={@gh_form}
            id="gh-form"
            phx-change="validate_gh"
            phx-submit="save_gh"
            class="flex flex-col gap-3"
          >
            <div class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@gh_form[:gh_binary]}
                type="text"
                label="gh binary (name on PATH or a path)"
                placeholder="gh"
                autocomplete="off"
                spellcheck="false"
              />
            </div>
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" id="save-gh">Save</.button>
              <button type="button" id="check-gh" class="btn btn-soft" phx-click="check_gh">
                Check gh
              </button>
              <.gh_check_result check={@gh_check} />
            </div>
            <p class="text-xs text-base-content/60">
              Checks use conditional requests, so a check that finds nothing new costs no GitHub
              rate limit and no tokens. Install the GitHub CLI and run
              <code class="font-mono">gh auth login</code>
              once; the check uses the saved binary.
            </p>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="profile-panel"
          title="You"
          description="How your messages are attributed in channels."
        >
          <.form
            for={@profile_form}
            id="profile-form"
            phx-change="validate_profile"
            phx-submit="save_profile"
            class="flex flex-col gap-3"
          >
            <.input
              field={@profile_form[:user_display_name]}
              type="text"
              label="Display name"
              autocomplete="off"
            />
            <div>
              <.button type="submit" variant="primary" id="save-profile">Save</.button>
            </div>
          </.form>
        </Layouts.panel>

        <.appearance_panel />

        <.notifications_panel />

        <Layouts.panel
          id="chatter-panel"
          title="Conversation"
          description="Agents wake each other by mentioning and by replying to the owner. This is the brake."
        >
          <:actions>
            <span
              :if={Presets.match(@setting) == :custom}
              id="chatter-custom"
              class="rounded-full bg-base-300/70 px-2 py-0.5 text-[11px] font-medium text-base-content/70"
            >
              custom
            </span>
          </:actions>
          <PresetComponents.preset_cards
            id="chatter-presets"
            selected={Presets.match(@setting)}
            event="apply_preset"
          />
          <p class="mt-2 mb-4 text-xs text-base-content/60">
            A preset sets the controls below at once; change them one by one for anything in between.
          </p>
          <.form
            for={@chatter_form}
            id="chatter-form"
            phx-change="validate_chatter"
            phx-submit="save_chatter"
            class="flex flex-col gap-3"
          >
            <.input
              field={@chatter_form[:serialize_turns]}
              type="checkbox"
              label="One agent at a time per channel (others wait their turn)"
            />
            <p class="-mt-1 text-xs text-base-content/60">
              Off, agents woken together all run at once. They get in each other's way and
              every one of them spends tokens; keep this on unless you want the swarm. An agent
              waiting on your answer to a question or permission card does not hold the channel:
              the next one starts, and when you answer, the waiting agent carries on alongside it.
              What agents really contend for (the test suite, e2e ports, screenshot runs) is
              guarded by locks either way: they take turns on those, whatever this says.
            </p>
            <.input
              field={@chatter_form[:interrupt_on_mention]}
              type="checkbox"
              label="Mentioning a working agent interrupts it (experimental)"
            />
            <p id="interrupt-help" class="-mt-1 text-xs text-base-content/60">
              When you @mention an agent that's working, it reads your message after its current
              step instead of after its turn; a running command is allowed to finish. Alt+Enter, or
              the menu beside Send, sends one message without interrupting. Experimental and off
              by default: how Claude Code and OpenCode take a message mid-turn has not been checked
              against the real engines yet. Off, your message waits until the agent's turn ends.
            </p>
            <div class="max-w-xs">
              <.input
                field={@chatter_form[:question_wait_minutes]}
                type="number"
                min="1"
                max={Canopy.Settings.Setting.max_question_wait_minutes()}
                label="Minutes a Claude Code question waits for you"
              />
            </div>
            <p class="-mt-1 text-xs text-base-content/60">
              After that the agent ends its turn instead of sitting on the question. The card stays
              open, and your answer reaches the agent as a message whenever you give it. At most {Canopy.Settings.Setting.max_question_wait_minutes()} minutes: Claude Code gives up
              on a waiting tool call after 30.
            </p>
            <div class="max-w-xs">
              <.input
                field={@chatter_form[:lock_hold_minutes]}
                type="number"
                min="1"
                max={Canopy.Settings.Setting.max_lock_hold_minutes()}
                label="Minutes an agent may keep a lock across turns"
              />
            </div>
            <p class="-mt-1 text-xs text-base-content/60">
              A lock is released when its holder's turn ends. An agent can ask to keep one across
              turns; after this long Canopy frees it anyway, and the next in line is woken.
            </p>
            <.input
              field={@chatter_form[:chatter_pause]}
              type="checkbox"
              label="Pause a channel after agents have taken turns without me"
            />
            <div class={[
              "max-w-xs transition",
              !Phoenix.HTML.Form.normalize_value("checkbox", @chatter_form[:chatter_pause].value) &&
                "opacity-50"
            ]}>
              <.input
                field={@chatter_form[:chatter_limit]}
                type="number"
                min="1"
                max="1000"
                label="Turns before pausing"
              />
            </div>
            <p class="text-xs text-base-content/60">
              A paused channel holds further wakeups and shows a Continue button; your next
              message also resets it. Turn this off for long-running work you want to leave
              alone, and watch the cost.
            </p>
            <div>
              <.button type="submit" variant="primary" id="save-chatter">Save</.button>
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="prompt-panel"
          title="Collaboration prompt"
          description="The instructions every agent is given, above its own role prompt. Canopy fills in the {{variables}} per agent."
        >
          <:actions>
            <span
              :if={customised(@setting)}
              id="prompt-customised"
              class="rounded-full bg-warning/15 px-2 py-0.5 text-[11px] font-medium text-warning"
            >
              customised
            </span>
            <.button
              :if={customised(@setting)}
              type="button"
              id="reset-prompt"
              phx-click="reset_prompt"
              data-canopy-confirm="Discard your collaboration prompt and go back to the one Canopy ships?"
            >
              Reset to default
            </.button>
          </:actions>
          <.form
            for={@prompt_form}
            id="prompt-form"
            phx-change="validate_prompt"
            phx-submit="save_prompt"
            class="flex flex-col gap-3"
          >
            <.input
              field={@prompt_form[:collaboration_prompt]}
              type="textarea"
              rows="18"
              label="Instructions"
              class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
            />
            <div class="text-xs text-base-content/60">
              <p class="mb-1">Available variables:</p>
              <p class="flex flex-wrap gap-1">
                <code
                  :for={name <- Prompts.preamble_variables()}
                  class="rounded bg-base-300/60 px-1 font-mono text-[11px]"
                >{"{{#{name}}}"}</code>
              </p>
              <p id="prompt-brief-note" class="mt-1">
                <code class="font-mono">{"{{channel_brief}}"}</code>
                is the channel's brief, empty when it has none. A prompt that leaves it out gets
                the brief added after it, so every agent still sees it.
              </p>
            </div>
            <p class="text-xs text-base-content/60">
              This is also where agents learn the <code class="font-mono">canopy_</code>
              tools exist. Strip that out and they lose the ability to post, delegate, or
              hand off — keep the tool list unless you mean to. Changes reach each agent on
              its next turn; sessions already running keep the text they started with.
            </p>
            <div>
              <.button type="submit" variant="primary" id="save-prompt">Save</.button>
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="mcp-panel"
          title="MCP bridge"
          description="Agents reach Canopy through an MCP server that Canopy registers with OpenCode on demand."
        >
          <div class="flex flex-col gap-5">
            <div class="alert alert-soft alert-info text-xs" id="mcp-transport-note">
              <.icon name="hero-information-circle" class="size-4 shrink-0" />
              <span>
                The MCP endpoint is served only while Canopy runs under
                <code class="font-mono">mix phx.server</code>
                (or with <code class="font-mono">PHX_SERVER=true</code>).
              </span>
            </div>

            <div>
              <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Endpoint URL
              </div>
              <div class="flex items-center gap-2">
                <code
                  id="mcp-url"
                  class="flex-1 truncate rounded-md border border-base-300 bg-base-200 px-3 py-1.5 font-mono text-sm"
                >
                  {@mcp_url}
                </code>
                <.copy_button id="copy-mcp-url" target="#mcp-url" />
              </div>
              <p class="mt-1 text-xs text-base-content/60">
                Registered with OpenCode under the name <code class="font-mono">{@mcp_name}</code>, so tools appear as <code class="font-mono">{@mcp_name}_*</code>.
              </p>
              <p id="mcp-per-repository" class="mt-1 text-xs text-base-content/60">
                Per-repository MCP servers: open a repository from
                <.link navigate={~p"/repositories"} class="link">Repositories</.link>
                and choose MCP.
              </p>
            </div>

            <div>
              <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Bearer token
              </div>
              <div class="flex items-center gap-2">
                <code
                  id="mcp-token"
                  class="flex-1 truncate rounded-md border border-base-300 bg-base-200 px-3 py-1.5 font-mono text-sm"
                >
                  {if @token_visible, do: @setting.mcp_token, else: mask_token(@setting.mcp_token)}
                </code>
                <button
                  type="button"
                  id="toggle-token"
                  class="btn btn-soft btn-sm"
                  phx-click="toggle_token"
                  title={if @token_visible, do: "Hide token", else: "Reveal token"}
                >
                  <.icon
                    name={if @token_visible, do: "hero-eye-slash", else: "hero-eye"}
                    class="size-4"
                  />
                </button>
                <button
                  type="button"
                  id="rotate-token"
                  class="btn btn-soft btn-warning btn-sm"
                  phx-click="rotate_token"
                  data-canopy-confirm="Rotate the MCP token? Running OpenCode sessions lose access until Canopy re-registers the MCP server, which happens automatically the next time an agent is prompted."
                >
                  <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Rotate token
                </button>
              </div>
              <p class="mt-1 flex items-center gap-1 text-xs text-warning">
                <.icon name="hero-exclamation-triangle-mini" class="size-3.5" />
                Rotating invalidates the current registration. OpenCode must be re-registered;
                the runtime does this automatically when it next prompts an agent.
              </p>
            </div>

            <div>
              <div class="mb-1 flex items-center justify-between">
                <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Identity plugin
                </div>
                <.copy_button id="copy-plugin" target="#plugin-source" label="Copy plugin" />
              </div>
              <p class="mb-2 text-xs text-base-content/60">
                Canopy installs this into every registered repository at
                <code class="font-mono">.opencode/plugins/canopy.js</code>
                (kept out of git) before an agent's first turn there. To cover repositories you open with OpenCode directly, install it once at
                <code class="font-mono" id="plugin-path">{@plugin_path}</code>
                and restart <code class="font-mono">opencode serve</code>. It stamps the real
                OpenCode session id into every Canopy tool call so agents cannot impersonate each other.
              </p>
              <pre
                id="plugin-source"
                class="max-h-72 overflow-auto rounded-md border border-base-300 bg-base-200 p-3 font-mono text-xs leading-relaxed"
              >{@plugin_source}</pre>
            </div>
          </div>
        </Layouts.panel>

        <Layouts.panel
          id="files-panel"
          title="Shared files"
          description="Documents attached in chats are stored once, next to the database, and served from /files/. Manage them on the Files page."
        >
          <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt class="text-base-content/60">Storage directory</dt>
            <dd class="min-w-0 truncate font-mono text-xs" id="files-dir" title={@files_dir}>
              {@files_dir}
            </dd>
            <dt class="text-base-content/60">Size limit per file</dt>
            <dd id="files-limit">
              {Canopy.Documents.size_label(@files_limit)}
              <span class="text-xs text-base-content/60">(CANOPY_MAX_UPLOAD_MB)</span>
            </dd>
            <dt class="text-base-content/60">Stored</dt>
            <dd id="files-stored">
              {@files_count} file(s), {Canopy.Documents.size_label(@files_bytes)} ·
              <.link navigate={~p"/files"} class="link link-primary">Files page</.link>
            </dd>
          </dl>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :engine, :string, required: true
  attr :kind, :string, required: true, doc: "\"model\" or \"effort\""
  attr :usage, :map, required: true, doc: "`%{default: n, own: n}` from `Canopy.Agents`"

  # How many active agents inherit the default, and the bulk switch for the rest.
  defp default_usage(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-x-2 text-xs text-base-content/60">
      <span>
        {@usage.default} {agents_word(@usage.default)} {if @usage.default == 1,
          do: "uses",
          else: "use"} the default {@kind} · {@usage.own} {if @usage.own == 1,
          do: "has its",
          else: "have their"} own
      </span>
      <button
        :if={@usage.own > 0}
        type="button"
        id={"#{@id}-inherit"}
        class="btn btn-ghost btn-xs text-primary"
        phx-click="inherit_default"
        phx-value-engine={@engine}
        phx-value-kind={@kind}
        data-canopy-confirm={"Clear the #{@kind} set on #{@usage.own} #{Canopy.Engine.label(@engine)} #{agents_word(@usage.own)}, so they use the default from their next turn? You can set one per agent again on the Agents page."}
        data-canopy-confirm-title={"Use the default #{@kind} for all?"}
        data-canopy-confirm-label="Use the default"
      >
        Use the default for all
      </button>
    </div>
    """
  end

  defp unavailable_prompt(:loading), do: "Loading OpenCode's models…"
  defp unavailable_prompt(_state), do: "Start OpenCode to choose a model"

  defp opencode_default_price(
         %{opencode_default_provider: p, opencode_default_model: m},
         providers
       )
       when is_binary(p) and is_binary(m) and providers != [] do
    case Providers.pricing(providers, p, m) do
      nil -> nil
      pricing -> "#{p}/#{m}: #{Providers.price_text(pricing, providers, p)}"
    end
  end

  defp opencode_default_price(_setting, _providers), do: nil

  defp blank?(value), do: value in [nil, ""]

  attr :health, :any, required: true

  defp health_result(assigns) do
    ~H"""
    <span id="health-result" class="flex items-center gap-1.5 text-sm" role="status">
      <%= case @health do %>
        <% nil -> %>
        <% :checking -> %>
          <span class="text-base-content/60">Checking…</span>
        <% {:ok, version} -> %>
          <.icon name="hero-check-circle-mini" class="size-4 text-success" />
          <span class="text-success">
            Connected{if version, do: " · OpenCode #{version}", else: ""}
          </span>
        <% {:error, reason} -> %>
          <.icon name="hero-x-circle-mini" class="size-4 text-error" />
          <span class="text-error">{reason}</span>
      <% end %>
    </span>
    """
  end

  attr :check, :any, default: nil

  defp gh_check_result(assigns) do
    ~H"""
    <span id="gh-check-result" class="flex items-center gap-1.5 text-sm" role="status">
      <%= case @check do %>
        <% nil -> %>
        <% :checking -> %>
          <span class="text-base-content/60">Checking…</span>
        <% {:ok, info} -> %>
          <.icon
            name={
              if info.logged_in? and not info.too_old?,
                do: "hero-check-circle-mini",
                else: "hero-exclamation-circle-mini"
            }
            class={[
              "size-4",
              if(info.logged_in? and not info.too_old?, do: "text-success", else: "text-warning")
            ]}
          />
          <span>
            gh {info.version}{if info.too_old?, do: " (too old: watches need gh 2.0 or later)"} · {cond do
              info.logged_in? and info.account -> "logged in as #{info.account}"
              info.logged_in? -> "logged in"
              true -> "not logged in: run gh auth login"
            end}
          </span>
        <% {:error, reason} -> %>
          <.icon name="hero-x-circle-mini" class="size-4 text-error" />
          <span class="text-error">{reason}</span>
      <% end %>
    </span>
    """
  end

  attr :check, :any, required: true

  defp claude_check_result(assigns) do
    ~H"""
    <span id="claude-check-result" class="flex items-center gap-1.5 text-sm" role="status">
      <%= case @check do %>
        <% nil -> %>
        <% :checking -> %>
          <span class="text-base-content/60">Checking…</span>
        <% {:ok, info} -> %>
          <.icon
            name={
              if info.logged_in, do: "hero-check-circle-mini", else: "hero-exclamation-circle-mini"
            }
            class={["size-4", if(info.logged_in, do: "text-success", else: "text-warning")]}
          />
          <span class={if info.logged_in, do: "text-success", else: "text-warning"}>
            Claude Code {info.version} at <code class="font-mono">{info.path}</code>{if info.logged_in,
              do:
                " · logged in" <>
                  if(info.subscription, do: " (#{info.subscription})", else: "") <>
                  if(info.email, do: " as #{info.email}", else: ""),
              else: " · not logged in: run `claude` once to log in"}
          </span>
        <% {:error, reason} -> %>
          <.icon name="hero-x-circle-mini" class="size-4 text-error" />
          <span class="text-error">{reason}</span>
      <% end %>
    </span>
    """
  end

  # Mode and palette live in this browser's localStorage, so the panel holds no
  # server state (see `CanopyWeb.AppearanceComponents`).
  defp appearance_panel(assigns) do
    ~H"""
    <Layouts.panel
      id="appearance-panel"
      title="Appearance"
      description="How Canopy looks in this browser. The rail's sun/moon switch changes the same setting."
    >
      <div class="flex flex-col gap-5">
        <AppearanceComponents.appearance_picker />

        <p class="text-xs text-base-content/60">
          Agent colours are set per agent on the Agents page and look the same in every palette.
        </p>
      </div>
    </Layouts.panel>
    """
  end

  # Desktop notifications belong to this browser (permission is per browser
  # and origin), so the panel holds no server state (see
  # `CanopyWeb.NotifyComponents`).
  defp notifications_panel(assigns) do
    ~H"""
    <Layouts.panel
      id="notifications-panel"
      title="Notifications"
      description="Desktop notifications from this browser when an agent needs you while you look elsewhere. Nothing leaves this machine."
    >
      <NotifyComponents.notify_prefs />
    </Layouts.panel>
    """
  end

  attr :id, :string, required: true
  attr :target, :string, required: true, doc: "CSS selector of the element whose text is copied"
  attr :label, :string, default: "Copy"

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="btn btn-soft btn-sm"
      phx-hook=".CopyText"
      data-copy-target={@target}
      title={@label}
    >
      <.icon name="hero-clipboard-document" class="size-4" />
      <span data-copy-label>{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const target = document.querySelector(this.el.dataset.copyTarget)
            if (!target) return
            const text = target.textContent.trim()
            const label = this.el.querySelector("[data-copy-label]")
            const original = label ? label.textContent : null
            navigator.clipboard.writeText(text).then(() => {
              if (label) {
                label.textContent = "Copied"
                setTimeout(() => { label.textContent = original }, 1500)
              }
            })
          })
        }
      }
    </script>
    """
  end

  # The textarea always shows the text in force, so a fresh install can be
  # edited from the shipped wording rather than an empty box. Saving it back
  # unchanged means "still the default", so later Canopy updates keep applying.
  defp prompt_form(setting) do
    effective = customised(setting) || Prompts.default_preamble()

    Settings.change(%{setting | collaboration_prompt: effective})
    |> to_form(id: "prompt-form")
  end

  defp prompt_attrs(params) do
    text = params |> Map.get("collaboration_prompt", "") |> to_string()

    if String.trim(text) == String.trim(Prompts.default_preamble()),
      do: %{"collaboration_prompt" => nil},
      else: %{"collaboration_prompt" => text}
  end

  defp customised(%{collaboration_prompt: text}) when is_binary(text) and text != "", do: text
  defp customised(_setting), do: nil

  defp prompt_saved(setting) do
    if customised(setting),
      do: "Collaboration prompt saved. Agents get it on their next turn.",
      else: "That matches the prompt Canopy ships, so the default is back in use."
  end

  defp chatter_saved(%{chatter_pause: false}),
    do: "Pausing is off: agents may keep talking until you step in."

  defp chatter_saved(%{chatter_limit: n}),
    do: "Channels pause after #{n} agent #{if n == 1, do: "turn", else: "turns"} without you."
end
