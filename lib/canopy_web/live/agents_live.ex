defmodule CanopyWeb.AgentsLive do
  @moduledoc """
  Agents, in four pages under one LiveView:

    * `/agents` — the list (active, plus deactivated behind a toggle)
    * `/agents/new` — the create form
    * `/agents/:id` — one agent: identity, model, channels, schedules, actions
    * `/agents/:id/edit` — the edit form for that agent

  The OpenCode agent picker is a select filled from `GET /agent` for the
  first repository (always offering the built-in `build` and `plan`), and the provider/model selects come from
  `GET /config/providers`; both degrade to plain inputs when OpenCode is away.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Channels, Memory, Repositories, Schedules}
  alias Canopy.Agents.Agent
  alias Canopy.OpenCode.Client
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
      |> assign(:default_models, %{})
      |> assign(:show_inactive, false)
      |> assign(:agent, nil)
      |> assign(:agent_channels, [])
      |> assign(:agent_schedules, [])
      |> assign(:agent_memory, "")
      |> assign(:memory_updated_at, nil)
      |> assign(:editing_memory?, false)
      |> assign_form(Agents.change(%Agent{}))
      |> load_agents()

    if connected?(socket), do: Memory.subscribe()

    socket =
      if connected?(socket) do
        socket
        |> fetch_opencode_agents()
        |> start_async(:providers, fn -> Client.impl().providers([]) end)
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

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Events -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    changeset =
      (socket.assigns.agent || %Agent{})
      |> Agents.change(blank_to_nil(params))
      |> validate_model(socket.assigns.providers)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"agent" => params}, socket) do
    params = blank_to_nil(params)
    editing = socket.assigns.agent || %Agent{}
    checked = editing |> Agents.change(params) |> validate_model(socket.assigns.providers)

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

  # "" for both fields clears the override, putting the agent back on whatever
  # model its OpenCode agent defaults to.
  def handle_event("pick_model", %{"provider" => provider, "model" => model}, socket) do
    agent = socket.assigns.model_picker
    attrs = blank_to_nil(%{"model_provider" => provider, "model_id" => model})

    case Agents.update(agent, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:model_picker, nil)
         |> load_agents()
         |> put_flash(:info, model_saved(updated))}

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

  def handle_async(:providers, {:ok, {:ok, %{"providers" => list} = body}}, socket)
      when is_list(list) do
    providers =
      list
      |> Enum.flat_map(fn
        %{"id" => id} = p when is_binary(id) ->
          model_map = Map.get(p, "models", %{})
          models = model_map |> Map.keys() |> Enum.sort()
          pricing = Map.new(model_map, fn {mid, m} -> {mid, pricing_of(m)} end)
          [%{id: id, name: Map.get(p, "name") || id, models: models, pricing: pricing}]

        _ ->
          []
      end)
      |> Enum.sort_by(& &1.id)

    {:noreply,
     socket
     |> assign(:providers, providers)
     |> assign(:default_models, Map.get(body, "default", %{}))}
  end

  def handle_async(:providers, _other, socket), do: {:noreply, assign(socket, :providers, [])}

  # models.dev pricing, in dollars per million tokens; nil when OpenCode has none
  defp pricing_of(%{"cost" => %{} = cost}) do
    %{
      input: number(cost["input"]),
      output: number(cost["output"]),
      cache_read: number(get_in(cost, ["cache", "read"]))
    }
  end

  defp pricing_of(_), do: nil

  defp number(n) when is_number(n), do: n / 1
  defp number(_), do: 0.0

  @doc false
  def pricing(providers, provider, model) when is_binary(provider) and is_binary(model) do
    case Enum.find(providers, &(&1.id == provider)) do
      %{pricing: pricing} -> Map.get(pricing, model)
      _ -> nil
    end
  end

  def pricing(_providers, _provider, _model), do: nil

  @doc false
  def price_text(nil, _providers, _provider), do: nil

  # A provider whose every model costs $0 is not free: OpenCode has no per-token
  # price for it, typically a subscription login (ChatGPT, Claude) that bills
  # by plan. A $0 model among priced ones really is free.
  def price_text(%{input: i, output: o, cache_read: c}, providers, provider) do
    cond do
      i == 0 and o == 0 and provider_unpriced?(providers, provider) ->
        "no per-token price reported by OpenCode; usually a subscription login billed by plan"

      i == 0 and o == 0 ->
        "free"

      true ->
        cache = if c > 0, do: " · cached input #{dollars(c)}", else: ""
        "#{dollars(i)} in / #{dollars(o)} out per million tokens#{cache}"
    end
  end

  defp provider_unpriced?(providers, provider) do
    case Enum.find(providers, &(&1.id == provider)) do
      %{pricing: pricing} when map_size(pricing) > 0 ->
        Enum.all?(pricing, fn {_, p} -> is_nil(p) or (p.input == 0 and p.output == 0) end)

      _ ->
        true
    end
  end

  defp dollars(n) when n >= 1, do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  defp dollars(n),
    do:
      "$" <>
        (:erlang.float_to_binary(n / 1, decimals: 3)
         |> String.trim_trailing("0")
         |> String.trim_trailing("."))

  @doc false
  def agent_price_line(agent, providers, defaults) do
    case effective_model(agent, defaults) do
      nil ->
        nil

      {p, m} ->
        prefix = if is_nil(model_label(agent)), do: "(#{p}/#{m}) ", else: ""
        prefix <> (price_text(pricing(providers, p, m), providers, p) || "price unknown")
    end
  end

  @doc false
  def form_price_line(form, providers, defaults) do
    provider = form[:model_provider].value
    model = form[:model_id].value
    picked? = is_binary(provider) and provider != "" and is_binary(model) and model != ""

    case if(picked?, do: {provider, model}, else: effective_model(%Agent{}, defaults)) do
      nil ->
        "Pick a model to see its price."

      {p, m} ->
        note = if picked?, do: "", else: " (OpenCode's default)"

        "#{p}/#{m}#{note} — #{price_text(pricing(providers, p, m), providers, p) || "price unknown"}"
    end
  end

  # The model an agent actually runs on: its override, else OpenCode's default
  # for the first provider that has one.
  defp effective_model(%Agent{model_provider: p, model_id: m}, _defaults)
       when is_binary(p) and is_binary(m),
       do: {p, m}

  defp effective_model(_agent, defaults) when map_size(defaults) > 0 do
    {p, m} = Enum.min_by(defaults, fn {p, _} -> p end)
    {p, m}
  end

  defp effective_model(_agent, _defaults), do: nil

  # With the provider list known, a model override must name a configured provider
  # and one of its models; otherwise OpenCode rejects every prompt at run time.
  defp validate_model(changeset, []), do: changeset

  defp validate_model(changeset, providers) do
    provider = Ecto.Changeset.get_field(changeset, :model_provider)
    model = Ecto.Changeset.get_field(changeset, :model_id)

    case {provider, model, Enum.find(providers, &(&1.id == provider))} do
      {nil, nil, _} ->
        changeset

      {nil, _model, _} ->
        Ecto.Changeset.add_error(changeset, :model_provider, "pick a provider for this model")

      {_provider, _model, nil} ->
        Ecto.Changeset.add_error(changeset, :model_provider, "is not configured in OpenCode")

      {_provider, nil, _} ->
        Ecto.Changeset.add_error(changeset, :model_id, "pick a model from #{provider}")

      {_provider, model, %{models: models}} ->
        if model in models,
          do: changeset,
          else:
            Ecto.Changeset.add_error(changeset, :model_id, "is not available from #{provider}")
    end
  end

  defp model_saved(agent) do
    case model_label(agent) do
      nil -> "@#{agent.name} is back on its OpenCode default model."
      label -> "@#{agent.name} now runs on #{label}."
    end
  end

  defp provider_options(providers, current) do
    known = Enum.map(providers, &{provider_label(&1), &1.id})

    if current && not Enum.any?(providers, &(&1.id == current)),
      do: known ++ [{"#{current} (not configured)", current}],
      else: known
  end

  # "OpenAI" reads better than "OpenAI (openai)"; the id is shown only when it
  # is not obvious from the name.
  defp provider_label(%{id: id, name: name}) do
    if String.downcase(name) |> String.replace(~r/[^a-z0-9]/, "") ==
         String.replace(id, ~r/[^a-z0-9]/, ""),
       do: name,
       else: "#{name} (#{id})"
  end

  defp model_options(providers, provider, current) do
    models =
      case Enum.find(providers, &(&1.id == provider)) do
        %{models: models} -> models
        nil -> []
      end

    options = Enum.map(models, &{&1, &1})

    if current && current not in models,
      do: options ++ [{"#{current} (not available)", current}],
      else: options
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

  defp load_agents(socket) do
    {active, inactive} = Agents.list() |> Enum.split_with(& &1.active)

    socket
    |> assign(:active_agents, active)
    |> assign(:inactive_agents, inactive)
    |> assign(:groups, Agents.groups())
    |> assign(:schedule_counts, Schedules.active_counts_by_agent())
  end

  defp load_agent_details(%{assigns: %{agent: %Agent{id: id}}} = socket) do
    channels =
      Channels.list()
      |> Enum.filter(fn channel -> Enum.any?(channel.agents, &(&1.id == id)) end)
      |> Enum.sort_by(&{&1.kind != "channel", &1.status, &1.name})

    socket
    |> assign(:agent_channels, channels)
    |> assign(:agent_schedules, Schedules.list_for_agent(id))
    |> assign(:agent_spend, agent_spend(id))
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

  defp load_memory(%{assigns: %{agent: %Agent{id: id}}} = socket) do
    socket
    |> assign(:agent_memory, Memory.get(id))
    |> assign(:memory_updated_at, Memory.updated_at(id))
  end

  defp load_memory(socket), do: socket

  # Empty optional strings should clear a field rather than fail validation.
  defp blank_to_nil(params) do
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
      schedule_counts={@schedule_counts}
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
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
      subtitle="Named coworkers backed by OpenCode agents and a role prompt"
      max_width="max-w-none"
    >
      <:actions>
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

      <Layouts.panel
        :if={@active_agents != []}
        id="agents-panel"
        title="Active agents"
        description="Mention an agent with @name in a channel to wake it. Open one for its channels, schedules, and settings."
      >
        <div class="-mx-2 hidden grid-cols-[2.25rem_minmax(0,1.2fr)_minmax(0,2fr)_6rem_14rem_3.5rem_1.25rem] items-center gap-4 px-2 pb-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/50 md:grid">
          <span />
          <span>Agent</span>
          <span>Role</span>
          <span>OpenCode agent</span>
          <span>Model</span>
          <span title="Active schedules">Sched.</span>
          <span />
        </div>
        <ul id="active-agents" class="divide-y divide-base-300">
          <%= for {group, agents} <- Agents.grouped(@active_agents) do %>
            <li
              :if={group}
              id={"agents-group-#{Layouts.group_slug(group)}"}
              class="-mx-2 px-2 pb-1 pt-3 text-[11px] font-semibold uppercase tracking-wider text-base-content/50"
            >
              {group}
            </li>
            <%!-- The row is a link stretched over the whole <li>: it paints above
                 the static cells, so a click anywhere opens the agent. Only the
                 model cell is lifted above it, to stay clickable on its own. --%>
            <li
              :for={agent <- agents}
              id={"agent-#{agent.id}"}
              class="group relative -mx-2 flex flex-col gap-2 rounded-lg px-2 py-3 transition hover:bg-base-200/60 md:grid md:grid-cols-[2.25rem_minmax(0,1.2fr)_minmax(0,2fr)_6rem_14rem_3.5rem_1.25rem] md:items-center md:gap-4"
            >
              <.link navigate={~p"/agents/#{agent.id}"} class="absolute inset-0 rounded-lg">
                <span class="sr-only">Open {agent.display_name}</span>
              </.link>
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
                class="badge badge-ghost badge-sm justify-self-start font-mono"
                title="OpenCode agent"
              >
                {agent.opencode_agent}
              </span>
              <button
                type="button"
                id={"model-#{agent.id}"}
                phx-click="open_model_picker"
                phx-value-id={agent.id}
                title="Change this agent's model"
                class={[
                  "relative max-w-full justify-self-start truncate rounded-md font-mono text-xs transition hover:ring-2 hover:ring-primary/40",
                  model_label(agent) && "badge badge-soft badge-primary badge-sm",
                  !model_label(agent) &&
                    "px-1.5 py-0.5 text-base-content/50 hover:text-base-content"
                ]}
              >
                {model_label(agent) || "default"}
              </button>
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

      <p :if={@inactive_agents != [] and @active_agents == []} class="text-xs text-base-content/60">
        {length(@inactive_agents)} deactivated agents can be brought back from their pages.
      </p>

      <.model_picker
        :if={@model_picker}
        agent={@model_picker}
        providers={@providers}
        defaults={@default_models}
      />
    </Layouts.page>
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
            :if={@providers == []}
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
              <span class="block text-sm font-medium">OpenCode default</span>
              <span class="block text-xs text-base-content/60">
                Whatever <code class="font-mono">{@agent.opencode_agent}</code> is configured to use.
              </span>
            </span>
          </button>

          <div :for={provider <- @providers} class="mt-1">
            <p class="px-3 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
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
              <span class="shrink-0 text-[11px] text-base-content/50">
                {price_text(pricing(@providers, provider.id, model), @providers, provider.id)}
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
                <dt class="text-base-content/50">Status</dt>
                <dd>
                  <span :if={@agent.active} class="badge badge-sm badge-success badge-soft">active</span>
                  <span :if={!@agent.active} class="badge badge-sm badge-ghost">deactivated</span>
                </dd>
                <dt class="text-base-content/50">Role</dt>
                <dd>{@agent.role || "—"}</dd>
                <dt class="text-base-content/50">OpenCode agent</dt>
                <dd class="font-mono text-xs">{@agent.opencode_agent}</dd>
                <dt class="text-base-content/50">Model</dt>
                <dd class="font-mono text-xs">
                  {model_label(@agent) || "OpenCode default"}
                  <span
                    :if={agent_price_line(@agent, @providers, @default_models)}
                    id="agent-model-price"
                    class="ml-1 font-sans text-base-content/60"
                  >
                    {agent_price_line(@agent, @providers, @default_models)}
                  </span>
                </dd>
                <dt class="text-base-content/50">Spend</dt>
                <dd id="agent-spend" class="text-xs tabular-nums">
                  {Canopy.Costs.money(@agent_spend.today)} today · {Canopy.Costs.money(
                    @agent_spend.week
                  )} this week · {Canopy.Costs.money(@agent_spend.all)} all time
                </dd>
              </dl>
            </div>
            <div :if={@agent.system_prompt} class="mt-4">
              <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
                System prompt
              </p>
              <pre
                id="agent-system-prompt"
                class="max-h-96 overflow-auto whitespace-pre-wrap rounded-md bg-base-100 p-3 font-mono text-xs leading-relaxed text-base-content/80"
              >{@agent.system_prompt}</pre>
            </div>
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
                <span class="ml-auto truncate text-xs text-base-content/50">{channel.repository.name}</span>
              </li>
            </ul>
            <p :if={@agent_channels == []} class="text-xs text-base-content/50">
              Not in any channel yet.
            </p>
          </Layouts.panel>
        </div>

        <div class="flex flex-col gap-6">
          <Layouts.panel
            id="agent-memory-panel"
            title="Memory"
            description="What this agent carries across repositories and channels. It goes into every prompt; the agent updates it with canopy_memory_write, and you can edit it here."
          >
            <:actions>
              <span
                :if={@memory_updated_at}
                class="text-[11px] text-base-content/50"
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
              class="text-xs text-base-content/50"
            >
              Nothing remembered yet. It fills in as the agent works, or write the first entry yourself.
            </div>
            <div
              :if={!@editing_memory? and @agent_memory != ""}
              id="agent-memory"
              class="max-h-[32rem] overflow-y-auto text-sm"
            >
              <.message_text body={@agent_memory} />
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
                prompt="OpenCode default"
                options={provider_options(@providers, @form[:model_provider].value)}
              />
              <.input
                field={@form[:model_id]}
                type="select"
                label="Model (optional)"
                prompt={
                  if @form[:model_provider].value, do: "Pick a model", else: "Pick a provider first"
                }
                options={
                  model_options(@providers, @form[:model_provider].value, @form[:model_id].value)
                }
                disabled={is_nil(@form[:model_provider].value) or @form[:model_provider].value == ""}
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
            {form_price_line(@form, @providers, @default_models)}
          </p>
          <p class="text-xs text-base-content/60">
            <code class="font-mono">build</code>
            can edit files; <code class="font-mono">plan</code>
            is read-only, a good fit for advisory roles. Agents from your OpenCode config appear
            once a repository is registered and <code class="font-mono">opencode serve</code>
            is up.
            <%= if @providers != [] do %>
              Leave the model blank to use that agent's default.
            <% else %>
              Leave the model blank to use OpenCode's default.
            <% end %>
          </p>
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
end
