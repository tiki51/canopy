defmodule CanopyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CanopyWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :repositories, :list, default: [], doc: "repositories with :channels, from CanopyWeb.Nav"
  attr :dms, :list, default: [], doc: "direct-message channels, from CanopyWeb.Nav"
  attr :agents, :list, default: [], doc: "active agents, from CanopyWeb.Nav"
  attr :unread, :map, default: %{}, doc: "channel_id => %{count, mentions}, from CanopyWeb.Nav"
  attr :current_path, :string, default: "/"
  attr :current_channel_id, :string, default: nil
  attr :current_repository_id, :string, default: nil, doc: "repository of the open channel"
  attr :agent_statuses, :map, default: %{}, doc: "agent_id => :idle | :busy | :error"

  slot :inner_block, required: true

  # The Canopy shell: a narrow workspace rail, the channels/agents sidebar, and the
  # main column. Every LiveView renders inside it; sidebar data comes from CanopyWeb.Nav.
  def app(assigns) do
    ~H"""
    <div class="flex h-dvh overflow-hidden bg-base-100 text-base-content">
      <%!-- Below lg the rail and sidebar slide in over the page; this checkbox
      is their open state, toggled by <.menu_button> and the overlay. --%>
      <input id="app-drawer" type="checkbox" class="peer sr-only" aria-hidden="true" tabindex="-1" />
      <label
        for="app-drawer"
        id="app-drawer-overlay"
        class="fixed inset-0 z-30 hidden bg-black/40 peer-checked:block lg:hidden"
        aria-label="Close the menu"
      ></label>
      <div
        id="app-nav"
        class="fixed inset-y-0 left-0 z-40 flex -translate-x-full shadow-xl transition-transform duration-200 peer-checked:translate-x-0 lg:static lg:translate-x-0 lg:shadow-none"
      >
        <nav
          id="rail"
          class="flex w-14 shrink-0 flex-col items-center gap-1 border-r border-base-300/60 bg-neutral py-3 text-neutral-content"
          aria-label="Workspace"
        >
          <.link
            navigate={~p"/"}
            class="mb-3 flex size-9 items-center justify-center rounded-lg shadow-sm transition hover:scale-105"
            title="Canopy"
          >
            <img
              src={~p"/images/canopy-icon-64.png"}
              alt="Canopy"
              width="36"
              height="36"
              class="size-9 rounded-lg"
            />
          </.link>
          <.rail_link
            navigate={~p"/repositories"}
            icon="hero-folder"
            title="Repositories"
            active={@current_path == "/repositories"}
          />
          <.rail_link
            navigate={~p"/agents"}
            icon="hero-cpu-chip"
            title="Agents"
            active={@current_path == "/agents"}
          />
          <.rail_link
            navigate={~p"/settings"}
            icon="hero-cog-6-tooth"
            title="Settings"
            active={@current_path == "/settings"}
          />
          <div class="mt-auto">
            <.theme_toggle />
          </div>
        </nav>

        <aside
          id="sidebar"
          class="flex w-64 shrink-0 flex-col overflow-y-auto border-r border-base-300 bg-base-200"
          aria-label="Channels and agents"
        >
          <div class="flex items-center justify-between px-4 pt-4 pb-2">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
              Channels
            </span>
            <.link
              navigate={~p"/channels/new"}
              class={[
                "flex size-6 items-center justify-center rounded-md text-base-content/60 transition",
                "hover:bg-base-300 hover:text-base-content",
                @current_path == "/channels/new" && "bg-base-300 text-base-content"
              ]}
              title="New channel"
              id="sidebar-new-channel"
            >
              <.icon name="hero-plus" class="size-4" />
            </.link>
          </div>

          <div
            :if={@repositories == []}
            class="mx-3 mb-3 rounded-lg border border-dashed border-base-300 p-3 text-xs text-base-content/60"
          >
            No repositories yet.
            <.link navigate={~p"/repositories"} class="link link-primary">Add one</.link>
            to create channels.
          </div>

          <div
            :for={repository <- @repositories}
            class="px-2 pb-2"
            id={"sidebar-repo-#{repository.id}"}
          >
            <div
              class="flex items-center gap-1.5 px-2 py-1 text-xs font-semibold text-base-content/70"
              title={repository.path}
            >
              <.icon name="hero-folder-mini" class="size-3.5 text-base-content/40" />
              <span class="truncate">{repository.name}</span>
            </div>
            <ul class="flex flex-col gap-px">
              <li :for={channel <- repository.channels}>
                <.link
                  navigate={~p"/channels/#{channel.id}"}
                  id={"sidebar-channel-#{channel.id}"}
                  data-active={channel.id == @current_channel_id}
                  class={[
                    "flex items-center gap-1.5 rounded-md px-2 py-1 text-sm transition",
                    channel.id == @current_channel_id && "bg-primary/15 text-primary font-medium",
                    channel.id != @current_channel_id &&
                      "text-base-content/80 hover:bg-base-300 hover:text-base-content",
                    channel.status == "archived" && "opacity-50"
                  ]}
                  title={channel.topic}
                >
                  <span class="opacity-60">#</span>
                  <span class={["truncate", unread_class(@unread, channel.id, @current_channel_id)]}>
                    {channel.name}
                  </span>
                  <.icon
                    :if={channel.status == "archived"}
                    name="hero-archive-box-mini"
                    class="ml-auto size-3.5 opacity-60"
                  />
                  <.unread_mark
                    unread={@unread}
                    channel_id={channel.id}
                    current_id={@current_channel_id}
                  />
                </.link>
              </li>
              <li :if={repository.channels == []} class="px-2 py-0.5 text-xs text-base-content/40">
                no channels
              </li>
            </ul>
          </div>

          <div class="mt-2 flex items-center justify-between px-4 pt-2 pb-2">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
              Direct messages
            </span>
          </div>
          <ul id="sidebar-dms" class="flex flex-col gap-px px-2 pb-2">
            <li :for={dm <- @dms}>
              <.link
                navigate={~p"/channels/#{dm.id}"}
                id={"sidebar-dm-#{dm.id}"}
                data-active={dm.id == @current_channel_id}
                title={"#{Canopy.Channels.dm_label(dm)} · #{dm.repository.name}"}
                class={[
                  "flex items-center gap-1.5 rounded-md px-2 py-1 text-sm transition",
                  dm.id == @current_channel_id && "bg-primary/15 text-primary font-medium",
                  dm.id != @current_channel_id &&
                    "text-base-content/80 hover:bg-base-300 hover:text-base-content",
                  dm.status == "archived" && "opacity-50"
                ]}
              >
                <.icon name="hero-chat-bubble-left-right-mini" class="size-3.5 shrink-0 opacity-60" />
                <span class={["truncate", unread_class(@unread, dm.id, @current_channel_id)]}>
                  {Canopy.Channels.dm_label(dm)}
                </span>
                <span :if={length(@repositories) > 1} class="ml-auto truncate text-[10px] opacity-50">
                  {dm.repository.name}
                </span>
                <.unread_mark unread={@unread} channel_id={dm.id} current_id={@current_channel_id} />
              </.link>
            </li>
            <li :if={@dms == []} class="px-2 text-xs text-base-content/40">
              Click an agent below to start one
            </li>
          </ul>

          <div class="flex items-center justify-between px-4 pt-2 pb-2">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
              Agents
            </span>
            <.link
              navigate={~p"/agents"}
              class="flex size-6 items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
              title="Manage agents"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4" />
            </.link>
          </div>
          <ul class="flex flex-col gap-px px-2 pb-4">
            <li :for={agent <- @agents}>
              <.link
                navigate={~p"/agents/#{agent.id}"}
                id={"sidebar-agent-#{agent.id}"}
                data-active={@current_path == "/agents/#{agent.id}"}
                title={"@#{agent.name}" <> if(agent.role, do: " · " <> agent.role, else: "")}
                class={[
                  "flex items-center gap-2 rounded-md px-2 py-1 text-sm transition",
                  @current_path == "/agents/#{agent.id}" && "bg-primary/15 text-primary font-medium",
                  @current_path != "/agents/#{agent.id}" &&
                    "text-base-content/80 hover:bg-base-300 hover:text-base-content"
                ]}
              >
                <.status_dot status={Map.get(@agent_statuses, agent.id, :idle)} />
                <span class="shrink-0">@{agent.name}</span>
                <span
                  :if={agent.role}
                  class={[
                    "min-w-0 truncate text-[11px]",
                    @current_path == "/agents/#{agent.id}" && "text-primary/70",
                    @current_path != "/agents/#{agent.id}" && "text-base-content/40"
                  ]}
                >
                  {agent.role}
                </span>
              </.link>
            </li>
            <li :if={@agents == []} class="px-2 text-xs text-base-content/40">no agents</li>
          </ul>
        </aside>
      </div>

      <main class="flex min-w-0 flex-1 flex-col overflow-hidden">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :active, :boolean, default: false

  defp rail_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      title={@title}
      aria-label={@title}
      class={[
        "relative flex size-10 items-center justify-center rounded-lg transition",
        @active && "bg-neutral-content/15 text-neutral-content",
        !@active && "text-neutral-content/60 hover:bg-neutral-content/10 hover:text-neutral-content"
      ]}
    >
      <span
        :if={@active}
        class="absolute -left-2 top-1/2 h-5 w-1 -translate-y-1/2 rounded-r-full bg-primary"
      />
      <.icon name={@icon} class="size-5" />
    </.link>
    """
  end

  attr :status, :atom, default: :idle

  @doc "Opens the rail and sidebar on small screens; hidden from lg up where they are always shown."
  def menu_button(assigns) do
    ~H"""
    <label
      for="app-drawer"
      class="btn btn-ghost btn-sm btn-square -ml-1 shrink-0 lg:hidden"
      aria-label="Open the menu"
      title="Menu"
    >
      <.icon name="hero-bars-3" class="size-5" />
    </label>
    """
  end

  @doc "A small coloured dot for agent status; it pings while the agent is busy."
  def status_dot(%{status: :busy} = assigns) do
    ~H"""
    <span class="relative inline-flex size-2 shrink-0" data-status="busy">
      <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-75" />
      <span class="relative inline-flex size-2 rounded-full bg-success" />
    </span>
    """
  end

  def status_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-block size-2 shrink-0 rounded-full",
        @status == :error && "bg-error",
        @status not in [:busy, :error] && "bg-base-content/25"
      ]}
      data-status={@status}
    />
    """
  end

  @doc """
  The standard scrollable page body for the admin screens (settings, repositories,
  agents, new channel): a sticky header with title, optional subtitle and actions,
  and a centred column for the content.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :max_width, :string, default: "max-w-3xl"
  slot :actions
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <header class="flex h-12 shrink-0 items-center justify-between gap-4 border-b border-base-300 px-3 sm:px-6">
      <div class="flex min-w-0 items-center gap-3">
        <.menu_button />
        <h1 class="truncate text-base font-semibold">{@title}</h1>
        <p :if={@subtitle} class="truncate text-xs text-base-content/60">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    <div class="flex-1 overflow-y-auto">
      <div class={["mx-auto flex flex-col gap-6 px-3 py-4 sm:px-6 sm:py-6", @max_width]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "A bordered section on an admin page, with a heading and optional description."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-xl border border-base-300 bg-base-200 shadow-xs", @class]}>
      <div class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-3">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold">{@title}</h2>
          <p :if={@description} class="mt-0.5 text-xs text-base-content/60">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="px-5 py-4">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc "A friendly empty-state block."
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-col items-center gap-2 rounded-lg border border-dashed border-base-300 px-4 py-8 text-center"
    >
      <.icon name={@icon} class="size-8 text-base-content/30" />
      <p class="text-sm font-medium">{@title}</p>
      <div :if={@inner_block != []} class="text-xs text-base-content/60">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-0.5 rounded-lg bg-neutral-content/10 p-1">
      <button
        class="flex size-7 cursor-pointer items-center justify-center rounded-md transition [[data-theme-source=system]_&]:bg-neutral-content/20"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex size-7 cursor-pointer items-center justify-center rounded-md transition [[data-theme=light][data-theme-source=user]_&]:bg-neutral-content/20"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex size-7 cursor-pointer items-center justify-center rounded-md transition [[data-theme=dark][data-theme-source=user]_&]:bg-neutral-content/20"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  # -- Unread marks -------------------------------------------------------------
  #
  # An unread channel gets a bold name and a dot; one that mentions the user
  # gets a filled count badge instead. The open channel never shows either.

  attr :unread, :map, required: true
  attr :channel_id, :string, required: true
  attr :current_id, :string, default: nil

  defp unread_mark(assigns) do
    assigns =
      assign(
        assigns,
        :state,
        unread_state(assigns.unread, assigns.channel_id, assigns.current_id)
      )

    ~H"""
    <span
      :if={@state}
      id={"unread-#{@channel_id}"}
      data-unread={@state.count}
      data-mentions={@state.mentions}
      class={[
        "ml-auto flex shrink-0 items-center justify-center",
        @state.mentions > 0 &&
          "h-4 min-w-4 rounded-full bg-primary px-1 text-[10px] font-bold leading-none text-primary-content",
        @state.mentions == 0 && "size-2 rounded-full bg-secondary"
      ]}
      title={unread_title(@state)}
    >
      {if @state.mentions > 0, do: @state.mentions}
    </span>
    """
  end

  defp unread_state(unread, channel_id, current_id) when channel_id != current_id,
    do: Map.get(unread, channel_id)

  defp unread_state(_unread, _channel_id, _current_id), do: nil

  defp unread_class(unread, channel_id, current_id) do
    if unread_state(unread, channel_id, current_id), do: "font-semibold text-base-content"
  end

  defp unread_title(%{count: count, mentions: 0}),
    do: "#{count} unread #{if count == 1, do: "message", else: "messages"}"

  defp unread_title(%{count: count, mentions: mentions}),
    do: "#{mentions} #{if mentions == 1, do: "mention", else: "mentions"} · #{count} unread"
end
