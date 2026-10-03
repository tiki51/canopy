defmodule CanopyWeb.CommandPalette do
  @moduledoc """
  The command palette (⌘K, Ctrl+K elsewhere): jump to a channel, DM, agent,
  team, repository or file, run a page action, or start a slash command.

  The shell renders it on every page with a sidebar. The server only renders a
  closed native `<dialog>` and the data the browser matches against, as data
  attributes on the `#cmdk` container: `data-items` (channels, DMs, agents,
  teams, repositories, playbooks), `data-badges` (unread, mentions and cards
  waiting, per channel), `data-context` (where you are) and `data-commands`
  (`Canopy.Runtime.Commands.catalog/0`). The container is `phx-update="ignore"`,
  so LiveView keeps the data attributes current and never touches the dialog,
  whose contents belong to the `CommandPalette` hook
  (`assets/js/hooks/command_palette.js`). Matching runs in the browser
  (`assets/js/command_palette/match.js`).

  Three things ask the server, and `CanopyWeb.Nav` answers them on every page:
  `cmdk:files` (a filename search), `cmdk:stop` (`/stop` for another channel)
  and `cmdk:notify` (the desktop notifications switch, which lives in the
  browser, was flipped: a flash confirms it).

  DOM ids use the `cmdk-` prefix: "palette" already means the colour palette.
  """

  use CanopyWeb, :html

  alias Canopy.Channels
  alias Canopy.Runtime.Commands

  @doc """
  Everything the palette can jump to, from what `CanopyWeb.Nav` already loads:
  channels (archived ones flagged), DMs by their label, active agents, teams,
  repositories, and the enabled playbooks (`palette` is Nav's `:palette`).
  """
  def items(repositories, dms, agents, palette \\ %{}) do
    channels =
      for repository <- repositories, channel <- repository.channels do
        %{
          t: "channel",
          id: channel.id,
          name: channel.name,
          repo: repository.name,
          repo_id: repository.id,
          archived: Channels.archived?(channel)
        }
      end

    direct =
      for dm <- dms do
        %{
          t: "dm",
          id: dm.id,
          label: Channels.dm_label(dm),
          repo: repository_name(dm),
          repo_id: dm.repository_id,
          archived: Channels.archived?(dm)
        }
      end

    members =
      for agent <- agents,
          do: %{t: "agent", id: agent.id, name: agent.name, role: agent.role, group: agent.group}

    teams =
      for team <- Map.get(palette, :teams, []), do: %{t: "team", id: team.id, name: team.name}

    repos =
      for repository <- repositories, do: %{t: "repo", id: repository.id, name: repository.name}

    playbooks =
      for playbook <- Map.get(palette, :playbooks, []),
          do: %{t: "playbook", id: playbook.id, name: playbook.name}

    channels ++ direct ++ members ++ teams ++ repos ++ playbooks
  end

  @doc """
  `%{channel_id => [unread, mentions, waiting]}` for the channels with any of
  them: unread messages and mentions (`Canopy.Unread.summary/1`) and cards or
  sign-offs waiting on the user (`Canopy.Attention.total/1`).
  """
  def badges(unread, attention) do
    (Map.keys(unread) ++ Map.keys(attention))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      counts = Map.get(unread, id, %{})

      entry = [
        Map.get(counts, :count, 0),
        Map.get(counts, :mentions, 0),
        Canopy.Attention.total(Map.get(attention, id))
      ]

      if Enum.all?(entry, &(&1 == 0)), do: [], else: [{id, entry}]
    end)
    |> Map.new()
  end

  @doc "Where you are: the open channel and its repository, the path, and whether a hold is on."
  def context(assigns) do
    %{
      channel_id: assigns[:current_channel_id],
      repo_id: assigns[:current_repository_id],
      path: assigns[:current_path] || "/",
      hold: not is_nil(assigns[:hold])
    }
  end

  @doc "The slash commands, as the palette lists them (`Commands.catalog/0`)."
  def commands do
    for command <- Commands.catalog() do
      %{
        name: command.name,
        aliases: command.aliases,
        usage: command.usage,
        summary: command.summary,
        prefill: command.prefill,
        dm: command.dm?
      }
    end
  end

  defp repository_name(%{repository: %{name: name}}), do: name
  defp repository_name(_), do: nil

  attr :items, :list, required: true
  attr :badges, :map, required: true
  attr :context, :map, required: true

  @doc """
  The palette: a closed dialog inside a `phx-update="ignore"` container that
  carries the data. Rendered once by `CanopyWeb.Layouts.app/1`.
  """
  def palette(assigns) do
    assigns = assign(assigns, :commands, commands())

    ~H"""
    <div
      id="cmdk"
      phx-hook="CommandPalette"
      phx-update="ignore"
      data-items={Jason.encode!(@items)}
      data-badges={Jason.encode!(@badges)}
      data-context={Jason.encode!(@context)}
      data-commands={Jason.encode!(@commands)}
    >
      <dialog
        id="cmdk-dialog"
        aria-label="Command palette"
        class={[
          "inset-x-0 top-0 mx-auto mt-[12vh] mb-auto h-fit max-h-[80dvh] w-[calc(100%-2rem)] max-w-xl",
          "flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-200 p-0 text-base-content shadow-2xl",
          "backdrop:bg-base-content/40 open:flex",
          "max-sm:mt-0 max-sm:max-h-[70dvh] max-sm:w-full max-sm:max-w-none max-sm:rounded-t-none max-sm:border-x-0 max-sm:border-t-0"
        ]}
      >
        <div class="flex shrink-0 items-center gap-2 border-b border-base-300 px-3">
          <.icon name="hero-magnifying-glass" class="size-5 shrink-0 text-base-content/50" />
          <span
            id="cmdk-chip"
            hidden
            class="shrink-0 whitespace-nowrap rounded-md bg-primary/10 px-1.5 py-0.5 font-mono text-xs font-medium text-primary"
          ></span>
          <input
            id="cmdk-input"
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls="cmdk-list"
            aria-autocomplete="list"
            aria-label="Jump to"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            placeholder="Jump to a channel, agent, file or command…"
            class="min-w-0 flex-1 border-0 bg-transparent py-3 text-base outline-none placeholder:text-base-content/40 focus:outline-none"
          />
          <kbd class="hidden shrink-0 rounded border border-base-300 px-1.5 py-0.5 font-sans text-[10px] text-base-content/50 sm:inline pointer-coarse:hidden">
            esc
          </kbd>
        </div>
        <div
          id="cmdk-list"
          role="listbox"
          aria-label="Results"
          class="min-h-0 flex-1 overflow-y-auto overscroll-contain py-1"
        >
        </div>
        <div
          id="cmdk-footer"
          class="flex shrink-0 flex-wrap items-center gap-x-3 gap-y-1 border-t border-base-300 px-3 py-1.5 text-[11px] text-base-content/50 pointer-coarse:hidden"
        >
          <span><kbd class="font-sans">↑↓</kbd> move</span>
          <span><kbd class="font-sans">↵</kbd> open</span>
          <span><kbd class="font-sans">⇧↵</kbd> alternative</span>
          <span>
            <kbd class="font-mono">#</kbd> <kbd class="font-mono">@</kbd>
            <kbd class="font-mono">&gt;</kbd> <kbd class="font-mono">/</kbd> filter
          </span>
          <span class="ml-auto"><kbd class="font-sans">esc</kbd> close</span>
        </div>
        <div id="cmdk-status" class="sr-only" aria-live="polite"></div>
      </dialog>
    </div>
    """
  end

  @doc """
  The sidebar's "Jump to…" button: the palette for the mouse and touch. The
  hint shows ⌘K on a Mac and Ctrl K elsewhere (app.js marks `<html>` with
  `data-platform`), and hides on touch screens.
  """
  def open_button(assigns) do
    ~H"""
    <button
      type="button"
      id="cmdk-open"
      phx-click={JS.dispatch("cmdk:toggle", to: "#cmdk")}
      class="flex w-full items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 text-sm text-base-content/60 shadow-xs transition hover:border-base-content/20 hover:text-base-content"
      aria-haspopup="dialog"
      aria-controls="cmdk-dialog"
    >
      <.icon name="hero-magnifying-glass-mini" class="size-4 shrink-0" />
      <span class="flex-1 text-left">Jump to…</span>
      <kbd class="shrink-0 rounded border border-base-300 px-1 font-sans text-[10px] text-base-content/50 pointer-coarse:hidden">
        <span class="kbd-mac">⌘K</span><span class="kbd-other">Ctrl K</span>
      </kbd>
    </button>
    """
  end
end
