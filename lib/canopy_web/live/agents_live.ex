defmodule CanopyWeb.AgentsLive do
  @moduledoc """
  Agents, in four pages under one LiveView:

    * `/agents` — the list (active, plus deactivated behind a toggle)
    * `/agents/new` — the create form
    * `/agents/:id` — one agent: identity, model, channels, schedules, actions
    * `/agents/:id/edit` — the edit form for that agent

  Sharing lives beside it: the list's Import and Gallery buttons lead to
  `CanopyWeb.AgentImportLive` and `CanopyWeb.AgentGalleryLive`, rows can be
  selected for "Export selected" (a zip), and an agent's page has Export
  (its `.md`, with its memory only when ticked). Downloads are plain GETs to
  `CanopyWeb.TemplateController`.

  The OpenCode agent picker is a select filled from `GET /agent` for the
  first repository (always offering the built-in `build` and `plan`), and the provider/model selects come from
  `GET /config/providers`; both degrade to plain inputs when OpenCode is away.

  An agent with no model (or, on Claude Code, no effort) of its own inherits
  its engine's default from Settings; the list, the picker, and the form show
  which default that is.

  Model routing (experimental, off by default and unverified until the Phase
  0 spike): the form's Routing section turns it on per agent and picks the
  light model and effort ("Default (…)" inherits the engine's light model from
  Settings); the agent page shows the routing state, the light turns' recent
  escalation rates, and paused rules with Resume; the list marks routed agents.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Channels, Memory, Repositories, Schedules, Settings, Teams}
  alias Canopy.Agents.Agent
  alias Canopy.OpenCode.{Client, Providers}
  alias CanopyWeb.Nav

  import CanopyWeb.TimelineComponents, only: [schedule_list: 1, message_text: 1]

  # OpenCode's own primary agents: `build` edits, `plan` is read-only.
  @builtin_opencode_agents ~w(build plan)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:opencode_agents, @builtin_opencode_agents)
      |> assign(:providers, [])
      |> assign(:model_picker, nil)
      |> assign(:server_defaults, %{})
      |> assign_defaults()
      |> assign(:show_inactive, false)
      |> assign(:agent, nil)
      |> assign(:agent_channels, [])
      |> assign(:agent_teams, [])
      |> assign(:agent_schedules, [])
      |> assign(:agent_memory, "")
      |> assign(:light_profile, nil)
      |> assign(:routing_pauses, [])
      |> assign(:rule_stats, [])
      |> assign(:memory_updated_at, nil)
      |> assign(:editing_memory?, false)
      |> assign(:selected, MapSet.new())
      |> assign_form(Agents.change(%Agent{}))
      |> load_agents()

    if connected?(socket) do
      Memory.subscribe()
      Settings.subscribe()
      Teams.subscribe()
    end

    socket =
      if connected?(socket) do
        socket
        |> fetch_opencode_agents()
        |> start_async(:providers, fn -> Providers.list() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case {socket.assigns.live_action, params} do
      {:index, _} ->
        {:noreply, socket |> assign(:agent, nil) |> assign(:page_title, "Agents")}

      {:new, _} ->
        {:noreply,
         socket
         |> assign(:agent, nil)
         |> assign(:page_title, "New agent")
         |> assign_form(Agents.change(%Agent{}))}

      {action, %{"id" => id}} when action in [:show, :edit] ->
        case Agents.get(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That agent no longer exists.")
             |> push_navigate(to: ~p"/agents")}

          agent ->
            socket =
              socket
              |> assign(:agent, agent)
              |> assign(:page_title, "@" <> agent.name)
              |> load_agent_details()

            {:noreply,
             if(action == :edit, do: assign_form(socket, Agents.change(agent)), else: socket)}
        end
    end
  end

  @impl true
  def handle_info({:schedules, :changed, _channel_id}, %{assigns: %{agent: %Agent{}}} = socket),
    do: {:noreply, load_agent_details(socket)}

  def handle_info(
        {:memory, :changed, agent_id},
        %{assigns: %{agent: %Agent{id: agent_id}}} = socket
      ),
      do: {:noreply, load_memory(socket)}

  # A default changed in Settings, or agents were moved onto it there.
  def handle_info({:settings, :default_models_changed}, socket) do
    socket = socket |> assign_defaults() |> load_agents()

    {:noreply,
     case socket.assigns.agent do
       %Agent{id: id} -> assign(socket, :agent, Agents.get!(id))
       nil -> socket
     end}
  end

  # A light model changed in Settings, or a routing rule paused or resumed.
  def handle_info({:settings, :light_profiles_changed}, socket) do
    socket = socket |> assign_defaults() |> load_agents()

    {:noreply,
     case socket.assigns.agent do
       %Agent{id: id} -> socket |> assign(:agent, Agents.get!(id)) |> load_routing()
       nil -> socket
     end}
  end

  def handle_info({:teams, :changed}, socket),
    do: {:noreply, socket |> load_agents() |> load_agent_details()}

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Events -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    # A model belongs to one engine: switching lands the agent on the new
    # engine's default rather than on a model that engine cannot run.
    params =
      if params["engine"] && params["engine"] != socket.assigns.form[:engine].value,
        do:
          Map.merge(params, %{
            "model_provider" => nil,
            "model_id" => nil,
            "light_model_provider" => nil,
            "light_model_id" => nil
          }),
        else: params

    changeset =
      (socket.assigns.agent || %Agent{})
      |> Agents.change(blank_to_nil(params))
      |> maybe_validate_model(socket.assigns.providers)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"agent" => params}, socket) do
    params = blank_to_nil(params)
    editing = socket.assigns.agent || %Agent{}
    checked = editing |> Agents.change(params) |> maybe_validate_model(socket.assigns.providers)

    result =
      cond do
        checked.errors != [] -> {:error, Map.put(checked, :action, :insert)}
        editing.id -> Agents.update(editing, params)
        true -> Agents.create(params)
      end

    case result do
      {:ok, agent} ->
        verb = if editing.id, do: "Updated", else: "Created"

        {:noreply,
         socket
         |> Nav.refresh_nav()
         |> put_flash(:info, "#{verb} @#{agent.name}.")
         |> push_navigate(to: ~p"/agents/#{agent.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # A routing rule paused for this agent runs on its light model again.
  def handle_event(
        "resume_routing",
        %{"kind" => kind},
        %{assigns: %{agent: %Agent{} = agent}} = socket
      ) do
    case Agents.resume_routing(agent.id, kind) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_routing()
         |> put_flash(:info, "Routing resumed for #{routing_kind_label(kind)}.")}

      {:error, _} ->
        {:noreply, load_routing(socket)}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    agent = Agents.get!(id)

    case Agents.deactivate(agent) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_after_change(agent.id)
         |> put_flash(:info, "Deactivated @#{agent.name}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not deactivate @#{agent.name}.")}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    agent = Agents.get!(id)

    case Agents.update(agent, %{active: true}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_after_change(agent.id)
         |> put_flash(:info, "Reactivated @#{agent.name}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reactivate @#{agent.name}.")}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, assign(socket, :selected, MapSet.new())}

  def handle_event("toggle_inactive", _params, socket) do
    {:noreply, update(socket, :show_inactive, &(!&1))}
  end

  def handle_event("edit_memory", _params, socket),
    do: {:noreply, assign(socket, :editing_memory?, true)}

  def handle_event("cancel_memory", _params, socket),
    do: {:noreply, socket |> assign(:editing_memory?, false) |> load_memory()}

  def handle_event("save_memory", %{"memory" => body}, socket) do
    case Memory.put(socket.assigns.agent.id, body) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_memory?, false)
         |> load_memory()
         |> put_flash(:info, "Memory saved for @#{socket.assigns.agent.name}.")}

      {:error, :too_large} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That is over #{div(Memory.max_bytes(), 1024)} KB; trim it first."
         )}
    end
  end

  def handle_event("cancel_schedule", %{"id" => id}, socket) do
    case Schedules.get(id) do
      nil ->
        {:noreply, socket}

      schedule ->
        {:ok, _} = Schedules.cancel(schedule, "cancelled from the Agents page")
        {:noreply, load_agent_details(socket)}
    end
  end

  def handle_event("open_model_picker", %{"id" => id}, socket) do
    {:noreply, assign(socket, :model_picker, Agents.get!(id))}
  end

  def handle_event("close_model_picker", _params, socket),
    do: {:noreply, assign(socket, :model_picker, nil)}

  # "" for both fields clears the agent's own model, putting it back on its
  # engine's default.
  def handle_event("pick_model", %{"provider" => provider, "model" => model}, socket) do
    agent = socket.assigns.model_picker
    attrs = blank_to_nil(%{"model_provider" => provider, "model_id" => model})

    case Agents.update(agent, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:model_picker, nil)
         |> load_agents()
         |> put_flash(:info, model_saved(updated, socket.assigns.defaults))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:model_picker, nil)
         |> put_flash(:error, "Could not change @#{agent.name}'s model.")}
    end
  end

  defp refresh_after_change(socket, agent_id) do
    socket = socket |> load_agents() |> Nav.refresh_nav()

    case socket.assigns.agent do
      %Agent{id: ^agent_id} ->
        socket |> assign(:agent, Agents.get!(agent_id)) |> load_agent_details()

      _ ->
        socket
    end
  end

  # -- OpenCode lookups ---------------------------------------------------------

  # OpenCode lists every agent it knows, including the internal ones it runs
  # for itself (compaction, title, summary) and subagents. Only primary, visible
  # agents can be prompted directly, and the built-ins are always available.
  @impl true
  def handle_async(:opencode_agents, {:ok, {:ok, list}}, socket) when is_list(list) do
    names =
      list
      |> Enum.filter(fn
        %{"name" => name} = agent when is_binary(name) ->
          Map.get(agent, "mode", "primary") == "primary" and not Map.get(agent, "hidden", false)

        _ ->
          false
      end)
      |> Enum.map(& &1["name"])
      |> Enum.concat(@builtin_opencode_agents)
      |> Enum.uniq()
      |> Enum.sort()

    {:noreply, assign(socket, :opencode_agents, names)}
  end

  def handle_async(:opencode_agents, _other, socket) do
    {:noreply, assign(socket, :opencode_agents, @builtin_opencode_agents)}
  end

  def handle_async(:providers, {:ok, {:ok, %{providers: providers, defaults: defaults}}}, socket) do
    {:noreply, socket |> assign(:providers, providers) |> assign(:server_defaults, defaults)}
  end

  def handle_async(:providers, _other, socket), do: {:noreply, assign(socket, :providers, [])}

  # The OpenCode model to price: the agent's (or form's) own, else Canopy's
  # default, else OpenCode's own as far as Canopy can tell. With the source.
  defp priced_model({p, m}, _defaults, _server_defaults) when is_binary(p) and is_binary(m),
    do: {p, m, :agent}

  defp priced_model(_own, defaults, server_defaults) do
    case Map.get(defaults, "opencode") do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) ->
        {p, m, :default}

      _ ->
        case Providers.server_default(server_defaults) do
          {p, m} -> {p, m, :server}
          nil -> nil
        end
    end
  end

  defp agent_price_line(%Agent{engine: "claude_code"}, _providers, _defaults, _server), do: nil

  defp agent_price_line(agent, providers, defaults, server_defaults) do
    case priced_model({agent.model_provider, agent.model_id}, defaults, server_defaults) do
      nil ->
        nil

      {p, m, source} ->
        # the model is named beside the price only when the label above does not say it
        prefix = if source == :server, do: "(#{p}/#{m}) ", else: ""
        prefix <> (price_of(providers, p, m) || "price unknown")
    end
  end

  defp form_price_line(form, providers, defaults, server_defaults) do
    own = {blank_to_nil(form[:model_provider].value), blank_to_nil(form[:model_id].value)}

    case priced_model(own, defaults, server_defaults) do
      nil ->
        "Pick a model to see its price."

      {p, m, source} ->
        note =
          case source do
            :agent -> ""
            :default -> " (default)"
            :server -> " (OpenCode's default)"
          end

        "#{p}/#{m}#{note} — #{price_of(providers, p, m) || "price unknown"}"
    end
  end

  defp price_of(providers, p, m),
    do: Providers.price_text(Providers.pricing(providers, p, m), providers, p)

  # The provider check only makes sense for agents OpenCode runs; Claude Code
  # models are checked against the alias list by the schema.
  defp maybe_validate_model(changeset, providers) do
    if Ecto.Changeset.get_field(changeset, :engine) == "opencode",
      do:
        changeset
        |> Providers.validate(providers)
        |> Providers.validate(providers, {:light_model_provider, :light_model_id}),
      else: changeset
  end

  defp model_saved(agent, defaults) do
    case {model_label(agent), default_label(defaults, agent.engine)} do
      {nil, nil} -> "@#{agent.name} is back on its #{engine_label(agent)} default model."
      {nil, default} -> "@#{agent.name} now uses the default model (#{default})."
      {label, _} -> "@#{agent.name} now runs on #{label}."
    end
  end

  # The known agents, plus the agent's current value when it is something
  # else (a name from an OpenCode config Canopy has not seen).
  defp opencode_agent_options(names, current) do
    current = if is_binary(current) and String.trim(current) != "", do: String.trim(current)
    (names ++ List.wrap(current)) |> Enum.uniq() |> Enum.sort()
  end

  defp fetch_opencode_agents(socket) do
    case Repositories.list() do
      [%{path: dir} | _] ->
        start_async(socket, :opencode_agents, fn -> Client.impl().agents(dir, []) end)

      [] ->
        socket
    end
  end

  # -- Assigns ------------------------------------------------------------------

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, id: "agent-form"))
  end

  # Each engine's default model from Settings, and Claude Code's default effort.
  defp assign_defaults(socket) do
    socket
    |> assign(:defaults, Settings.default_models())
    |> assign(:default_effort, Settings.default_effort("claude_code"))
    |> assign(:light_defaults, Settings.light_profiles())
  end

  defp load_agents(socket) do
    {active, inactive} = Agents.list() |> Enum.split_with(& &1.active)

    socket
    |> assign(:active_agents, active)
    |> assign(:inactive_agents, inactive)
    |> assign(:groups, Agents.groups())
    |> assign(:teams, Teams.list())
    |> assign(:schedule_counts, Schedules.active_counts_by_agent())
  end

  defp load_agent_details(%{assigns: %{agent: %Agent{id: id}}} = socket) do
    channels =
      Channels.list()
      |> Enum.filter(fn channel -> Enum.any?(channel.agents, &(&1.id == id)) end)
      |> Enum.sort_by(&{&1.kind != "channel", &1.status, &1.name})

    socket
    |> assign(:agent_channels, channels)
    |> assign(:agent_teams, Teams.for_agent(id))
    |> assign(:agent_schedules, Schedules.list_for_agent(id))
    |> assign(:agent_spend, agent_spend(id))
    |> load_routing()
    |> load_memory()
  end

  defp load_agent_details(socket), do: socket

  defp agent_spend(agent_id) do
    for {key, since} <- [
          today: Canopy.Costs.since(:today),
          week: Canopy.Costs.since(:week),
          all: nil
        ],
        into: %{} do
      row = Canopy.Costs.by_agent(since) |> Enum.find(&(&1.key == agent_id))
      {key, if(row, do: row.cost, else: 0.0)}
    end
  end

  # Model routing on the agent page: the light profile it resolves, the paused
  # rules, and the recent light turns per wake kind.
  defp load_routing(%{assigns: %{agent: %Agent{} = agent}} = socket) do
    socket
    |> assign(:light_profile, Agents.effective_profile(agent, :light))
    |> assign(:routing_pauses, Agents.routing_pauses(agent.id))
    |> assign(:rule_stats, Canopy.Costs.rule_stats(agent.id))
  end

  defp load_routing(socket), do: socket

  defp load_memory(%{assigns: %{agent: %Agent{id: id}}} = socket) do
    socket
    |> assign(:agent_memory, Memory.get(id))
    |> assign(:memory_updated_at, Memory.updated_at(id))
  end

  defp load_memory(socket), do: socket

  # Empty optional strings should clear a field rather than fail validation.
  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {key, nil}
          trimmed -> {key, trimmed}
        end

      pair ->
        pair
    end)
  end

  defp blank_to_nil(value), do: value

  defp engine_options, do: Enum.map(Canopy.Engine.names(), &{engine_label(&1), &1})

  defp engine_label(%Agent{engine: engine}), do: engine_label(engine)
  defp engine_label(engine), do: Canopy.Engine.label(engine)

  defp default_model_label(%Agent{engine: "claude_code"}), do: "Claude Code default"
  defp default_model_label(_agent), do: "OpenCode default"

  # The engine's default model from Settings as a label, or nil when the
  # engine picks.
  defp default_label(defaults, engine) do
    case Map.get(defaults, engine) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) -> "#{p}/#{m}"
      %{model_id: m} when is_binary(m) -> m
      _ -> nil
    end
  end

  # The "Default (…)" option of a model select.
  defp default_option(defaults, engine) do
    case default_label(defaults, engine) do
      nil -> if engine == "claude_code", do: "Claude Code's own default", else: "OpenCode default"
      label -> "Default (#{label})"
    end
  end

  defp default_effort_option(nil), do: "Claude Code's own default"
  defp default_effort_option(effort), do: "Default (#{effort})"

  # The "Default (…)" option of a light model select: the engine's light
  # model from Settings, or none.
  defp light_default_option(light_defaults, engine) do
    case Map.get(light_defaults, engine) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) ->
        "Default (#{p}/#{m})"

      %{model_id: m} when is_binary(m) ->
        "Default (#{m})"

      _ ->
        "No light model (none set in Settings)"
    end
  end

  defp light_effort_option(light_defaults) do
    case get_in(light_defaults, ["claude_code", :effort]) do
      nil -> "Default (Claude Code picks)"
      effort -> "Default (#{effort})"
    end
  end

  # The agent page's routing line.
  defp routing_text(%Agent{routing_enabled: true}, nil),
    do: "Routing is on but no light model is set"

  defp routing_text(%Agent{routing_enabled: true}, profile),
    do:
      "on · light #{profile_label(profile)}#{if profile.source == :default, do: " (default)", else: ""}"

  defp routing_text(_agent, _profile), do: "off"

  defp profile_label(%{model_provider: p, model_id: m} = profile) do
    model =
      cond do
        is_binary(p) and is_binary(m) -> "#{p}/#{m}"
        is_binary(m) -> m
        true -> "the main model"
      end

    if profile.effort, do: "#{model}, effort #{profile.effort}", else: model
  end

  defp routing_kind_label("*"), do: "every wake"
  defp routing_kind_label(kind), do: String.replace(kind, "_", " ") <> " wakes"

  # A list row's label for an agent on its engine's default.
  defp inherited_label(defaults, engine) do
    case default_label(defaults, engine) do
      nil -> "default"
      label -> "default · #{label}"
    end
  end

  defp effort_text(%Agent{effort: effort}, _default) when is_binary(effort),
    do: " · effort #{effort}"

  defp effort_text(_agent, nil), do: ""
  defp effort_text(_agent, default), do: " · effort #{default} (default)"

  defp settings_anchor("claude_code"), do: ~p"/settings" <> "#claude-panel"
  defp settings_anchor(_engine), do: ~p"/settings" <> "#opencode-panel"

  defp permission_mode_options do
    [
      {"Ask first (default)", "default"},
      {"Auto-approve edits (acceptEdits)", "acceptEdits"},
      {"Read-only (plan)", "plan"}
    ]
  end

  defp model_label(%Agent{model_provider: nil, model_id: nil}), do: nil
  defp model_label(%Agent{model_provider: nil, model_id: id}), do: id
  defp model_label(%Agent{model_provider: provider, model_id: nil}), do: provider
  defp model_label(%Agent{model_provider: provider, model_id: id}), do: "#{provider}/#{id}"

  defp initial(%Agent{name: name}), do: name |> String.first() |> String.upcase()

  # -- Render -------------------------------------------------------------------

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
      <%= case @live_action do %>
        <% :index -> %>
          <.index_page {assigns} />
        <% :new -> %>
          <.form_page {assigns} />
        <% :show -> %>
          <.show_page {assigns} />
        <% :edit -> %>
          <.form_page {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  # The list.
  defp index_page(assigns) do
    ~H"""
    <Layouts.page
      title="Agents"
      subtitle="Named coworkers backed by Claude Code or OpenCode and a role prompt"
      max_width="max-w-none"
    >
      <:actions>
        <.link navigate={~p"/teams"} id="agents-teams" class="btn btn-sm btn-ghost">
          <.icon name="hero-user-group" class="size-4" /> Teams
        </.link>
        <.link navigate={~p"/agents/gallery"} id="agents-gallery" class="btn btn-sm btn-ghost">
          <.icon name="hero-sparkles" class="size-4" /> Gallery
        </.link>
        <.link navigate={~p"/agents/import"} id="agents-import" class="btn btn-sm btn-ghost">
          <.icon name="hero-arrow-up-tray" class="size-4" /> Import
        </.link>
        <.link navigate={~p"/agents/new"} id="new-agent" class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> New agent
        </.link>
      </:actions>

      <Layouts.empty_state
        :if={@active_agents == []}
        id="agents-empty"
        icon="hero-cpu-chip"
        title="No agents yet"
      >
        Create one with <.link navigate={~p"/agents/new"} class="link link-primary">New agent</.link>. A good
        first pair is a builder and a reviewer.
      </Layouts.empty_state>

      <p
        id="default-models-hint"
        class="flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/60"
      >
        <span>Default models:</span>
        <%= for {engine, index} <- Enum.with_index(Canopy.Engine.names()) do %>
          <span :if={index > 0} aria-hidden="true">·</span>
          <span id={"default-model-#{engine}"}>
            {engine_label(engine)}
            <span class={["font-mono", default_label(@defaults, engine) && "text-base-content/80"]}>
              {default_label(@defaults, engine) || "its own default"}
            </span>
          </span>
        <% end %>
        <span aria-hidden="true">·</span>
        <.link navigate={~p"/settings"} id="default-models-settings" class="link link-primary">
          change in Settings
        </.link>
      </p>

      <Layouts.panel
        :if={@active_agents != []}
        id="agents-panel"
        title="Active agents"
        description="Mention an agent with @name in a channel to wake it. Open one for its channels, schedules, and settings."
      >
        <.export_bar :if={MapSet.size(@selected) > 0} selected={@selected} />
        <div class="-mx-2 hidden grid-cols-[1rem_2.25rem_minmax(0,1.2fr)_minmax(0,2fr)_10rem_14rem_3.5rem_1.25rem] items-center gap-4 px-2 pb-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/60 md:grid">
          <span class="sr-only">Select</span>
          <span />
          <span>Agent</span>
          <span>Role</span>
          <span>Engine</span>
          <span>Model</span>
          <span title="Active schedules">Sched.</span>
          <span />
        </div>
        <ul id="active-agents" class="divide-y divide-base-300">
          <%= for {group, agents} <- Agents.grouped(@active_agents) do %>
            <li
              :if={group}
              id={"agents-group-#{Layouts.group_slug(group)}"}
              class="-mx-2 px-2 pb-1 pt-3 text-[11px] font-semibold uppercase tracking-wider text-base-content/60"
            >
              {group}
            </li>
            <%!-- The row is a link stretched over the whole <li>: it paints above
                 the static cells, so a click anywhere opens the agent. Only the
                 model cell is lifted above it, to stay clickable on its own. --%>
            <li
              :for={agent <- agents}
              id={"agent-#{agent.id}"}
              class="group relative -mx-2 flex flex-col gap-2 rounded-lg px-2 py-3 transition hover:bg-base-200/60 md:grid md:grid-cols-[1rem_2.25rem_minmax(0,1.2fr)_minmax(0,2fr)_10rem_14rem_3.5rem_1.25rem] md:items-center md:gap-4"
            >
              <.link navigate={~p"/agents/#{agent.id}"} class="absolute inset-0 rounded-lg">
                <span class="sr-only">Open {agent.display_name}</span>
              </.link>
              <input
                type="checkbox"
                id={"select-agent-#{agent.id}"}
                class="checkbox checkbox-xs relative z-10"
                checked={MapSet.member?(@selected, agent.id)}
                phx-click="toggle_select"
                phx-value-id={agent.id}
                aria-label={"Select @#{agent.name} for export"}
              />
              <div class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 font-mono text-sm font-semibold text-base-content/70 group-hover:bg-base-300/70">
                {initial(agent)}
              </div>
              <div class="min-w-0">
                <div class="truncate text-sm font-semibold">{agent.display_name}</div>
                <div class="truncate font-mono text-xs text-base-content/60">@{agent.name}</div>
              </div>
              <p class="min-w-0 truncate text-sm text-base-content/75" title={agent.role}>
                {agent.role || "—"}
              </p>
              <span
                id={"engine-#{agent.id}"}
                class="min-w-0 truncate text-sm"
                title={
                  if agent.engine == "claude_code",
                    do: "Claude Code · #{agent.permission_mode}",
                    else: "OpenCode · agent #{agent.opencode_agent}"
                }
              >
                {engine_label(agent)}<span
                  :if={agent.engine == "opencode"}
                  class="text-base-content/60"
                > · {agent.opencode_agent}</span>
              </span>
              <button
                type="button"
                id={"model-#{agent.id}"}
                phx-click="open_model_picker"
                phx-value-id={agent.id}
                title={
                  if model_label(agent),
                    do: "Change this agent's model",
                    else: "Uses the default model; click to choose its own"
                }
                class={[
                  "relative max-w-full justify-self-start truncate rounded-md font-mono text-xs transition hover:ring-2 hover:ring-primary/40",
                  model_label(agent) && "badge badge-soft badge-primary badge-sm",
                  !model_label(agent) &&
                    "px-1.5 py-0.5 text-base-content/60 hover:text-base-content"
                ]}
              >
                {model_label(agent) || inherited_label(@defaults, agent.engine)}
              </button>
              <span
                :if={agent.routing_enabled}
                id={"routed-#{agent.id}"}
                class="badge badge-ghost badge-xs justify-self-start"
                title="Model routing is on (experimental): cheap wakes run on a light model"
              >
                routed
              </span>
              <span
                class="flex items-center gap-0.5 text-xs text-base-content/60"
                title="Active schedules"
              >
                <.icon
                  :if={Map.get(@schedule_counts, agent.id, 0) > 0}
                  name="hero-clock-mini"
                  class="size-3.5"
                />
                {if Map.get(@schedule_counts, agent.id, 0) > 0,
                  do: Map.get(@schedule_counts, agent.id),
                  else: "—"}
              </span>
              <.icon
                name="hero-chevron-right-mini"
                class="hidden size-4 shrink-0 text-base-content/30 group-hover:text-base-content/60 md:block"
              />
            </li>
          <% end %>
        </ul>

        <div :if={@inactive_agents != []} class="mt-4 border-t border-base-300 pt-3">
          <button
            type="button"
            id="toggle-inactive"
            class="flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content"
            phx-click="toggle_inactive"
          >
            <.icon
              name={if @show_inactive, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
              class="size-3.5"
            />
            {length(@inactive_agents)} deactivated
          </button>
          <ul :if={@show_inactive} id="inactive-agents" class="mt-2 flex flex-col gap-1">
            <li
              :for={agent <- @inactive_agents}
              id={"agent-#{agent.id}"}
              class="flex items-center gap-2 text-sm text-base-content/60"
            >
              <.link navigate={~p"/agents/#{agent.id}"} class="font-mono text-xs hover:underline">
                @{agent.name}
              </.link>
              <span class="truncate text-xs">{agent.role}</span>
              <button
                type="button"
                id={"reactivate-agent-#{agent.id}"}
                class="btn btn-ghost btn-xs ml-auto"
                phx-click="reactivate"
                phx-value-id={agent.id}
              >
                Reactivate
              </button>
            </li>
          </ul>
        </div>
      </Layouts.panel>

      <Layouts.panel
        :if={@active_agents != [] or @teams != []}
        id="agents-teams-panel"
        title="Teams"
        description="Crews you can add to a channel at once and mention as one @name. An agent can be on several."
      >
        <:actions>
          <.link navigate={~p"/teams/new"} id="agents-new-team" class="btn btn-ghost btn-xs">
            <.icon name="hero-plus-mini" class="size-3.5" /> New team
          </.link>
        </:actions>
        <ul :if={@teams != []} id="agents-teams-list" class="divide-y divide-base-300">
          <li
            :for={team <- @teams}
            id={"agents-team-#{team.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2"
          >
            <.link
              navigate={~p"/teams/#{team.id}/edit"}
              class="font-mono text-sm font-semibold hover:underline"
            >
              @{team.name}
            </.link>
            <span class="flex min-w-0 flex-wrap gap-1">
              <span
                :for={member <- team.members}
                class={[
                  "rounded-full border px-1.5 font-mono text-[11px]",
                  cond do
                    member.id == team.lead_agent_id -> "border-primary/40 text-primary"
                    member.active -> "border-base-300"
                    true -> "border-dashed border-base-300 text-base-content/40"
                  end
                ]}
                title={if member.id == team.lead_agent_id, do: "Lead", else: member.role}
              >
                @{member.name}
              </span>
            </span>
          </li>
        </ul>
        <p :if={@teams == []} class="text-xs text-base-content/60">
          No teams yet. <.link navigate={~p"/teams/new"} class="link link-primary">Create one</.link>
          to bring a crew into a channel in one step.
        </p>
      </Layouts.panel>

      <p :if={@inactive_agents != [] and @active_agents == []} class="text-xs text-base-content/60">
        {length(@inactive_agents)} deactivated agents can be brought back from their pages.
      </p>

      <.model_picker
        :if={@model_picker}
        agent={@model_picker}
        providers={@providers}
        defaults={@defaults}
      />
    </Layouts.page>
    """
  end

  attr :selected, :any, required: true

  # Shown while rows are selected: download them as one zip. A plain GET
  # form, so "Include memory" stays in the browser.
  defp export_bar(assigns) do
    ~H"""
    <form
      id="agents-export-bar"
      action={~p"/agents/export"}
      method="get"
      class="mb-3 flex flex-wrap items-center gap-3 rounded-lg bg-base-200 px-3 py-2 text-sm"
    >
      <input :for={id <- Enum.sort(@selected)} type="hidden" name="ids[]" value={id} />
      <span>{MapSet.size(@selected)} selected</span>
      <label class="flex cursor-pointer items-center gap-1.5 text-xs">
        <input
          type="checkbox"
          id="agents-export-memory"
          name="memory"
          value="1"
          class="checkbox checkbox-xs"
        /> Include memory
      </label>
      <button type="submit" id="agents-export-selected" class="btn btn-primary btn-xs">
        <.icon name="hero-arrow-down-tray-mini" class="size-3.5" />
        Export selected ({MapSet.size(@selected)})
      </button>
      <button
        type="button"
        id="agents-clear-selection"
        class="btn btn-ghost btn-xs"
        phx-click="clear_selection"
      >
        Clear
      </button>
    </form>
    """
  end

  attr :agent, :map, required: true
  attr :providers, :list, required: true
  attr :defaults, :map, required: true

  defp model_picker(assigns) do
    ~H"""
    <div
      id="model-picker"
      class="fixed inset-0 z-40 flex items-center justify-center bg-base-content/40 p-4"
      phx-window-keydown="close_model_picker"
      phx-key="Escape"
    >
      <div
        id="model-dialog"
        class="flex max-h-[80vh] w-full max-w-md flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-200 shadow-2xl"
        phx-click-away="close_model_picker"
      >
        <div class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-3">
          <div class="min-w-0">
            <h2 class="text-sm font-semibold">Model for @{@agent.name}</h2>
            <p class="mt-0.5 text-xs text-base-content/60">
              Takes effect on this agent's next turn; sessions already running keep theirs.
            </p>
          </div>
          <button
            type="button"
            id="close-model-picker"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="close_model_picker"
            aria-label="Close"
          >
            <.icon name="hero-x-mark-mini" class="size-4" />
          </button>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-2 py-2">
          <p
            :if={@agent.engine == "opencode" and @providers == []}
            id="model-picker-empty"
            class="px-3 py-6 text-center text-xs text-base-content/60"
          >
            No models to choose from: OpenCode did not answer. Start
            <code class="font-mono">opencode serve</code>
            and reload, or set the model on the agent's own page.
          </p>

          <button
            type="button"
            id="model-option-default"
            phx-click="pick_model"
            phx-value-provider=""
            phx-value-model=""
            class={[
              "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left transition hover:bg-base-300/60",
              is_nil(model_label(@agent)) && "bg-primary/10"
            ]}
          >
            <.icon
              name="hero-check-mini"
              class={["size-4 shrink-0", model_label(@agent) && "invisible"]}
            />
            <span class="min-w-0 flex-1">
              <span class="block text-sm font-medium">
                {if default_label(@defaults, @agent.engine),
                  do: default_option(@defaults, @agent.engine),
                  else: default_model_label(@agent)}
              </span>
              <span class="block text-xs text-base-content/60">
                <%= cond do %>
                  <% default_label(@defaults, @agent.engine) -> %>
                    Canopy's {engine_label(@agent)} default · change in Settings
                  <% @agent.engine == "claude_code" -> %>
                    Whatever Claude Code is set to use; pick a default in Settings.
                  <% true -> %>
                    Whatever <code class="font-mono">{@agent.opencode_agent}</code>
                    is configured to use.
                <% end %>
              </span>
            </span>
          </button>

          <div :if={@agent.engine == "claude_code"} class="mt-1">
            <p class="px-3 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/60">
              Claude Code
            </p>
            <button
              :for={model <- Agent.claude_models()}
              type="button"
              id={model_dom_id("claude", model)}
              phx-click="pick_model"
              phx-value-provider=""
              phx-value-model={model}
              class={[
                "flex w-full items-center gap-2 rounded-lg px-3 py-1.5 text-left transition hover:bg-base-300/60",
                current_model?(@agent, nil, model) && "bg-primary/10"
              ]}
            >
              <.icon
                name="hero-check-mini"
                class={["size-4 shrink-0", !current_model?(@agent, nil, model) && "invisible"]}
              />
              <span class="min-w-0 flex-1 truncate font-mono text-xs">{model}</span>
            </button>
          </div>

          <div :for={provider <- @providers} :if={@agent.engine == "opencode"} class="mt-1">
            <p class="px-3 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/60">
              {provider.name}
            </p>
            <button
              :for={model <- provider.models}
              type="button"
              id={model_dom_id(provider.id, model)}
              phx-click="pick_model"
              phx-value-provider={provider.id}
              phx-value-model={model}
              class={[
                "flex w-full items-center gap-2 rounded-lg px-3 py-1.5 text-left transition hover:bg-base-300/60",
                current_model?(@agent, provider.id, model) && "bg-primary/10"
              ]}
            >
              <.icon
                name="hero-check-mini"
                class={[
                  "size-4 shrink-0",
                  !current_model?(@agent, provider.id, model) && "invisible"
                ]}
              />
              <span class="min-w-0 flex-1 truncate font-mono text-xs">{model}</span>
              <span class="shrink-0 text-[11px] text-base-content/60">
                {price_of(@providers, provider.id, model)}
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp current_model?(%Agent{model_provider: provider, model_id: model}, provider, model),
    do: true

  defp current_model?(_agent, _provider, _model), do: false

  # Model ids carry dots and slashes; DOM ids must stay selector-safe.
  defp model_dom_id(provider, model),
    do: "model-option-" <> Regex.replace(~r/[^A-Za-z0-9_-]+/, "#{provider}-#{model}", "-")

  # One agent.
  defp show_page(assigns) do
    ~H"""
    <Layouts.page
      title={"@" <> @agent.name}
      subtitle={@agent.display_name}
      max_width="max-w-none"
    >
      <:actions>
        <.link navigate={~p"/agents"} class="btn btn-ghost btn-sm" id="back-to-agents">
          <.icon name="hero-arrow-left-mini" class="size-4" /> All agents
        </.link>
        <.link
          :if={@agent.active}
          href={~p"/dm/#{@agent.id}"}
          id={"message-agent-#{@agent.id}"}
          class="btn btn-sm btn-primary"
          title={"Open a direct message with @#{@agent.name}"}
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" /> Message
        </.link>
        <details id="export-agent" class="dropdown dropdown-end">
          <summary class="btn btn-sm" id={"export-agent-#{@agent.id}"}>
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export
          </summary>
          <div class="dropdown-content z-30 mt-1 flex w-64 flex-col gap-3 rounded-xl border border-base-300 bg-base-100 p-3 shadow-lg">
            <p class="text-xs text-base-content/70">
              A Markdown file with @{@agent.name}'s role, prompt and engine settings, to import on
              another machine. Never its channels, schedules or costs.
            </p>
            <%!-- a plain GET form: the download needs no round trip through the LiveView --%>
            <form
              id="export-agent-form"
              action={~p"/agents/#{@agent.id}/export"}
              method="get"
              class="flex flex-col gap-3"
            >
              <label class="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  id="export-agent-memory"
                  name="memory"
                  value="1"
                  class="checkbox checkbox-sm"
                /> Include memory
              </label>
              <button type="submit" id="export-agent-download" class="btn btn-primary btn-sm">
                Download {@agent.name}.md
              </button>
            </form>
          </div>
        </details>
        <.link
          navigate={~p"/agents/#{@agent.id}/edit"}
          id={"edit-agent-#{@agent.id}"}
          class="btn btn-sm"
        >
          <.icon name="hero-pencil-square" class="size-4" /> Edit
        </.link>
        <button
          :if={@agent.active}
          type="button"
          id={"deactivate-agent-#{@agent.id}"}
          class="btn btn-ghost btn-sm text-error"
          phx-click="deactivate"
          phx-value-id={@agent.id}
          data-canopy-confirm="It stops appearing in channels and mentions and its schedules pause; its history is kept."
          data-canopy-confirm-title={"Deactivate @#{@agent.name}?"}
          data-canopy-confirm-label="Deactivate"
          title="Deactivate"
        >
          <.icon name="hero-power" class="size-4" />
        </button>
        <button
          :if={!@agent.active}
          type="button"
          id={"reactivate-agent-#{@agent.id}"}
          class="btn btn-sm btn-outline"
          phx-click="reactivate"
          phx-value-id={@agent.id}
        >
          Reactivate
        </button>
      </:actions>

      <div
        id="agent-page"
        data-agent-id={@agent.id}
        class="grid items-start gap-6 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]"
      >
        <div class="flex flex-col gap-6">
          <Layouts.panel id="agent-about" title="About">
            <div class="flex items-start gap-4">
              <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-base-200 font-mono text-lg font-semibold text-base-content/70">
                {initial(@agent)}
              </div>
              <dl class="grid min-w-0 flex-1 grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-sm">
                <dt class="text-base-content/60">Status</dt>
                <dd>
                  <span :if={@agent.active} class="badge badge-sm badge-success badge-soft">active</span>
                  <span :if={!@agent.active} class="badge badge-sm badge-ghost">deactivated</span>
                </dd>
                <dt class="text-base-content/60">Role</dt>
                <dd>{@agent.role || "—"}</dd>
                <dt class="text-base-content/60">Engine</dt>
                <dd id="agent-engine">{engine_label(@agent)}</dd>
                <%= if @agent.engine == "claude_code" do %>
                  <dt class="text-base-content/60">Permissions</dt>
                  <dd id="agent-permissions" class="font-mono text-xs">
                    {@agent.permission_mode}{effort_text(@agent, @default_effort)}
                  </dd>
                <% else %>
                  <dt class="text-base-content/60">OpenCode agent</dt>
                  <dd class="font-mono text-xs">{@agent.opencode_agent}</dd>
                <% end %>
                <dt class="text-base-content/60">Model</dt>
                <dd id="agent-model" class="font-mono text-xs">
                  <%= cond do %>
                    <% model_label(@agent) -> %>
                      {model_label(@agent)}
                    <% default_label(@defaults, @agent.engine) -> %>
                      {default_label(@defaults, @agent.engine)}
                      <span class="font-sans text-base-content/60">
                        (<.link
                          navigate={settings_anchor(@agent.engine)}
                          id="agent-model-default"
                          class="link"
                          title="The default model, set in Settings"
                        >default</.link>)
                      </span>
                    <% true -> %>
                      {default_model_label(@agent)}
                  <% end %>
                  <span
                    :if={agent_price_line(@agent, @providers, @defaults, @server_defaults)}
                    id="agent-model-price"
                    class="ml-1 font-sans text-base-content/60"
                  >
                    {agent_price_line(@agent, @providers, @defaults, @server_defaults)}
                  </span>
                </dd>
                <dt class="text-base-content/60">Routing</dt>
                <dd id="agent-routing" class="text-xs">
                  {routing_text(@agent, @light_profile)}
                  <span
                    :if={@agent.routing_enabled}
                    class="ml-1 badge badge-warning badge-soft badge-xs"
                    title="Unverified until the Phase 0 spike; see the user guide"
                  >
                    experimental
                  </span>
                </dd>
                <dt class="text-base-content/60">Spend</dt>
                <dd id="agent-spend" class="text-xs tabular-nums">
                  {Canopy.Costs.money(@agent_spend.today)} today · {Canopy.Costs.money(
                    @agent_spend.week
                  )} this week · {Canopy.Costs.money(@agent_spend.all)} all time
                </dd>
              </dl>
            </div>
            <div :if={@agent.system_prompt} class="mt-4">
              <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/60">
                System prompt
              </p>
              <pre
                id="agent-system-prompt"
                class="max-h-96 overflow-auto whitespace-pre-wrap rounded-md bg-base-100 p-3 font-mono text-xs leading-relaxed text-base-content/80"
              >{@agent.system_prompt}</pre>
            </div>
          </Layouts.panel>

          <Layouts.panel
            :if={@agent.routing_enabled or @routing_pauses != [] or @rule_stats != []}
            id="agent-routing-panel"
            title="Model routing"
            description="Experimental, unverified until the Phase 0 spike. A rule pauses when at least 10 of its last 20 light turns exist and 35% or more escalated."
          >
            <ul :if={@routing_pauses != []} class="mb-3 flex flex-col gap-2">
              <li
                :for={pause <- @routing_pauses}
                id={"routing-pause-#{pause.wake_kind}"}
                class="flex items-center gap-2 rounded-md bg-warning/10 px-3 py-2 text-sm"
              >
                <.icon name="hero-pause-circle-mini" class="size-4 shrink-0 text-warning" />
                <span class="min-w-0 flex-1">
                  Routing paused for {routing_kind_label(pause.wake_kind)}: {pause.reason}
                </span>
                <button
                  type="button"
                  id={"resume-routing-#{pause.wake_kind}"}
                  class="btn btn-xs"
                  phx-click="resume_routing"
                  phx-value-kind={pause.wake_kind}
                >
                  Resume
                </button>
              </li>
            </ul>
            <table :if={@rule_stats != []} id="routing-rule-stats" class="table table-xs">
              <thead>
                <tr>
                  <th>Wake kind</th>
                  <th class="text-right">Light turns</th>
                  <th class="text-right">Escalated</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rule_stats} id={"rule-stat-#{row.kind}"}>
                  <td>{String.replace(row.kind, "_", " ")}</td>
                  <td class="text-right tabular-nums">{row.turns}</td>
                  <td class="text-right tabular-nums">
                    {row.escalated} ({round(row.rate * 100)}%)
                  </td>
                </tr>
              </tbody>
            </table>
            <p
              :if={@routing_pauses == [] and @rule_stats == []}
              class="text-xs text-base-content/60"
            >
              No light turns yet.
            </p>
          </Layouts.panel>

          <Layouts.panel
            id="agent-channels"
            title="Channels"
            description="Where this agent is a member. Owned channels are marked."
          >
            <ul :if={@agent_channels != []} class="divide-y divide-base-300">
              <li
                :for={channel <- @agent_channels}
                id={"agent-channel-#{channel.id}"}
                class="flex items-center gap-2 py-2 text-sm"
              >
                <.icon
                  name={
                    if Channels.dm?(channel),
                      do: "hero-chat-bubble-left-right-mini",
                      else: "hero-hashtag-mini"
                  }
                  class="size-4 shrink-0 text-base-content/40"
                />
                <.link navigate={~p"/channels/#{channel.id}"} class="min-w-0 truncate hover:underline">
                  {if Channels.dm?(channel), do: Channels.dm_label(channel), else: channel.name}
                </.link>
                <span
                  :if={channel.owner_agent_id == @agent.id}
                  class="rounded-full bg-primary/10 px-1.5 text-[10px] font-medium uppercase tracking-wide text-primary"
                >
                  owner
                </span>
                <span :if={channel.status == "archived"} class="badge badge-ghost badge-xs">archived</span>
                <span class="ml-auto truncate text-xs text-base-content/60">{channel.repository.name}</span>
                <.link
                  navigate={~p"/channels/#{channel.id}/agents/#{@agent.id}/transcript"}
                  id={"agent-channel-#{channel.id}-transcript"}
                  class="btn btn-ghost btn-xs shrink-0 gap-1 text-base-content/60"
                  title={"@#{@agent.name}'s session transcript in this channel"}
                >
                  <.icon name="hero-document-text-mini" class="size-3.5" /> Transcript
                </.link>
              </li>
            </ul>
            <p :if={@agent_channels == []} class="text-xs text-base-content/60">
              Not in any channel yet.
            </p>
          </Layouts.panel>

          <Layouts.panel
            id="agent-teams"
            title="Teams"
            description="Teams this agent is on. Leads are marked."
          >
            <ul :if={@agent_teams != []} class="divide-y divide-base-300">
              <li
                :for={team <- @agent_teams}
                id={"agent-team-#{team.id}"}
                class="flex items-center gap-2 py-2 text-sm"
              >
                <.icon name="hero-user-group-mini" class="size-4 shrink-0 text-base-content/40" />
                <.link navigate={~p"/teams/#{team.id}/edit"} class="font-mono text-xs hover:underline">
                  @{team.name}
                </.link>
                <span
                  :if={team.lead_agent_id == @agent.id}
                  class="rounded-full bg-primary/10 px-1.5 text-[10px] font-medium uppercase tracking-wide text-primary"
                >
                  lead
                </span>
                <span class="ml-auto truncate text-xs text-base-content/60">
                  {length(team.members)} {if length(team.members) == 1, do: "member", else: "members"}
                </span>
              </li>
            </ul>
            <p :if={@agent_teams == []} class="text-xs text-base-content/60">
              Not on any team. <.link navigate={~p"/teams"} class="link link-primary">Teams</.link>
            </p>
          </Layouts.panel>
        </div>

        <div class="flex flex-col gap-6">
          <Layouts.panel
            id="agent-memory-panel"
            title="Memory"
            description="What this agent carries across repositories and channels. It goes into every prompt. The agent keeps it current, and you can edit it here."
          >
            <:actions>
              <span
                :if={@memory_updated_at}
                class="text-[11px] text-base-content/60"
                title={DateTime.to_iso8601(@memory_updated_at)}
              >
                updated {Schedules.relative(@memory_updated_at)}
              </span>
              <button
                :if={!@editing_memory?}
                type="button"
                id="edit-memory"
                class="btn btn-ghost btn-xs"
                phx-click="edit_memory"
              >
                <.icon name="hero-pencil-square" class="size-4" /> Edit
              </button>
            </:actions>

            <div
              :if={!@editing_memory? and @agent_memory == ""}
              id="agent-memory-empty"
              class="text-xs text-base-content/60"
            >
              Nothing remembered yet. It fills in as the agent works, or write the first entry yourself.
            </div>
            <div
              :if={!@editing_memory? and @agent_memory != ""}
              id="agent-memory"
              class="max-h-[32rem] overflow-y-auto text-sm"
            >
              <.message_text
                body={@agent_memory}
                mentions={Enum.map(@active_agents ++ @teams, & &1.name)}
              />
            </div>

            <form
              :if={@editing_memory?}
              id="memory-form"
              phx-submit="save_memory"
              class="flex flex-col gap-2"
            >
              <textarea
                id="memory-input"
                name="memory"
                rows="16"
                class="w-full textarea font-mono text-xs leading-relaxed"
                spellcheck="false"
              >{@agent_memory}</textarea>
              <div class="flex items-center justify-end gap-2">
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_memory">Cancel</button>
                <.button type="submit" variant="primary" id="save-memory">Save memory</.button>
              </div>
            </form>
          </Layouts.panel>

          <Layouts.panel
            id="agent-schedules-panel"
            title="Scheduled"
            description="Across every channel. Ask the agent to schedule or cancel, or cancel here."
          >
            <.schedule_list
              id="agent-schedules"
              schedules={@agent_schedules}
              scope={:agent}
              empty="Nothing scheduled for this agent."
            />
          </Layouts.panel>
        </div>
      </div>
    </Layouts.page>
    """
  end

  # Create (no @agent) or edit (@agent set).
  defp form_page(assigns) do
    ~H"""
    <Layouts.page
      title={if @agent, do: "Edit @#{@agent.name}", else: "New agent"}
      subtitle="The role and system prompt are sent with every prompt; OpenCode's own agent prompt still applies."
      max_width="max-w-4xl"
    >
      <:actions>
        <.link
          navigate={if @agent, do: ~p"/agents/#{@agent.id}", else: ~p"/agents"}
          id="cancel-edit"
          class="btn btn-ghost btn-sm"
        >
          Cancel
        </.link>
      </:actions>

      <Layouts.panel id="agent-form-panel" title={if @agent, do: "Settings", else: "Details"}>
        <.form
          for={@form}
          id="agent-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col gap-3"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:name]}
              type="text"
              label="Name (slug, used as @name)"
              placeholder="backend"
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:display_name]}
              type="text"
              label="Display name"
              placeholder="Backend engineer"
              autocomplete="off"
            />
          </div>
          <div class="grid gap-3 sm:grid-cols-[1fr_14rem]">
            <.input
              field={@form[:role]}
              type="text"
              label="Role (one line)"
              placeholder="Owns the Phoenix backend and its tests"
              autocomplete="off"
            />
            <.input
              field={@form[:group]}
              type="text"
              label="Group (optional)"
              placeholder="Engineering"
              list="agent-groups"
              autocomplete="off"
            />
            <datalist id="agent-groups">
              <option :for={group <- @groups} value={group} />
            </datalist>
          </div>
          <.input
            field={@form[:system_prompt]}
            type="textarea"
            label="System prompt"
            rows="8"
            placeholder="You are the backend engineer on this project. Prefer small, well-tested changes…"
            class="w-full textarea font-mono text-xs leading-relaxed"
          />
          <.input
            field={@form[:engine]}
            type="select"
            id="agent-engine-select"
            label="Engine"
            options={engine_options()}
          />
          <%= if @form[:engine].value == "claude_code" do %>
            <div class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@form[:model_id]}
                type="select"
                id="claude-model"
                label="Model"
                prompt={default_option(@defaults, "claude_code")}
                options={Agent.claude_models()}
              />
              <.input
                field={@form[:effort]}
                type="select"
                id="claude-effort"
                label="Effort"
                prompt={default_effort_option(@default_effort)}
                options={Agent.efforts()}
              />
              <.input
                field={@form[:permission_mode]}
                type="select"
                id="claude-permission-mode"
                label="Permissions"
                options={permission_mode_options()}
              />
            </div>
            <.input
              field={@form[:allowed_tools]}
              type="textarea"
              id="claude-allowed-tools"
              label="Tools that run without asking (one per line or comma-separated; blank for the default set)"
              rows="3"
              placeholder="Read, Glob, Grep, Edit, Write, Bash(git *)"
              class="w-full textarea font-mono text-xs leading-relaxed"
            />
            <p class="text-xs text-base-content/60">
              Permissions: <em>ask first</em>
              puts every tool not on the list on a permission
              card in the channel; <em>auto-approve edits</em>
              also lets file edits through; <em>read-only</em>
              is plan mode. The Canopy tools are always allowed. Model aliases <code class="font-mono">fable</code>, <code class="font-mono">opus</code>, <code class="font-mono">sonnet</code>, and
              <code class="font-mono">haiku</code>
              name the latest of each family; Claude Code picks the exact version. <em>Default</em>
              follows the model and effort set in <.link
                navigate={settings_anchor("claude_code")}
                class="link"
              >Settings</.link>.
            </p>
          <% else %>
            <div class="grid gap-3 sm:grid-cols-3">
              <.input
                field={@form[:opencode_agent]}
                type="select"
                id="opencode-agents"
                label="OpenCode agent"
                options={opencode_agent_options(@opencode_agents, @form[:opencode_agent].value)}
              />
              <%= if @providers != [] do %>
                <.input
                  field={@form[:model_provider]}
                  type="select"
                  label="Model provider (optional)"
                  prompt={default_option(@defaults, "opencode")}
                  options={Providers.provider_options(@providers, @form[:model_provider].value)}
                />
                <.input
                  field={@form[:model_id]}
                  type="select"
                  label="Model (optional)"
                  prompt={
                    if @form[:model_provider].value, do: "Pick a model", else: "Pick a provider first"
                  }
                  options={
                    Providers.model_options(
                      @providers,
                      @form[:model_provider].value,
                      @form[:model_id].value
                    )
                  }
                  disabled={
                    is_nil(@form[:model_provider].value) or @form[:model_provider].value == ""
                  }
                />
              <% else %>
                <.input
                  field={@form[:model_provider]}
                  type="text"
                  label="Model provider (optional)"
                  placeholder="opencode"
                  autocomplete="off"
                  spellcheck="false"
                />
                <.input
                  field={@form[:model_id]}
                  type="text"
                  label="Model id (optional)"
                  placeholder="claude-haiku-4-5"
                  autocomplete="off"
                  spellcheck="false"
                />
              <% end %>
            </div>
            <p :if={@providers != []} id="model-price" class="-mt-1 text-xs text-base-content/60">
              {form_price_line(@form, @providers, @defaults, @server_defaults)}
            </p>
            <p class="text-xs text-base-content/60">
              <code class="font-mono">build</code>
              can edit files; <code class="font-mono">plan</code>
              is read-only, a good fit for advisory roles. Agents from your OpenCode config appear
              once a repository is registered and <code class="font-mono">opencode serve</code>
              is up.
              <%= cond do %>
                <% default_label(@defaults, "opencode") -> %>
                  Leave the model blank to use the default, {default_label(@defaults, "opencode")} (<.link
                    navigate={settings_anchor("opencode")}
                    class="link"
                  >Settings</.link>).
                <% @providers != [] -> %>
                  Leave the model blank to use that agent's default.
                <% true -> %>
                  Leave the model blank to use OpenCode's default.
              <% end %>
            </p>
          <% end %>
          <.routing_fields
            form={@form}
            providers={@providers}
            light_defaults={@light_defaults}
          />
          <div class="flex items-center gap-2 pt-1">
            <.button type="submit" variant="primary" id="save-agent">
              {if @agent, do: "Save changes", else: "Create agent"}
            </.button>
          </div>
        </.form>
      </Layouts.panel>
    </Layouts.page>
    """
  end

  attr :form, :any, required: true
  attr :providers, :list, required: true
  attr :light_defaults, :map, required: true

  # Model routing on the edit form: off by default, experimental, with the
  # light model and effort in the same pattern as the main ones.
  defp routing_fields(assigns) do
    ~H"""
    <fieldset
      id="agent-routing-fields"
      class="flex flex-col gap-3 rounded-lg border border-base-300 p-3"
    >
      <legend class="flex items-center gap-2 px-1 text-sm font-medium">
        Model routing <span class="badge badge-warning badge-soft badge-xs">experimental</span>
      </legend>
      <p id="routing-experimental-note" class="text-xs text-warning">
        Unverified until the Phase 0 spike — see docs. Leave it off unless you are testing it.
      </p>
      <.input
        field={@form[:routing_enabled]}
        type="checkbox"
        id="agent-routing-enabled"
        label="Run cheap wakes on a light model"
      />
      <%= if @form[:engine].value == "claude_code" do %>
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:light_model_id]}
            type="select"
            id="claude-light-model"
            label="Light model"
            prompt={light_default_option(@light_defaults, "claude_code")}
            options={Agent.claude_models()}
          />
          <.input
            field={@form[:light_effort]}
            type="select"
            id="claude-light-effort"
            label="Light effort"
            prompt={light_effort_option(@light_defaults)}
            options={Agent.efforts()}
          />
        </div>
      <% else %>
        <div class="grid gap-3 sm:grid-cols-2">
          <%= if @providers != [] do %>
            <.input
              field={@form[:light_model_provider]}
              type="select"
              id="opencode-light-provider"
              label="Light model provider"
              prompt={light_default_option(@light_defaults, "opencode")}
              options={Providers.provider_options(@providers, @form[:light_model_provider].value)}
            />
            <.input
              field={@form[:light_model_id]}
              type="select"
              id="opencode-light-model"
              label="Light model"
              prompt={
                if @form[:light_model_provider].value,
                  do: "Pick a model",
                  else: "Pick a provider first"
              }
              options={
                Providers.model_options(
                  @providers,
                  @form[:light_model_provider].value,
                  @form[:light_model_id].value
                )
              }
              disabled={
                is_nil(@form[:light_model_provider].value) or
                  @form[:light_model_provider].value == ""
              }
            />
          <% else %>
            <.input
              field={@form[:light_model_provider]}
              type="text"
              id="opencode-light-provider"
              label="Light model provider (optional)"
              placeholder="opencode"
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:light_model_id]}
              type="text"
              id="opencode-light-model"
              label="Light model id (optional)"
              placeholder="claude-haiku-4-5"
              autocomplete="off"
              spellcheck="false"
            />
          <% end %>
        </div>
      <% end %>
      <p class="text-xs text-base-content/60">
        With routing on, scheduled checks, delegation reports, accepted handoffs, unaddressed
        agent posts reaching this agent as owner, and agent acknowledgements run on the light
        model; the agent can call <code class="font-mono">canopy_escalate</code>
        to re-run the wake on its main model. Your own messages, delegated tasks, playbook steps,
        and watches always use the main model, and so does any wake while its main cache is still
        warm. Routing does nothing until a light model is set here or in Settings.
      </p>
    </fieldset>
    """
  end
end
