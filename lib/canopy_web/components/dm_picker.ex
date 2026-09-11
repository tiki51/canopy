defmodule CanopyWeb.DmPicker do
  @moduledoc """
  The "new direct message" modal, rendered by the shell on every page. Pick
  one or more agents (and a repository when there are several); Canopy finds
  the DM with exactly that set of agents, creating it on first use, and
  navigates there.

  A live component rendered at the shell level (outside the sliding sidebar,
  whose transform would otherwise trap a fixed-position overlay), opened by
  the sidebar's `+` with `phx-target="#dm-picker-component"`.
  """

  use CanopyWeb, :live_component

  alias Canopy.Channels

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(:open?, false) |> assign(:agent_ids, []) |> assign(:error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    repository_id =
      socket.assigns[:repository_id] ||
        preselected(assigns[:current_repository_id], assigns.repositories)

    {:ok, assign(socket, :repository_id, repository_id)}
  end

  @impl true
  def handle_event("open_picker", _params, socket) do
    {:noreply,
     socket
     |> assign(:open?, true)
     |> assign(:agent_ids, [])
     |> assign(:error, nil)
     |> assign(
       :repository_id,
       preselected(socket.assigns.current_repository_id, socket.assigns.repositories)
     )}
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, assign(socket, :open?, false)}

  def handle_event("change", params, socket) do
    {:noreply,
     socket
     |> assign(:repository_id, preselected(params["repository_id"], socket.assigns.repositories))
     |> assign(:agent_ids, Map.get(params, "agent_ids", []))
     |> assign(:error, nil)}
  end

  def handle_event("open_dm", params, socket) do
    repository_id = preselected(params["repository_id"], socket.assigns.repositories)
    ids = Map.get(params, "agent_ids", [])
    agents = Enum.filter(socket.assigns.agents, &(&1.id in ids))

    cond do
      is_nil(repository_id) ->
        {:noreply, assign(socket, :error, "Add a repository first.")}

      agents == [] ->
        {:noreply,
         socket |> assign(:agent_ids, ids) |> assign(:error, "Pick at least one agent.")}

      true ->
        case Channels.ensure_dm(repository_id, agents) do
          {:ok, dm} ->
            {:noreply,
             socket |> assign(:open?, false) |> push_navigate(to: ~p"/channels/#{dm.id}")}

          {:error, _changeset} ->
            {:noreply, assign(socket, :error, "Could not open that direct message.")}
        end
    end
  end

  defp preselected(id, repositories) when is_binary(id) do
    if Enum.any?(repositories, &(&1.id == id)), do: id, else: preselected(nil, repositories)
  end

  defp preselected(_id, [first | _]), do: first.id
  defp preselected(_id, []), do: nil

  defp label(agent_ids, agents) do
    agents
    |> Enum.filter(&(&1.id in agent_ids))
    |> Enum.map_join(", ", &("@" <> &1.name))
  end

  attr :id, :string, required: true
  attr :repositories, :list, required: true
  attr :agents, :list, required: true
  attr :current_repository_id, :string, default: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open?}
        id="dm-picker"
        class="fixed inset-0 z-50 flex items-center justify-center bg-base-content/40 p-4"
        phx-window-keydown="close_picker"
        phx-key="Escape"
        phx-target={@myself}
      >
        <div
          id="dm-picker-dialog"
          class="w-full max-w-lg overflow-hidden rounded-2xl border border-base-300 bg-base-200 shadow-2xl"
          phx-click-away="close_picker"
          phx-target={@myself}
        >
          <div class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-3">
            <div>
              <h2 class="text-sm font-semibold">New direct message</h2>
              <p class="mt-0.5 text-xs text-base-content/60">
                You and one or more agents. The same set always opens the same conversation.
              </p>
            </div>
            <button
              type="button"
              id="close-dm-picker"
              class="btn btn-ghost btn-xs btn-square"
              phx-click="close_picker"
              phx-target={@myself}
              aria-label="Close"
            >
              <.icon name="hero-x-mark-mini" class="size-4" />
            </button>
          </div>

          <div :if={@repositories == []} id="dm-picker-no-repository" class="px-5 py-4 text-sm">
            Agents work inside a repository, so a DM needs one too.
            <.link navigate={~p"/repositories"} class="link link-primary">Register one</.link>
            first.
          </div>
          <div
            :if={@repositories != [] and @agents == []}
            id="dm-picker-no-agents"
            class="px-5 py-4 text-sm"
          >
            No agents yet.
            <.link navigate={~p"/agents/new"} class="link link-primary">Create one</.link>
            first.
          </div>

          <form
            :if={@repositories != [] and @agents != []}
            id="dm-form"
            phx-change="change"
            phx-submit="open_dm"
            phx-target={@myself}
            class="flex flex-col gap-4 px-5 py-4"
          >
            <div :if={length(@repositories) > 1} class="fieldset mb-0">
              <label for="dm-repository">
                <span class="label mb-1">Repository</span>
                <select id="dm-repository" name="repository_id" class="w-full select select-sm">
                  <option
                    :for={repository <- @repositories}
                    value={repository.id}
                    selected={repository.id == @repository_id}
                  >
                    {repository.name}
                  </option>
                </select>
              </label>
            </div>
            <input
              :if={length(@repositories) == 1}
              type="hidden"
              name="repository_id"
              value={@repository_id}
            />

            <fieldset class="fieldset mb-0">
              <span class="label mb-1">Agents</span>
              <ul id="dm-agents" class="grid max-h-72 gap-1 overflow-y-auto sm:grid-cols-2">
                <li :for={agent <- @agents}>
                  <label
                    for={"dm-agent-#{agent.id}"}
                    class={[
                      "flex cursor-pointer items-center gap-2 rounded-lg border px-3 py-2 text-sm transition",
                      agent.id in @agent_ids && "border-primary/40 bg-primary/5",
                      agent.id not in @agent_ids && "border-base-300 hover:bg-base-100"
                    ]}
                  >
                    <input
                      type="checkbox"
                      id={"dm-agent-#{agent.id}"}
                      name="agent_ids[]"
                      value={agent.id}
                      checked={agent.id in @agent_ids}
                      class="checkbox checkbox-sm"
                    />
                    <span class="font-mono text-xs">@{agent.name}</span>
                    <span class="truncate text-base-content/60">{agent.role}</span>
                  </label>
                </li>
              </ul>
              <p class="mt-1.5 text-[11px] text-base-content/50">
                A plain message in a DM wakes every agent in it; mention one to address it alone.
              </p>
            </fieldset>

            <p :if={@error} id="dm-error" class="flex items-center gap-2 text-sm text-error">
              <.icon name="hero-exclamation-circle" class="size-5" /> {@error}
            </p>

            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="close_picker"
                phx-target={@myself}
              >
                Cancel
              </button>
              <.button type="submit" variant="primary" id="open-dm" disabled={@agent_ids == []}>
                <.icon name="hero-chat-bubble-left-right" class="size-4" />
                {if @agent_ids == [], do: "Open", else: "Open DM with " <> label(@agent_ids, @agents)}
              </.button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
