defmodule CanopyWeb.AgentsLive do
  @moduledoc """
  Agents: list active agents with their role and model, create or edit one
  (name, display name, role, system prompt, OpenCode agent, model override),
  deactivate, and reactivate.

  The OpenCode agent picker is a datalist filled from `GET /agent` for the
  first repository; without a repository (or if the call fails) it is a plain
  text input defaulting to `build`.
  """
  use CanopyWeb, :live_view

  alias Canopy.Agents
  alias Canopy.Agents.Agent
  alias Canopy.OpenCode.Client
  alias Canopy.Repositories
  alias CanopyWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:opencode_agents, [])
      |> assign(:show_inactive, false)
      |> start_new()
      |> load_agents()

    socket =
      if connected?(socket) do
        fetch_opencode_agents(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, start_new(socket)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    agent = Agents.get!(id)

    {:noreply,
     socket
     |> assign(:editing, agent)
     |> assign_form(Agents.change(agent))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, start_new(socket)}
  end

  def handle_event("validate", %{"agent" => params}, socket) do
    changeset =
      socket.assigns.editing
      |> Agents.change(blank_to_nil(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"agent" => params}, socket) do
    params = blank_to_nil(params)
    editing = socket.assigns.editing

    result =
      if editing.id,
        do: Agents.update(editing, params),
        else: Agents.create(params)

    case result do
      {:ok, agent} ->
        verb = if editing.id, do: "Updated", else: "Created"

        {:noreply,
         socket
         |> start_new()
         |> load_agents()
         |> Nav.refresh_nav()
         |> put_flash(:info, "#{verb} @#{agent.name}.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    agent = Agents.get!(id)

    case Agents.deactivate(agent) do
      {:ok, _} ->
        socket =
          if socket.assigns.editing.id == agent.id, do: start_new(socket), else: socket

        {:noreply,
         socket
         |> load_agents()
         |> Nav.refresh_nav()
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
         |> load_agents()
         |> Nav.refresh_nav()
         |> put_flash(:info, "Reactivated @#{agent.name}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reactivate @#{agent.name}.")}
    end
  end

  def handle_event("toggle_inactive", _params, socket) do
    {:noreply, update(socket, :show_inactive, &(!&1))}
  end

  @impl true
  def handle_async(:opencode_agents, {:ok, {:ok, list}}, socket) when is_list(list) do
    names =
      list
      |> Enum.map(fn
        %{"name" => name} when is_binary(name) -> name
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    {:noreply, assign(socket, :opencode_agents, names)}
  end

  def handle_async(:opencode_agents, _other, socket) do
    {:noreply, assign(socket, :opencode_agents, [])}
  end

  defp fetch_opencode_agents(socket) do
    case Repositories.list() do
      [%{path: dir} | _] ->
        start_async(socket, :opencode_agents, fn -> Client.impl().agents(dir, []) end)

      [] ->
        socket
    end
  end

  defp start_new(socket) do
    agent = %Agent{}

    socket
    |> assign(:editing, agent)
    |> assign_form(Agents.change(agent))
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, id: "agent-form"))
  end

  defp load_agents(socket) do
    {active, inactive} = Agents.list() |> Enum.split_with(& &1.active)

    socket
    |> assign(:active_agents, active)
    |> assign(:inactive_agents, inactive)
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      repositories={@repositories}
      agents={@agents}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
    >
      <Layouts.page
        title="Agents"
        subtitle="Named coworkers backed by OpenCode agents and a role prompt"
        max_width="max-w-6xl"
      >
        <div class="grid gap-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
          <div class="flex flex-col gap-6">
            <Layouts.panel
              id="agents-panel"
              title="Active agents"
              description="Mention an agent with @name in a channel to wake it."
            >
              <:actions>
                <button
                  type="button"
                  id="new-agent"
                  class={[
                    "btn btn-sm",
                    if(@editing.id, do: "btn-soft btn-primary", else: "btn-ghost")
                  ]}
                  phx-click="new"
                >
                  <.icon name="hero-plus" class="size-4" /> New agent
                </button>
              </:actions>

              <Layouts.empty_state
                :if={@active_agents == []}
                id="agents-empty"
                icon="hero-cpu-chip"
                title="No agents yet"
              >
                Create one with the form. A good first pair is a builder and a reviewer.
              </Layouts.empty_state>

              <ul :if={@active_agents != []} id="active-agents" class="divide-y divide-base-300">
                <li
                  :for={agent <- @active_agents}
                  id={"agent-#{agent.id}"}
                  class={[
                    "group -mx-2 flex items-start gap-3 rounded-lg px-2 py-3 transition",
                    @editing.id == agent.id && "bg-primary/5 ring-1 ring-primary/30"
                  ]}
                >
                  <div class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 font-mono text-sm font-semibold text-base-content/70">
                    {String.first(agent.name) |> String.upcase()}
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                      <span class="text-sm font-semibold">{agent.display_name}</span>
                      <span class="font-mono text-xs text-base-content/60">@{agent.name}</span>
                      <span class="badge badge-ghost badge-sm font-mono" title="OpenCode agent">
                        {agent.opencode_agent}
                      </span>
                      <span
                        :if={model_label(agent)}
                        class="badge badge-soft badge-primary badge-sm font-mono"
                        title="Model override"
                      >
                        {model_label(agent)}
                      </span>
                    </div>
                    <p :if={agent.role} class="mt-0.5 truncate text-xs text-base-content/70">
                      {agent.role}
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-1 opacity-60 transition group-hover:opacity-100">
                    <button
                      type="button"
                      id={"edit-agent-#{agent.id}"}
                      class="btn btn-ghost btn-xs"
                      phx-click="edit"
                      phx-value-id={agent.id}
                    >
                      <.icon name="hero-pencil-square" class="size-4" /> Edit
                    </button>
                    <button
                      type="button"
                      id={"deactivate-agent-#{agent.id}"}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="deactivate"
                      phx-value-id={agent.id}
                      data-confirm={"Deactivate @#{agent.name}? It stops appearing in channels and mentions, but its history is kept."}
                      title="Deactivate"
                    >
                      <.icon name="hero-power" class="size-4" />
                    </button>
                  </div>
                </li>
              </ul>

              <div :if={@inactive_agents != []} class="mt-4 border-t border-base-300 pt-3">
                <button
                  type="button"
                  id="toggle-inactive"
                  class="flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content"
                  phx-click="toggle_inactive"
                >
                  <.icon
                    name={
                      if @show_inactive, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"
                    }
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
                    <span class="font-mono text-xs">@{agent.name}</span>
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
          </div>

          <Layouts.panel
            id="agent-form-panel"
            title={if @editing.id, do: "Edit @#{@editing.name}", else: "New agent"}
            description="The role and system prompt are sent with every prompt; OpenCode's own agent prompt still applies."
          >
            <:actions>
              <button
                :if={@editing.id}
                type="button"
                id="cancel-edit"
                class="btn btn-ghost btn-sm"
                phx-click="cancel"
              >
                Cancel
              </button>
            </:actions>

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
              <.input
                field={@form[:role]}
                type="text"
                label="Role (one line)"
                placeholder="Owns the Phoenix backend and its tests"
                autocomplete="off"
              />
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
                  type="text"
                  label="OpenCode agent"
                  placeholder="build"
                  list={if @opencode_agents != [], do: "opencode-agents"}
                  autocomplete="off"
                  spellcheck="false"
                />
                <.input
                  field={@form[:model_provider]}
                  type="text"
                  label="Model provider (optional)"
                  placeholder="anthropic"
                  autocomplete="off"
                  spellcheck="false"
                />
                <.input
                  field={@form[:model_id]}
                  type="text"
                  label="Model id (optional)"
                  placeholder="claude-sonnet-4"
                  autocomplete="off"
                  spellcheck="false"
                />
              </div>
              <datalist :if={@opencode_agents != []} id="opencode-agents">
                <option :for={name <- @opencode_agents} value={name} />
              </datalist>
              <p class="text-xs text-base-content/60">
                <%= if @opencode_agents != [] do %>
                  Suggestions come from your OpenCode server. Leave the model blank to use that agent's default.
                <% else %>
                  Add a repository and start <code class="font-mono">opencode serve</code>
                  to get agent name suggestions. Leave the model blank to use OpenCode's default.
                <% end %>
              </p>
              <div class="flex items-center gap-2 pt-1">
                <.button type="submit" variant="primary" id="save-agent">
                  {if @editing.id, do: "Save changes", else: "Create agent"}
                </.button>
              </div>
            </.form>
          </Layouts.panel>
        </div>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
