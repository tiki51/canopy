defmodule CanopyWeb.Sidebar do
  @moduledoc """
  One project's block in the sidebar: the project row with its **+** (new
  section), the channels in no section, the sections in their order, and the
  "N archived" fold.

  The markup is plain server-rendered HEEx. The browser side
  (`assets/js/hooks/sidebar_channels.js`, on `#sidebar-projects`) reads the
  `data-*` attributes here to build the row and section menus, to name
  sections in place and to drag; every change goes back as a Nav event
  (`CanopyWeb.Nav`), and the next render puts things where they belong.
  Hover and focus reveal of the row actions is CSS only (`group-hover/row`).
  """
  use CanopyWeb, :html

  alias Canopy.Channels
  alias Canopy.Channels.Sections

  attr :repository, :map, required: true, doc: "a repository with :channels and :sections"
  attr :current_channel_id, :string, default: nil
  attr :unread, :map, default: %{}
  attr :attention, :map, default: %{}

  def project(assigns) do
    assigns =
      assign(assigns, :group, Sections.group(assigns.repository, assigns.current_channel_id))

    ~H"""
    <div class="px-2 pb-2" id={"sidebar-repo-#{@repository.id}"} data-repo-id={@repository.id}>
      <div
        class="group/proj flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-semibold text-base-content/70"
        title={@repository.path}
      >
        <.icon name="hero-folder-mini" class="size-3.5 text-base-content/40" />
        <span class="truncate">{@repository.name}</span>
        <button
          type="button"
          id={"sidebar-new-section-btn-#{@repository.id}"}
          data-new-section={@repository.id}
          aria-controls={"sidebar-new-section-#{@repository.id}"}
          title="New section"
          aria-label={"New section in #{@repository.name}"}
          class={[
            "ml-auto flex size-5 shrink-0 items-center justify-center rounded text-base-content/60",
            "opacity-0 hover:bg-base-300 hover:text-base-content focus-visible:opacity-100",
            "group-hover/proj:opacity-100 pointer-coarse:size-8 pointer-coarse:-my-1.5",
            "pointer-coarse:text-base-content/40 pointer-coarse:opacity-100"
          ]}
        >
          <.icon name="hero-plus-mini" class="size-3.5 pointer-coarse:size-4" />
        </button>
      </div>

      <.section_editor
        id={"sidebar-new-section-#{@repository.id}"}
        mode="create"
        repository_id={@repository.id}
      />

      <ul
        id={"sidebar-top-#{@repository.id}"}
        data-drop-section=""
        class="sidebar-drop flex flex-col gap-px rounded-md"
      >
        <.channel_row
          :for={channel <- @group.top}
          :key={channel.id}
          channel={channel}
          current_channel_id={@current_channel_id}
          unread={@unread}
          attention={@attention}
        />
        <li :if={@repository.channels == []} class="px-2 py-0.5 text-xs text-base-content/60">
          no channels
        </li>
      </ul>

      <div id={"sidebar-sections-#{@repository.id}"} class="flex flex-col">
        <.section
          :for={{%{section: section, channels: channels}, index} <- Enum.with_index(@group.sections)}
          :key={section.id}
          section={section}
          channels={channels}
          index={index}
          last?={index == length(@group.sections) - 1}
          current_channel_id={@current_channel_id}
          unread={@unread}
          attention={@attention}
        />
      </div>

      <details
        :if={@group.archived != []}
        id={"sidebar-archived-#{@repository.id}"}
        class="group/arch mt-1.5"
      >
        <summary class="flex cursor-pointer select-none list-none items-center gap-1 rounded-md px-2 py-1 text-[11px] text-base-content/45 hover:text-base-content/70 [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right-mini"
            class="size-3 transition-transform group-open/arch:rotate-90"
          />
          <.icon name="hero-archive-box-micro" class="size-3" />
          {length(@group.archived)} archived
        </summary>
        <ul class="flex flex-col gap-px">
          <li :for={channel <- @group.archived} :key={channel.id}>
            <.link
              navigate={~p"/channels/#{channel.id}"}
              id={"sidebar-channel-#{channel.id}"}
              class="flex items-center gap-1.5 rounded-md px-2 py-1 text-sm text-base-content/50 opacity-70 transition hover:bg-base-300 hover:text-base-content"
              title={channel.topic}
            >
              <span class="opacity-60">#</span>
              <span class="truncate">{channel.name}</span>
              <.icon name="hero-archive-box-mini" class="ml-auto size-3.5 opacity-60" />
            </.link>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :channels, :list, required: true
  attr :index, :integer, required: true
  attr :last?, :boolean, default: false
  attr :current_channel_id, :string, default: nil
  attr :unread, :map, default: %{}
  attr :attention, :map, default: %{}

  # A section is one <ul>: its header is the first item, its open channels
  # follow. One element for both is what lets SortableJS treat the header and
  # the rows as a single drop zone (a collapsed section is still a target).
  defp section(assigns) do
    assigns =
      assigns
      |> assign(:open_count, Enum.count(assigns.channels, &(&1.status != "archived")))
      |> assign(
        :dot?,
        Enum.any?(assigns.channels, fn channel ->
          channel.id != assigns.current_channel_id and
            (Map.has_key?(assigns.unread, channel.id) or
               Canopy.Attention.total(Map.get(assigns.attention, channel.id)) > 0)
        end)
      )

    ~H"""
    <ul
      id={"sidebar-section-#{@section.id}"}
      data-section-id={@section.id}
      data-section-name={@section.name}
      data-index={@index}
      data-first={@index == 0}
      data-last={@last?}
      data-collapsed={@section.collapsed}
      aria-labelledby={"sidebar-section-label-#{@section.id}"}
      class="sidebar-drop mt-1 flex flex-col gap-px rounded-md"
    >
      <li class="group/head relative flex items-center rounded-md" data-section-header>
        <button
          type="button"
          id={"sidebar-section-toggle-#{@section.id}"}
          data-section-handle
          aria-expanded={to_string(!@section.collapsed)}
          aria-keyshortcuts="Shift+F10"
          phx-click="toggle_section"
          phx-value-id={@section.id}
          phx-value-collapsed={to_string(!@section.collapsed)}
          class="flex min-w-0 flex-1 cursor-pointer items-center gap-1 rounded-md px-2 py-1 text-left text-xs text-base-content/60 hover:text-base-content"
        >
          <.icon
            name="hero-chevron-right-mini"
            class={["size-3 shrink-0", !@section.collapsed && "rotate-90"]}
          />
          <span id={"sidebar-section-label-#{@section.id}"} class="truncate">{@section.name}</span>
          <span
            :if={@section.collapsed}
            id={"sidebar-section-count-#{@section.id}"}
            class="shrink-0 text-base-content/50"
          >
            {@open_count}
          </span>
          <span
            :if={@section.collapsed and @dot?}
            id={"sidebar-section-dot-#{@section.id}"}
            class="size-1.5 shrink-0 rounded-full bg-secondary"
            title="Something inside is unread or needs you"
          />
        </button>
        <.section_editor
          id={"sidebar-rename-section-#{@section.id}"}
          mode="rename"
          section_id={@section.id}
        />
        <button
          type="button"
          tabindex="-1"
          id={"sidebar-section-menu-#{@section.id}"}
          data-menu="section"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-label={"Actions for section #{@section.name}"}
          title="Section actions"
          class={[
            "mr-1 flex size-5 shrink-0 items-center justify-center rounded text-base-content/60",
            "opacity-0 hover:bg-base-300 hover:text-base-content",
            "group-hover/head:opacity-100 group-focus-within/head:opacity-100",
            "pointer-coarse:size-8 pointer-coarse:-my-1.5 pointer-coarse:text-base-content/40 pointer-coarse:opacity-100"
          ]}
        >
          <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
        </button>
      </li>
      <.channel_row
        :for={channel <- @channels}
        :key={channel.id}
        channel={channel}
        hidden={@section.collapsed and channel.id != @current_channel_id}
        current_channel_id={@current_channel_id}
        unread={@unread}
        attention={@attention}
      />
    </ul>
    """
  end

  attr :channel, :map, required: true
  attr :hidden, :boolean, default: false
  attr :current_channel_id, :string, default: nil
  attr :unread, :map, default: %{}
  attr :attention, :map, default: %{}

  # The link and the row's buttons are siblings (a button can't sit inside a
  # link). The buttons are out of the tab order: each row stays one Tab stop,
  # and the keyboard reaches the same actions through the menu (Shift+F10).
  defp channel_row(assigns) do
    assigns =
      assigns
      |> assign(:current?, assigns.channel.id == assigns.current_channel_id)
      |> assign(:archived?, assigns.channel.status == "archived")
      |> assign(:done?, Channels.archive_offer?(assigns.channel))
      |> assign(
        :row_button,
        "flex size-6 items-center justify-center rounded text-base-content/60 hover:bg-base-content/10 hover:text-base-content " <>
          "pointer-coarse:size-8 pointer-coarse:-my-1 pointer-coarse:text-base-content/40 pointer-coarse:hover:bg-transparent"
      )
      |> assign(
        :unread?,
        assigns.channel.id != assigns.current_channel_id and
          Map.has_key?(assigns.unread, assigns.channel.id)
      )

    ~H"""
    <li
      id={"sidebar-row-#{@channel.id}"}
      class={[
        "group/row relative flex items-center rounded-md transition",
        @hidden && "hidden",
        @current? && "bg-primary/10 dark:bg-primary/15",
        !@current? && "hover:bg-base-300"
      ]}
      data-channel-id={@channel.id}
      data-section-id={@channel.section_id}
      data-name={@channel.name}
      data-unread={to_string(@unread?)}
      data-archived={to_string(@archived?)}
    >
      <.link
        navigate={~p"/channels/#{@channel.id}"}
        id={"sidebar-channel-#{@channel.id}"}
        data-active={@current?}
        aria-keyshortcuts="Shift+F10"
        class={[
          "flex min-w-0 flex-1 items-center gap-1.5 rounded-md px-2 py-1 text-sm",
          "pointer-fine:group-hover/row:pr-14 pointer-fine:group-focus-within/row:pr-14",
          @current? && "text-primary font-medium",
          !@current? && "text-base-content/80 hover:text-base-content",
          @archived? && "opacity-50"
        ]}
        title={@channel.topic}
      >
        <span class="opacity-60">#</span>
        <span class={["truncate", @unread? && "font-semibold text-base-content"]}>
          {@channel.name}
        </span>
        <span
          :if={Canopy.Attention.playbook?(Map.get(@attention, @channel.id))}
          id={"sidebar-playbook-#{@channel.id}"}
          class="flex shrink-0 text-primary/70"
          title="A playbook run is in progress"
        >
          <.icon name="hero-book-open-micro" class="size-3" />
        </span>
        <.icon
          :if={@archived?}
          name="hero-archive-box-mini"
          class="ml-auto size-3.5 opacity-60"
        />
        <span class="row-badges ml-auto flex shrink-0 items-center gap-1 pointer-fine:group-hover/row:invisible pointer-fine:group-focus-within/row:invisible">
          <CanopyWeb.Layouts.attention_mark attention={@attention} channel_id={@channel.id} />
          <CanopyWeb.Layouts.unread_mark
            unread={@unread}
            channel_id={@channel.id}
            current_id={@current_channel_id}
          />
          <span
            :if={@done?}
            id={"sidebar-done-#{@channel.id}"}
            class="flex shrink-0 text-success/80"
            title="Task done: archive or keep open"
          >
            <.icon name="hero-check-circle-mini" class="size-4" />
          </span>
        </span>
      </.link>
      <div class={[
        "row-actions hidden items-center gap-0.5",
        "pointer-fine:absolute pointer-fine:inset-y-0 pointer-fine:right-1",
        "pointer-fine:group-hover/row:flex pointer-fine:group-focus-within/row:flex",
        "pointer-coarse:flex pointer-coarse:pr-1"
      ]}>
        <button
          :if={!@archived?}
          type="button"
          tabindex="-1"
          id={"sidebar-archive-#{@channel.id}"}
          class={[@row_button, "pointer-coarse:hidden"]}
          aria-label={"Archive ##{@channel.name}"}
          title="Archive channel"
          phx-click="archive_channel"
          phx-value-id={@channel.id}
        >
          <.icon name="hero-archive-box-arrow-down-mini" class="size-4" />
        </button>
        <button
          type="button"
          tabindex="-1"
          id={"sidebar-row-menu-#{@channel.id}"}
          class={[@row_button, @current? && "pointer-coarse:text-base-content/70"]}
          data-menu="channel"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-label={"Actions for ##{@channel.name}"}
          title="More actions"
        >
          <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
        </button>
      </div>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :mode, :string, required: true, values: ~w(create rename)
  attr :repository_id, :string, default: nil
  attr :section_id, :string, default: nil

  # Naming a section in place. The wrapper is shown and hidden by the hook
  # through `this.js()` (sticky across patches); the form inside is ignored by
  # LiveView, so what is typed and the error line belong to the hook. The form
  # has no phx-change or phx-submit: the hook sends `create_section` or
  # `rename_section` itself and reads the reply.
  defp section_editor(assigns) do
    ~H"""
    <div
      id={@id}
      class={["hidden", @mode == "rename" && "absolute inset-0 z-10"]}
      data-section-editor={@mode}
      data-repo-id={@repository_id}
      data-section-id={@section_id}
    >
      <div id={"#{@id}-box"} phx-update="ignore">
        <form id={"#{@id}-form"} class="flex flex-col gap-0.5 px-1 py-0.5" autocomplete="off">
          <label class="flex items-center gap-1 rounded-md border border-primary/60 bg-base-100 px-1.5 py-0.5 text-xs shadow-xs focus-within:ring-1 focus-within:ring-primary/40">
            <.icon name="hero-chevron-down-mini" class="size-3 shrink-0 text-base-content/40" />
            <input
              type="text"
              name="name"
              required
              maxlength="40"
              spellcheck="false"
              placeholder={if @mode == "create", do: "Section name", else: nil}
              aria-label="Section name"
              aria-describedby={"#{@id}-error"}
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-xs outline-none focus:ring-0"
            />
            <span class="shrink-0 text-[10px] text-base-content/50" aria-hidden="true">
              ↵ to save
            </span>
          </label>
          <p id={"#{@id}-error"} class="px-1 text-[11px] text-error empty:hidden" role="alert"></p>
        </form>
      </div>
    </div>
    """
  end
end
