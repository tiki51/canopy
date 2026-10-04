defmodule CanopyWeb.ChannelLive.New do
  @moduledoc """
  New channel: pick a repository, name the channel, set a topic (and, behind
  "Add a brief", the channel's standing context), choose the
  member agents (all active agents preselected), and pick the initial owner
  among the chosen members. On success the channel, its task, and its
  memberships are created in one transaction and the user lands in the channel.

  Team chips and group headings tick (or clear) all their active agents at
  once. `?team=<id>` (the Teams page's "New channel") starts with only that
  team's members, its lead as owner.
  """
  use CanopyWeb, :live_view

  alias Canopy.{Channels, Teams}
  alias Canopy.Channels.Channel
  alias CanopyWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "New channel")
     |> assign(:teams, Teams.list())
     |> assign(:brief_open?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    team = params["team"] && Teams.get(params["team"])

    member_ids =
      if team,
        do: team_member_ids(team, socket.assigns.agents),
        else: Enum.map(socket.assigns.agents, & &1.id)

    repository_id = preselected_repository(params["repository_id"], socket.assigns.repositories)

    owner =
      if team && team.lead_agent_id in member_ids,
        do: team.lead_agent_id,
        else: List.first(member_ids)

    attrs = %{
      "repository_id" => repository_id,
      "owner_agent_id" => owner
    }

    {:noreply,
     socket
     |> assign(:member_ids, member_ids)
     |> assign_form(build_changeset(attrs, member_ids))}
  end

  # The brief field stays out of the way until asked for.
  @impl true
  def handle_event("add_brief", _params, socket),
    do: {:noreply, assign(socket, :brief_open?, true)}

  # "Select all" / "Clear all" above the members grid.
  def handle_event("toggle_all_members", _params, socket),
    do: {:noreply, toggle_members(socket, Enum.map(socket.assigns.agents, & &1.id))}

  # A team chip or a group heading: ticks all its active agents, or clears
  # them when they are all ticked already.
  def handle_event("toggle_team", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.teams, &(&1.id == id)) do
      nil -> {:noreply, socket}
      team -> {:noreply, toggle_members(socket, team_member_ids(team, socket.assigns.agents))}
    end
  end

  def handle_event("toggle_group", %{"group" => group}, socket) do
    ids = for agent <- socket.assigns.agents, agent.group == group, do: agent.id
    {:noreply, toggle_members(socket, ids)}
  end

  def handle_event("validate", %{"channel" => params}, socket) do
    member_ids = members_from(params, socket.assigns.agents)
    params = ensure_owner(params, member_ids)

    changeset =
      params
      |> build_changeset(member_ids)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:member_ids, member_ids)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    member_ids = members_from(params, socket.assigns.agents)
    params = ensure_owner(params, member_ids)
    changeset = build_changeset(params, member_ids)

    with true <- changeset.valid?,
         {:ok, channel} <- Channels.create(Map.put(create_attrs(params), :agent_ids, member_ids)) do
      {:noreply,
       socket
       |> Nav.refresh_nav()
       |> put_flash(:info, "Created ##{channel.name}.")
       |> push_navigate(to: ~p"/channels/#{channel.id}")}
    else
      false ->
        {:noreply,
         socket
         |> assign(:member_ids, member_ids)
         |> assign_form(Map.put(changeset, :action, :insert))}

      {:error, %Ecto.Changeset{data: %Channel{}} = changeset} ->
        {:noreply,
         socket
         |> assign(:member_ids, member_ids)
         |> assign_form(changeset)}

      {:error, _other} ->
        {:noreply,
         socket
         |> assign(:member_ids, member_ids)
         |> put_flash(
           :error,
           "Could not create the channel. Check that the chosen agents still exist."
         )}
    end
  end

  # Ticks every id in `ids`, or clears them all when every one is ticked. The
  # rest of the form keeps what was typed; the owner follows the membership as
  # it does when a box is unchecked by hand.
  defp toggle_members(socket, []), do: socket

  defp toggle_members(socket, ids) do
    current = socket.assigns.member_ids

    member_ids =
      if Enum.all?(ids, &(&1 in current)),
        do: current -- ids,
        else: Enum.filter(Enum.map(socket.assigns.agents, & &1.id), &(&1 in current or &1 in ids))

    params =
      socket.assigns.form.source.params
      |> Map.put("agent_ids", member_ids)
      |> ensure_owner(member_ids)

    changeset =
      params
      |> build_changeset(member_ids)
      |> Map.put(:action, socket.assigns.form.source.action)

    socket
    |> assign(:member_ids, member_ids)
    |> assign_form(changeset)
  end

  # The team's members among the active agents, in the agents' order.
  defp team_member_ids(team, agents) do
    ids = MapSet.new(Teams.active_members(team), & &1.id)
    for agent <- agents, MapSet.member?(ids, agent.id), do: agent.id
  end

  defp all_ticked?(ids, member_ids), do: ids != [] and Enum.all?(ids, &(&1 in member_ids))

  # Only ids of currently active agents count as members, whatever the client sent.
  defp members_from(params, agents) do
    known = MapSet.new(agents, & &1.id)

    params
    |> Map.get("agent_ids", [])
    |> List.wrap()
    |> Enum.filter(&MapSet.member?(known, &1))
  end

  # The owner must be a member: drop an owner that was unchecked, and default
  # to the first member when nothing is chosen.
  defp ensure_owner(params, member_ids) do
    owner = params["owner_agent_id"]

    cond do
      owner in member_ids -> params
      member_ids == [] -> Map.put(params, "owner_agent_id", nil)
      true -> Map.put(params, "owner_agent_id", List.first(member_ids))
    end
  end

  defp build_changeset(params, member_ids) do
    params =
      params
      |> Map.take(["repository_id", "name", "topic", "brief", "owner_agent_id", "spend_limit"])
      |> blank_to_nil()

    %Channel{}
    |> Channels.change(params)
    |> Channel.brief_changeset(%{"brief" => params["brief"] || ""})
    |> Ecto.Changeset.validate_required([:owner_agent_id], message: "pick an owner")
    |> validate_members(member_ids)
  end

  defp validate_members(changeset, []) do
    Ecto.Changeset.add_error(changeset, :agent_ids, "pick at least one agent")
  end

  defp validate_members(changeset, _member_ids), do: changeset

  defp create_attrs(params) do
    params
    |> Map.take(["repository_id", "name", "topic", "brief", "owner_agent_id", "spend_limit"])
    |> blank_to_nil()
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

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

  defp preselected_repository(id, repositories) when is_binary(id) do
    if Enum.any?(repositories, &(&1.id == id)),
      do: id,
      else: preselected_repository(nil, repositories)
  end

  defp preselected_repository(_id, [first | _]), do: first.id
  defp preselected_repository(_id, []), do: nil

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, id: "channel-form"))
  end

  defp repository_options(repositories) do
    Enum.map(repositories, &{&1.name, &1.id})
  end

  defp owner_options(agents, member_ids) do
    agents
    |> Enum.filter(&(&1.id in member_ids))
    |> Enum.map(&{"@#{&1.name} · #{&1.display_name}", &1.id})
  end

  defp member_errors(form) do
    if Phoenix.Component.used_input?(form[:agent_ids]) or form.source.action != nil,
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
      palette={@palette}
      setup={@setup}
      socket={@socket}
    >
      <Layouts.page title="New channel" subtitle="A focused room for one task in one repository">
        <Layouts.empty_state
          :if={@repositories == []}
          id="new-channel-no-repositories"
          icon="hero-folder-open"
          title="Add a repository first"
        >
          Channels live inside a repository.
          <.link navigate={~p"/repositories"} class="link link-primary">Register one</.link>
          and come back.
        </Layouts.empty_state>

        <Layouts.empty_state
          :if={@repositories != [] and @agents == []}
          id="new-channel-no-agents"
          icon="hero-cpu-chip"
          title="Create an agent first"
        >
          A channel needs at least one agent to own it.
          <.link navigate={~p"/agents"} class="link link-primary">Create one</.link>
          and come back.
        </Layouts.empty_state>

        <Layouts.panel
          :if={@repositories != [] and @agents != []}
          id="new-channel-panel"
          title="Channel"
          description="The owner is woken for every message; other members join when mentioned or delegated to. Teams add all their members at once."
        >
          <.form
            for={@form}
            id="channel-form"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-3"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:repository_id]}
                type="select"
                label="Repository"
                options={repository_options(@repositories)}
              />
              <.input
                field={@form[:name]}
                type="text"
                label="Name (slug, shown as #name)"
                placeholder="retry-logic"
                autocomplete="off"
                spellcheck="false"
              />
            </div>
            <.input
              field={@form[:topic]}
              type="text"
              label="Topic"
              placeholder="Make the HTTP client retry idempotent requests"
              autocomplete="off"
            />
            <%= if @brief_open? or (@form[:brief].value || "") != "" do %>
              <.input
                field={@form[:brief]}
                type="textarea"
                rows="4"
                label="Brief (standing context every agent here gets in its instructions)"
                placeholder="Goal: …\nConstraints:\n- Don't touch …"
                class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
              />
            <% else %>
              <div>
                <button
                  type="button"
                  id="add-brief"
                  class="btn btn-ghost btn-xs gap-1"
                  phx-click="add_brief"
                >
                  <.icon name="hero-document-text-mini" class="size-4" /> Add a brief
                </button>
              </div>
            <% end %>

            <fieldset class="fieldset mb-2">
              <div class="mb-1 flex items-center justify-between">
                <span class="label">Members</span>
                <button
                  type="button"
                  id="toggle-all-members"
                  class="btn btn-ghost btn-xs"
                  phx-click="toggle_all_members"
                >
                  {if length(@member_ids) == length(@agents), do: "Clear all", else: "Select all"}
                </button>
              </div>
              <div
                :if={@teams != []}
                id="channel-teams"
                class="mb-2 flex flex-wrap items-center gap-1.5"
              >
                <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/60">
                  Teams
                </span>
                <button
                  :for={team <- @teams}
                  :if={team_member_ids(team, @agents) != []}
                  type="button"
                  id={"team-chip-#{team.id}"}
                  phx-click="toggle_team"
                  phx-value-id={team.id}
                  aria-pressed={to_string(all_ticked?(team_member_ids(team, @agents), @member_ids))}
                  title={"@#{team.name}: " <> Enum.map_join(Teams.active_members(team), ", ", &("@" <> &1.name))}
                  class={[
                    "flex items-center gap-1 rounded-full border px-2.5 py-0.5 text-xs transition",
                    if(all_ticked?(team_member_ids(team, @agents), @member_ids),
                      do: "border-primary/40 bg-primary/10 text-primary",
                      else: "border-base-300 hover:bg-base-200"
                    )
                  ]}
                >
                  <.icon name="hero-user-group-mini" class="size-3.5" />
                  <span class="font-mono">@{team.name}</span>
                  <span class="text-base-content/50">{length(team_member_ids(team, @agents))}</span>
                </button>
              </div>
              <ul id="channel-members" class="grid gap-1 sm:grid-cols-2">
                <%= for {group, agents} <- Canopy.Agents.grouped(@agents) do %>
                  <li :if={group} class="pt-2 sm:col-span-2">
                    <button
                      type="button"
                      id={"group-toggle-#{Layouts.group_slug(group)}"}
                      phx-click="toggle_group"
                      phx-value-group={group}
                      title={"Select or clear everyone in #{group}"}
                      class="text-[11px] font-semibold uppercase tracking-wider text-base-content/60 transition hover:text-primary"
                    >
                      {group}
                    </button>
                  </li>
                  <li :for={agent <- agents}>
                    <label
                      for={"member-#{agent.id}"}
                      class={[
                        "flex cursor-pointer items-center gap-2 rounded-lg border px-3 py-2 text-sm transition",
                        agent.id in @member_ids && "border-primary/40 bg-primary/5",
                        agent.id not in @member_ids && "border-base-300 hover:bg-base-200"
                      ]}
                    >
                      <input
                        type="checkbox"
                        id={"member-#{agent.id}"}
                        name="channel[agent_ids][]"
                        value={agent.id}
                        checked={agent.id in @member_ids}
                        class="checkbox checkbox-sm"
                      />
                      <span class="font-mono text-xs">@{agent.name}</span>
                      <span class="truncate text-base-content/60">{agent.role}</span>
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
              field={@form[:owner_agent_id]}
              type="select"
              label="Initial owner"
              prompt={if @member_ids == [], do: "Pick members first"}
              options={owner_options(@agents, @member_ids)}
            />

            <.input
              field={@form[:spend_limit]}
              type="number"
              label="Spend limit in dollars (optional)"
              placeholder="No limit"
              min="0.01"
              step="0.01"
            />
            <p class="-mt-1 text-xs text-base-content/60">
              The total this channel may spend. Once reached, agents here stay quiet until you raise
              it. Only you can change it later.
            </p>

            <div class="flex items-center gap-2 pt-1">
              <.button type="submit" variant="primary" id="create-channel">
                <.icon name="hero-plus" class="size-4" /> Create channel
              </.button>
              <.link navigate={~p"/"} class="btn btn-ghost">Cancel</.link>
            </div>
          </.form>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
