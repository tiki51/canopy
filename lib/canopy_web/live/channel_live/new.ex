defmodule CanopyWeb.ChannelLive.New do
  @moduledoc """
  New channel: pick a repository, name the channel, set a topic, choose the
  member agents (all active agents preselected), and pick the initial owner
  among the chosen members. On success the channel, its task, and its
  memberships are created in one transaction and the user lands in the channel.
  """
  use CanopyWeb, :live_view

  alias Canopy.Channels
  alias Canopy.Channels.Channel
  alias CanopyWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "New channel")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    member_ids = Enum.map(socket.assigns.agents, & &1.id)
    repository_id = preselected_repository(params["repository_id"], socket.assigns.repositories)

    attrs = %{
      "repository_id" => repository_id,
      "owner_agent_id" => List.first(member_ids)
    }

    {:noreply,
     socket
     |> assign(:member_ids, member_ids)
     |> assign_form(build_changeset(attrs, member_ids))}
  end

  @impl true
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
      |> Map.take(["repository_id", "name", "topic", "owner_agent_id"])
      |> blank_to_nil()

    %Channel{}
    |> Channels.change(params)
    |> Ecto.Changeset.validate_required([:owner_agent_id], message: "pick an owner")
    |> validate_members(member_ids)
  end

  defp validate_members(changeset, []) do
    Ecto.Changeset.add_error(changeset, :agent_ids, "pick at least one agent")
  end

  defp validate_members(changeset, _member_ids), do: changeset

  defp create_attrs(params) do
    params
    |> Map.take(["repository_id", "name", "topic", "owner_agent_id"])
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
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
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
          description="The owner is woken for every message; other members join when mentioned or delegated to."
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

            <fieldset class="fieldset mb-2">
              <span class="label mb-1">Members</span>
              <ul id="channel-members" class="grid gap-1 sm:grid-cols-2">
                <li :for={agent <- @agents}>
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
