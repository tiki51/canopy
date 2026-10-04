defmodule CanopyWeb.AgentGalleryLive do
  @moduledoc """
  `/agents/gallery`: the starter agents and bundles Canopy ships
  (`Canopy.Templates.Gallery`), as cards grouped like the sidebar. A card
  whose name is free offers Add; one already here says Added, or Differs
  with Compare when its role, prompt or mode was changed. Add and Compare go
  through the import preview (`CanopyWeb.AgentImportLive`), so a gallery
  agent fits this machine's engine and default model like any import.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Teams}
  alias Canopy.Templates.Gallery

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Teams.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Agent gallery")
     |> assign(:bundles, Gallery.bundles())
     |> load()}
  end

  @impl true
  def handle_info({:teams, :changed}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    here = Map.new(Agents.list(), &{&1.name, &1})

    cards =
      for %{name: name, template: template} <- Gallery.agents() do
        status =
          case Map.get(here, name) do
            nil -> :new
            agent -> Gallery.compare(template, agent)
          end

        %{name: name, template: template, status: status}
      end

    assign(socket, :groups, group(cards))
  end

  defp group(cards) do
    cards
    |> Enum.group_by(& &1.template.group)
    |> Enum.sort_by(fn {group, _} -> {is_nil(group), group && String.downcase(group)} end)
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
      <Layouts.page
        title="Agent gallery"
        subtitle="Starter agents and teams to add; each follows this machine's engine and default model"
        max_width="max-w-none"
      >
        <:actions>
          <.link navigate={~p"/agents"} id="gallery-back" class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left-mini" class="size-4" /> All agents
          </.link>
          <.link navigate={~p"/agents/import"} id="gallery-import" class="btn btn-sm">
            <.icon name="hero-arrow-up-tray" class="size-4" /> Import a file
          </.link>
        </:actions>

        <Layouts.panel
          :if={@bundles != []}
          id="gallery-bundles"
          title="Teams and playbooks"
          description="A team with its agents and playbooks, ready to add together."
        >
          <ul class="grid gap-3 md:grid-cols-2">
            <li
              :for={bundle <- @bundles}
              id={"gallery-bundle-#{bundle.name}"}
              class="flex flex-col gap-2 rounded-xl border border-base-300 p-4"
            >
              <div class="flex items-center gap-2">
                <.icon name="hero-user-group" class="size-4 text-base-content/60" />
                <span class="text-sm font-semibold">{bundle.title}</span>
              </div>
              <p :if={bundle.description} class="text-xs text-base-content/70">
                {bundle.description}
              </p>
              <p class="font-mono text-[11px] text-base-content/50">
                {bundle.files
                |> Enum.map(&elem(&1, 0))
                |> Enum.reject(&(&1 == "canopy.md"))
                |> Enum.join(" · ")}
              </p>
              <div>
                <.link
                  navigate={~p"/agents/import?bundle=#{bundle.name}"}
                  id={"gallery-add-bundle-#{bundle.name}"}
                  class="btn btn-sm"
                >
                  <.icon name="hero-plus-mini" class="size-4" /> Add
                </.link>
              </div>
            </li>
          </ul>
        </Layouts.panel>

        <Layouts.panel
          :for={{group, cards} <- @groups}
          id={"gallery-group-#{Layouts.group_slug(group || "other")}"}
          title={group || "Other"}
        >
          <ul class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            <li
              :for={card <- cards}
              id={"gallery-#{card.name}"}
              data-status={card.status}
              class="flex flex-col gap-2 rounded-xl border border-base-300 p-4"
            >
              <div class="flex items-center gap-2">
                <span
                  class="size-2.5 shrink-0 rounded-full"
                  style={card.template.color && "background-color: #{card.template.color}"}
                />
                <%!-- the name alone (the handle shows on hover and once added); the
                     permission only when it is not the usual "edits" --%>
                <span class="truncate text-sm font-semibold" title={"@" <> card.name}>
                  {card.template.display_name || card.name}
                </span>
                <span
                  :if={card.template.mode == "plan"}
                  id={"gallery-#{card.name}-read-only"}
                  class="badge badge-sm badge-soft badge-info ml-auto shrink-0"
                  title="Read-only: reviews and plans, never edits"
                >
                  read-only
                </span>
              </div>
              <p class="text-xs text-base-content/80">{card.template.role}</p>
              <p class="line-clamp-3 text-xs text-base-content/60">{card.template.system_prompt}</p>
              <div class="mt-auto flex items-center gap-2 pt-1">
                <%= case card.status do %>
                  <% :new -> %>
                    <.link
                      navigate={~p"/agents/import?gallery=#{card.name}"}
                      id={"gallery-add-#{card.name}"}
                      class="btn btn-sm"
                    >
                      <.icon name="hero-plus-mini" class="size-4" /> Add
                    </.link>
                  <% :added -> %>
                    <span
                      id={"gallery-added-#{card.name}"}
                      class="flex items-center gap-1 text-xs text-success"
                    >
                      <.icon name="hero-check-mini" class="size-4" /> Added
                    </span>
                  <% :differs -> %>
                    <span class="text-xs text-warning">Differs from @{card.name} here</span>
                    <.link
                      navigate={~p"/agents/import?gallery=#{card.name}&replace=1"}
                      id={"gallery-compare-#{card.name}"}
                      class="btn btn-ghost btn-xs"
                    >
                      Compare
                    </.link>
                <% end %>
              </div>
            </li>
          </ul>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
