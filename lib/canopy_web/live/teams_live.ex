defmodule CanopyWeb.TeamsLive do
  @moduledoc """
  Teams, in three pages under one LiveView:

    * `/teams` — every team with its lead and members
    * `/teams/new` — the create form
    * `/teams/:id/edit` — the edit form

  A team is a named crew addressable as `@name`; unlike an agent's group, an
  agent can be on several teams. Every team has a lead, chosen among its
  members: the lead owns a channel created for the team. Only the user
  creates and edits teams.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Teams}
  alias Canopy.Teams.Team

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Teams.subscribe()

    {:ok,
     socket
     |> assign(:team, nil)
     |> assign(:member_ids, [])
     |> assign(:pickable, [])
     |> assign(:teams, Teams.list())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case {socket.assigns.live_action, params} do
      {:index, _} ->
        {:noreply, socket |> assign(:team, nil) |> assign(:page_title, "Teams")}

      {:new, _} ->
        {:noreply,
         socket
         |> assign(:team, nil)
         |> assign(:pickable, pickable(nil))
         |> assign(:page_title, "New team")
         |> assign_form(%Team{}, %{"agent_ids" => []})}

      {:edit, %{"id" => id}} ->
        case Teams.get(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That team no longer exists.")
             |> push_navigate(to: ~p"/teams")}

          team ->
            {:noreply,
             socket
             |> assign(:team, team)
             |> assign(:pickable, pickable(team))
             |> assign(:page_title, "Edit @" <> team.name)
             |> assign_form(team, %{"agent_ids" => Enum.map(team.members, & &1.id)})}
        end
    end
  end

  @impl true
  def handle_info({:teams, :changed}, socket),
    do: {:noreply, assign(socket, :teams, Teams.list())}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"team" => params}, socket) do
    team = socket.assigns.team
    {:noreply, assign_form(socket, team || %Team{}, with_lead(params, team), :validate)}
  end

  def handle_event("save", %{"team" => params}, socket) do
    editing = socket.assigns.team
    params = with_lead(params, editing)

    result = if editing, do: Teams.update(editing, params), else: Teams.create(params)

    case result do
      {:ok, team} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{if editing, do: "Updated", else: "Created"} @#{team.name}.")
         |> push_navigate(to: ~p"/teams")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:member_ids, member_ids(params))
         |> assign(:form, to_form(changeset, id: "team-form"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Teams.get(id) do
      nil ->
        {:noreply, socket}

      team ->
        {:ok, _} = Teams.delete(team)

        {:noreply,
         socket
         |> assign(:teams, Teams.list())
         |> put_flash(:info, "Deleted @#{team.name}. Channels keep the members it added.")}
    end
  end

  # The lead defaults to the first member, and on a new team follows the
  # members. On a saved team an unticked lead stays chosen, so the form says to
  # pick a new one rather than silently handing the team to someone else.
  defp with_lead(params, team) do
    members = member_ids(params)
    lead = params["lead_agent_id"]

    cond do
      members == [] -> params
      lead in [nil, ""] -> Map.put(params, "lead_agent_id", hd(members))
      is_nil(team) and lead not in members -> Map.put(params, "lead_agent_id", hd(members))
      true -> params
    end
  end

  defp member_ids(params) do
    params |> Map.get("agent_ids", []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp assign_form(socket, team, params, action \\ nil) do
    changeset = team |> Teams.change(params) |> Map.put(:action, action)

    socket
    |> assign(:member_ids, member_ids(params))
    |> assign(:form, to_form(changeset, id: "team-form"))
  end

  # Active agents, plus any inactive ones already on the team (greyed out).
  defp pickable(team) do
    inactive =
      if team, do: Enum.reject(team.members, & &1.active), else: []

    Agents.list_active() ++ inactive
  end

  defp lead_options(agents, member_ids, lead_id) do
    chosen = Enum.filter(agents, &(&1.id in member_ids))

    stale =
      case lead_id not in member_ids && Enum.find(agents, &(&1.id == lead_id)) do
        %{} = lead -> [{"@#{lead.name} (no longer a member)", lead.id}]
        _ -> []
      end

    Enum.map(chosen, &{"@#{&1.name} · #{&1.display_name}", &1.id}) ++ stale
  end

  defp member_errors(form) do
    if form.source.action != nil,
      do: Enum.map(form[:agent_ids].errors, &translate_error/1),
      else: []
  end

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
    >
      <%= if @live_action == :index do %>
        <.index_page {assigns} />
      <% else %>
        <.form_page {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp index_page(assigns) do
    ~H"""
    <Layouts.page
      title="Teams"
      subtitle="Crews of agents you can add to a channel and mention as one @name"
    >
      <:actions>
        <.link navigate={~p"/agents"} id="back-to-agents" class="btn btn-ghost btn-sm">
          Agents
        </.link>
        <.link navigate={~p"/teams/new"} id="new-team" class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> New team
        </.link>
      </:actions>

      <Layouts.empty_state
        :if={@teams == []}
        id="teams-empty"
        icon="hero-user-group"
        title="No teams yet"
      >
        A team brings several agents into a channel at once, and <code>@team</code>
        wakes all of its members there. <.link navigate={~p"/teams/new"} class="link link-primary">Create one</.link>.
      </Layouts.empty_state>

      <Layouts.panel
        :if={@teams != []}
        id="teams-panel"
        title="Teams"
        description="Adding a team copies its active members into the channel; later edits to the team leave existing channels alone."
      >
        <ul id="teams" class="divide-y divide-base-300">
          <li :for={team <- @teams} id={"team-#{team.id}"} class="flex flex-col gap-2 py-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-mono text-sm font-semibold">@{team.name}</span>
              <span :if={team.display_name != team.name} class="text-sm text-base-content/70">
                {team.display_name}
              </span>
              <div class="ml-auto flex items-center gap-1">
                <.link
                  navigate={~p"/channels/new?team=#{team.id}"}
                  id={"new-channel-team-#{team.id}"}
                  class="btn btn-ghost btn-xs"
                  title="New channel with only this team, owned by its lead"
                >
                  <.icon name="hero-hashtag-mini" class="size-3.5" /> New channel
                </.link>
                <.link
                  navigate={~p"/teams/#{team.id}/edit"}
                  id={"edit-team-#{team.id}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-pencil-square-mini" class="size-3.5" /> Edit
                </.link>
                <button
                  type="button"
                  id={"delete-team-#{team.id}"}
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete"
                  phx-value-id={team.id}
                  data-canopy-confirm="Channels keep the members it added; @mentions of it stop working."
                  data-canopy-confirm-title={"Delete @#{team.name}?"}
                  data-canopy-confirm-label="Delete"
                  title="Delete"
                >
                  <.icon name="hero-trash-mini" class="size-3.5" />
                </button>
              </div>
            </div>
            <p :if={team.description} class="text-xs text-base-content/70">{team.description}</p>
            <div class="flex flex-wrap items-center gap-1.5">
              <.member_pill
                :for={member <- team.members}
                agent={member}
                lead?={member.id == team.lead_agent_id}
              />
            </div>
          </li>
        </ul>
      </Layouts.panel>
    </Layouts.page>
    """
  end

  attr :agent, :map, required: true
  attr :lead?, :boolean, default: false

  @doc false
  def member_pill(assigns) do
    ~H"""
    <span
      class={[
        "flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs",
        @agent.active && "border-base-300 bg-base-100",
        !@agent.active && "border-dashed border-base-300 text-base-content/40"
      ]}
      title={if @agent.active, do: @agent.role, else: "Inactive: skipped when the team is used"}
    >
      <span class="font-mono">@{@agent.name}</span>
      <span
        :if={@lead?}
        class="rounded-full bg-primary/10 px-1.5 text-[10px] font-medium uppercase tracking-wide text-primary"
      >
        lead
      </span>
    </span>
    """
  end

  defp form_page(assigns) do
    ~H"""
    <Layouts.page
      title={if @team, do: "Edit @#{@team.name}", else: "New team"}
      subtitle="A crew that crosses groups, addressable as @name"
    >
      <:actions>
        <.link navigate={~p"/teams"} id="cancel-team" class="btn btn-ghost btn-sm">Cancel</.link>
      </:actions>

      <Layouts.panel
        id="team-form-panel"
        title={if @team, do: "Team", else: "Details"}
        description="@name shares the namespace with agents, so it can't be an agent's name."
      >
        <.form
          for={@form}
          id="team-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col gap-3"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:name]}
              type="text"
              label="Name (slug, used as @name)"
              placeholder="bugfix-team"
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:display_name]}
              type="text"
              label="Display name"
              placeholder="Bugfix team"
              autocomplete="off"
            />
          </div>
          <.input
            field={@form[:description]}
            type="text"
            label="Description (agents see it)"
            placeholder="Reproduces, fixes, tests, and reviews bugs"
            autocomplete="off"
          />

          <fieldset class="fieldset mb-2">
            <span class="label mb-1">Members</span>
            <input type="hidden" name="team[agent_ids][]" value="" />
            <ul id="team-members" class="grid gap-1 sm:grid-cols-2">
              <%= for {group, agents} <- Agents.grouped(@pickable) do %>
                <li
                  :if={group}
                  class="pt-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/60 sm:col-span-2"
                >
                  {group}
                </li>
                <li :for={agent <- agents}>
                  <label
                    for={"team-member-#{agent.id}"}
                    class={[
                      "flex cursor-pointer items-center gap-2 rounded-lg border px-3 py-2 text-sm transition",
                      agent.id in @member_ids && "border-primary/40 bg-primary/5",
                      agent.id not in @member_ids && "border-base-300 hover:bg-base-100",
                      !agent.active && "opacity-60"
                    ]}
                  >
                    <input
                      type="checkbox"
                      id={"team-member-#{agent.id}"}
                      name="team[agent_ids][]"
                      value={agent.id}
                      checked={agent.id in @member_ids}
                      class="checkbox checkbox-sm"
                    />
                    <span class="font-mono text-xs">@{agent.name}</span>
                    <span class="truncate text-base-content/60">
                      {if agent.active, do: agent.role, else: "inactive"}
                    </span>
                  </label>
                </li>
              <% end %>
            </ul>
            <p
              :for={msg <- member_errors(@form)}
              class="mt-1.5 flex items-center gap-2 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" />
              {msg}
            </p>
          </fieldset>

          <.input
            field={@form[:lead_agent_id]}
            type="select"
            id="team-lead"
            label="Lead (owns a channel created for the team)"
            prompt={if @member_ids == [], do: "Pick members first"}
            options={lead_options(@pickable, @member_ids, @form[:lead_agent_id].value)}
          />

          <div class="flex items-center gap-2 pt-1">
            <.button type="submit" variant="primary" id="save-team">
              {if @team, do: "Save team", else: "Create team"}
            </.button>
            <.link navigate={~p"/teams"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </Layouts.panel>
    </Layouts.page>
    """
  end
end
