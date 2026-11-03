defmodule CanopyWeb.PlaybookSharingComponents do
  @moduledoc """
  Sharing playbooks through GitHub, on the Playbooks page and in Settings:
  the GitHub ▾ menu, the updates notice and row chips, the Import and Export
  dialogs, Compare (and View, for a playbook only on GitHub), the setup
  fields, the error boxes and the pull request toast.

  What goes where comes from `CanopyWeb.PlaybookSharing`; the states, names
  and versions from `Canopy.Playbooks.Sharing`. The dialogs are URL state
  (`?github=import|export&compare=<key>&row=<key>`), so every way in is a
  patch and closing is a patch back to `/playbooks`.
  """

  use CanopyWeb, :html

  import CanopyWeb.PlaybookComponents, only: [compare_step: 1]

  alias Canopy.Playbooks.Definition
  alias CanopyWeb.PlaybookSharing

  # -- Library page -------------------------------------------------------------------

  @doc "The GitHub mark (Heroicons has none)."
  attr :class, :any, default: "size-4"

  def github_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class={@class} fill="currentColor" aria-hidden="true">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
    """
  end

  @doc "A pull request (Octicons' git-pull-request), for In PR, Open pull request and the toast."
  attr :class, :any, default: "size-4"

  def pr_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class={@class} fill="currentColor" aria-hidden="true">
      <path d="M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z" />
    </svg>
    """
  end

  # A branch (Octicons' git-branch), for Export's branch line.
  attr :class, :any, default: "size-4"

  defp branch_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class={@class} fill="currentColor" aria-hidden="true">
      <path d="M9.5 3.25a2.25 2.25 0 1 1 3 2.122V6A2.5 2.5 0 0 1 10 8.5H6a1 1 0 0 0-1 1v1.128a2.251 2.251 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.5 0v1.836A2.493 2.493 0 0 1 6 7h4a1 1 0 0 0 1-1v-.628A2.25 2.25 0 0 1 9.5 3.25Zm-6 0a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Zm8.25-.75a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM4.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z" />
    </svg>
    """
  end

  @doc """
  GitHub ▾: Import from GitHub (with the updates badge), Export to GitHub,
  Import a file, and Open owner/name once sharing is set up.
  """
  attr :config, :any, required: true, doc: "`Sharing.config/0`'s map, or :not_set_up"
  attr :status, :any, default: nil

  def github_menu(assigns) do
    assigns = assign(assigns, :count, PlaybookSharing.update_count(assigns.status))

    ~H"""
    <div id="github-menu" class="dropdown dropdown-end">
      <button
        type="button"
        tabindex="0"
        id="github-menu-toggle"
        class="btn btn-ghost btn-sm"
        aria-haspopup="menu"
      >
        <.github_mark /> GitHub
        <span
          :if={@count > 0}
          class="badge badge-sm badge-secondary badge-soft"
          aria-label={"#{@count} updates"}
        >
          {@count}
        </span>
        <.icon name="hero-chevron-down-mini" class="size-4" />
      </button>
      <ul
        tabindex="0"
        role="menu"
        class="dropdown-content menu menu-sm z-30 mt-1 w-60 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg"
      >
        <li role="none">
          <.link
            patch={~p"/playbooks?github=import"}
            id="github-import"
            role="menuitem"
            class="flex items-center gap-2"
          >
            <.icon name="hero-arrow-down-tray-mini" class="size-4" />
            <span class="flex-1">Import from GitHub…</span>
            <span
              :if={@count > 0}
              id="github-import-badge"
              class="badge badge-sm badge-secondary badge-soft"
            >
              {@count}
            </span>
          </.link>
        </li>
        <li role="none">
          <.link
            patch={~p"/playbooks?github=export"}
            id="github-export"
            role="menuitem"
            class="flex items-center gap-2"
          >
            <.icon name="hero-arrow-up-tray-mini" class="size-4" /> Export to GitHub…
          </.link>
        </li>
        <li role="none" class="my-1 border-t border-base-300"></li>
        <li role="none">
          <.link navigate={~p"/agents/import"} id="import-playbook" role="menuitem">
            <.icon name="hero-document-arrow-up-mini" class="size-4" /> Import a file…
          </.link>
        </li>
        <li :if={@config != :not_set_up} role="none">
          <a
            href={PlaybookSharing.repo_url(@config, @status && @status.branch)}
            id="github-open-repo"
            role="menuitem"
            target="_blank"
            rel="noopener"
            class="flex items-center gap-2"
          >
            <.github_mark /> <span class="min-w-0 flex-1 truncate">Open {@config.repo}</span>
            <.icon name="hero-arrow-top-right-on-square-mini" class="size-4 opacity-60" />
          </a>
        </li>
      </ul>
    </div>
    """
  end

  @doc "`3 updates on GitHub · Review`, beside the draft notice."
  attr :count, :integer, required: true

  def updates_notice(assigns) do
    ~H"""
    <div
      id="playbook-github-notice"
      class="flex items-center gap-2 rounded-box border border-secondary/40 bg-secondary/5 px-3 py-1.5 text-sm"
    >
      <.github_mark class="size-4 text-secondary" />
      <span>{if @count == 1, do: "1 update", else: "#{@count} updates"} on GitHub</span>
      <.link
        patch={~p"/playbooks?github=import"}
        id="playbook-github-notice-review"
        class="link link-primary font-medium"
      >
        Review
      </.link>
    </div>
    """
  end

  @doc """
  A library row's chip: In PR #N links to the pull request; the others open
  Import at that row.
  """
  attr :id, :string, required: true
  attr :entry, :map, required: true

  def sync_chip(assigns) do
    assigns = assign(assigns, :chip, PlaybookSharing.chip(assigns.entry))

    ~H"""
    <%= cond do %>
      <% is_nil(@chip) -> %>
      <% @chip.state == :in_pr -> %>
        <a
          id={@id}
          href={@entry.pr.url}
          target="_blank"
          rel="noopener"
          data-state={@chip.state}
          class={["badge badge-sm shrink-0 gap-1 whitespace-nowrap", @chip.class]}
          title="Open the pull request on GitHub"
        >
          <.pr_mark class="size-3" />
          {@chip.label}
        </a>
      <% true -> %>
        <.link
          id={@id}
          patch={~p"/playbooks?#{[github: "import", row: @entry.key]}"}
          data-state={@chip.state}
          class={["badge badge-sm shrink-0 whitespace-nowrap", @chip.class]}
        >
          {@chip.label}
        </.link>
    <% end %>
    """
  end

  # -- Dialog frame -------------------------------------------------------------------

  # The modal frame both dialogs and Compare use, after `reset_modal/1`: an
  # overlay, a focus wrap, Esc and click-away only while `closable`.
  attr :id, :string, required: true
  attr :closable, :boolean, required: true
  attr :close, :any, required: true, doc: "the JS that closes it"
  attr :busy, :boolean, default: false
  attr :width, :string, default: "max-w-[720px]"
  attr :layer, :string, default: "z-50"
  slot :header, required: true
  slot :inner_block, required: true
  slot :footer

  defp sharing_modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["fixed inset-0 flex items-center justify-center p-4", @layer]}
      phx-window-keydown={@closable && @close}
      phx-key={@closable && "Escape"}
    >
      <div
        class="absolute inset-0 bg-neutral/30 backdrop-blur-[2px] dark:bg-black/50"
        aria-hidden="true"
      >
      </div>
      <.focus_wrap id={"#{@id}-focus"} class={["relative flex max-h-[85vh] w-full", @width]}>
        <div
          id={"#{@id}-panel"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          aria-describedby={"#{@id}-sub"}
          aria-busy={to_string(@busy)}
          tabindex="-1"
          phx-click-away={@closable && @close}
          class="flex w-full flex-col overflow-hidden rounded-2xl bg-base-100 text-base-content shadow-2xl outline-none ring-1 ring-base-content/10"
        >
          <header class="relative shrink-0 border-b border-base-300 pb-3 pl-6 pr-14 pt-5">
            {render_slot(@header)}
            <button
              type="button"
              id={"#{@id}-x"}
              class="btn btn-ghost btn-sm btn-square absolute right-3 top-3"
              aria-label="Close"
              phx-click={@close}
              disabled={!@closable}
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>
          <div id={"#{@id}-body"} class="min-h-0 flex-1 overflow-y-auto px-6 py-4">
            {render_slot(@inner_block)}
          </div>
          <footer :if={@footer != []} class="shrink-0 border-t border-base-300 px-6 py-3">
            {render_slot(@footer)}
          </footer>
        </div>
      </.focus_wrap>
    </div>
    """
  end

  # `owner/name › folder/ on main · Change`
  attr :config, :any, required: true
  attr :status, :any, default: nil
  attr :loading, :boolean, default: false

  defp where_line(assigns) do
    ~H"""
    <p
      :if={@config != :not_set_up}
      class="mt-1 flex flex-wrap items-center gap-x-1.5 text-sm text-base-content/65"
    >
      <.github_mark class="size-3.5" />
      <span id="sharing-where" class="font-mono text-[13px]">
        {@config.repo} › {PlaybookSharing.folder_label(@config.folder)} on {(@status && @status.branch) ||
          "default branch"}
      </span>
      <.link navigate={~p"/settings#playbook-sharing-panel"} class="link text-xs">Change</.link>
      <span
        :if={@loading}
        role="status"
        class="ml-auto flex items-center gap-1.5 text-xs text-base-content/55"
      >
        <span class="loading loading-spinner loading-xs"></span> Checking GitHub…
      </span>
    </p>
    """
  end

  defp close_dialog, do: JS.patch(~p"/playbooks") |> JS.focus(to: "#github-menu-toggle")

  # -- Import ---------------------------------------------------------------------------

  @doc """
  The Import dialog: the first-run setup while sharing isn't set up, else
  Ready, Needs a look, Can't import and the up-to-date count.
  """
  attr :sharing, :map, required: true
  attr :picks, :any, required: true
  attr :choices, :map, required: true
  attr :busy, :any, default: nil
  attr :row, :string, default: nil
  attr :stacked, :boolean, default: false, doc: "Compare is open on top"
  attr :setup_form, :any, default: nil
  attr :check, :any, default: nil
  attr :taken, :any, default: MapSet.new(), doc: "the library's playbook names"

  def import_modal(assigns) do
    %{sharing: %{status: status}, picks: picks, choices: choices} = assigns
    groups = PlaybookSharing.import_groups((status && status.entries) || [])

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:groups, groups)
      |> assign(:count, import_count(groups, picks, choices))
      |> assign(:names, PlaybookSharing.import_names(groups, picks, choices, assigns.taken))

    ~H"""
    <.sharing_modal
      id="github-import-dialog"
      closable={is_nil(@busy) and !@stacked}
      close={close_dialog()}
      busy={!is_nil(@busy)}
    >
      <:header>
        <h2 id="github-import-dialog-title" class="text-lg font-semibold">Import from GitHub</h2>
        <p
          :if={@sharing.config == :not_set_up}
          id="github-import-dialog-sub"
          class="text-sm text-base-content/65"
        >
          Set up sharing once; it's saved in Settings
        </p>
        <div :if={@sharing.config != :not_set_up} id="github-import-dialog-sub">
          <.where_line
            config={@sharing.config}
            status={@status}
            loading={@sharing.loading?}
          />
        </div>
      </:header>

      <%= if @sharing.config == :not_set_up do %>
        <.setup_body form={@setup_form} check={@check} />
      <% else %>
        <.dialog_error sharing={@sharing} />
        <.loading_rows :if={@sharing.loading? and is_nil(@status)} />
        <.empty_folder :if={@status && !@status.folder?} config={@sharing.config} status={@status} />
        <div
          :if={@status && @status.folder?}
          id="import-sections"
          class={["flex flex-col gap-5", @sharing.loading? && "pointer-events-none opacity-60"]}
        >
          <section :if={@groups.ready != []} aria-labelledby="import-ready-heading">
            <h3 id="import-ready-heading" class={heading()}>
              Ready <span class="font-normal">{length(@groups.ready)}</span>
              <span class="font-normal normal-case tracking-normal">· checked for you</span>
            </h3>
            <ul id="import-ready" class={list_box()}>
              <.import_row
                :for={entry <- @groups.ready}
                entry={entry}
                ticked={MapSet.member?(@picks, entry.key)}
                choice={nil}
                as={@names[entry.key]}
                focused={@row == entry.key}
                busy={!is_nil(@busy)}
              />
            </ul>
          </section>

          <section :if={@groups.look != []} aria-labelledby="import-look-heading">
            <h3 id="import-look-heading" class={heading()}>
              Needs a look <span class="font-normal">{length(@groups.look)}</span>
              <span class="font-normal normal-case tracking-normal">· compare, then choose</span>
            </h3>
            <ul id="import-look" class={list_box()}>
              <.import_row
                :for={entry <- @groups.look}
                entry={entry}
                ticked={MapSet.member?(@picks, entry.key)}
                choice={@choices[entry.key]}
                as={@names[entry.key]}
                focused={@row == entry.key}
                busy={!is_nil(@busy)}
              />
            </ul>
          </section>

          <section :if={@groups.cant != []} aria-labelledby="import-cant-heading">
            <h3 id="import-cant-heading" class={heading()}>
              Can't import <span class="font-normal">{length(@groups.cant)}</span>
            </h3>
            <ul id="import-cant" class={list_box()}>
              <li
                :for={entry <- @groups.cant}
                id={"import-row-" <> PlaybookSharing.dom_id(entry.key)}
                class="flex items-center gap-3 px-3 py-2 text-sm"
              >
                <span class="min-w-0 flex-1">
                  <span class="font-mono">{entry.path || entry.name}</span>
                  <span class="block text-xs text-base-content/55">{entry.error}</span>
                </span>
                <span class="badge badge-sm badge-error badge-soft">Can't read</span>
              </li>
            </ul>
          </section>

          <.up_to_date_list id="import-up-to-date" entries={@groups.up_to_date} />

          <p
            :if={@groups.ready == [] and @groups.look == [] and @groups.cant == []}
            id="import-nothing"
            class="text-sm text-base-content/60"
          >
            Nothing new on GitHub. Everything here matches your library.
          </p>
        </div>
      <% end %>

      <:footer>
        <div class="flex flex-wrap items-center gap-3">
          <p class="min-w-0 flex-1 text-xs text-base-content/60">
            {if @sharing.config != :not_set_up,
              do: "Imported playbooks arrive enabled; starred ones keep their star."}
          </p>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click={close_dialog()}
            disabled={!is_nil(@busy)}
          >
            Cancel
          </button>
          <%= if @sharing.config == :not_set_up do %>
            <button
              type="submit"
              form="sharing-setup-form"
              id="sharing-setup-continue"
              class="btn btn-primary btn-sm"
              disabled={!valid_repo?(@setup_form)}
            >
              Continue
            </button>
          <% else %>
            <button
              type="button"
              id="import-submit"
              class="btn btn-primary btn-sm"
              phx-click="import"
              disabled={@count == 0 or !is_nil(@busy) or @sharing.loading?}
            >
              <span :if={@busy == :import} class="loading loading-spinner loading-xs"></span>
              {cond do
                @busy == :import -> "Importing…"
                @count == 0 -> "Import"
                true -> "Import #{@count}"
              end}
            </button>
          <% end %>
        </div>
      </:footer>
    </.sharing_modal>
    """
  end

  defp import_count(groups, picks, choices) do
    Enum.count(groups.ready, &MapSet.member?(picks, &1.key)) +
      Enum.count(groups.look, &(MapSet.member?(picks, &1.key) and Map.has_key?(choices, &1.key)))
  end

  attr :entry, :map, required: true
  attr :ticked, :boolean, required: true
  attr :choice, :any, required: true
  attr :as, :string, default: nil, doc: "the name a ticked row imports as, when it's a new one"
  attr :focused, :boolean, default: false
  attr :busy, :boolean, default: false

  defp import_row(assigns) do
    entry = assigns.entry
    look? = entry.state in [:both_changed, :name_clash]

    assigns =
      assigns
      |> assign(:dom, PlaybookSharing.dom_id(entry.key))
      |> assign(:look?, look?)
      |> assign(:enabled?, not look? or not is_nil(assigns.choice))

    ~H"""
    <li
      id={"import-row-#{@dom}"}
      data-state={@entry.state}
      class={["flex items-start gap-3 px-3 py-2.5 text-sm", @focused && "bg-primary/5"]}
    >
      <input
        type="checkbox"
        id={"import-tick-#{@dom}"}
        class={[
          "checkbox checkbox-sm checkbox-primary mt-0.5",
          !@enabled? && "opacity-40 cursor-not-allowed"
        ]}
        checked={@ticked and @enabled?}
        disabled={!@enabled? or @busy}
        title={!@enabled? && "Compare first, then choose"}
        phx-click="tick"
        phx-value-key={@entry.key}
        phx-mounted={@focused && JS.focus()}
        aria-label={"Import #{@entry.name}"}
      />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
          <label
            for={"import-tick-#{@dom}"}
            class="font-mono font-medium"
            title={!@enabled? && "Compare first, then choose"}
          >
            {@entry.name}
          </label>
          <span :if={@entry.remote_version} class="text-xs text-base-content/50">
            v{@entry.remote_version}
          </span>
          <span :if={@entry.state == :new} class="badge badge-xs badge-success badge-soft">New</span>
          <span :if={@entry.state == :update} class="badge badge-xs badge-secondary badge-soft">
            Update{PlaybookSharing.versions(@entry.local_version, @entry.remote_version)}
          </span>
          <span :if={@entry.state == :both_changed} class="badge badge-xs badge-warning badge-soft">
            ⚠ Both changed
          </span>
          <span :if={@entry.state == :name_clash} class="badge badge-xs badge-warning badge-soft">
            ⚠ Same name, different
          </span>
        </div>
        <p :if={@entry.description} class="truncate text-xs text-base-content/60">
          {@entry.description}
        </p>
        <p :if={@entry.state == :update && @entry.base_version} class="text-xs text-base-content/60">
          You haven't changed yours since v{@entry.base_version}, so this replaces it.
        </p>
        <p
          :if={@entry.state == :new && (@entry.import_as || (@as && @as != @entry.name))}
          id={"import-as-#{@dom}"}
          class="text-xs text-base-content/60"
        >
          A playbook named <code class="font-mono">{@entry.name}</code>
          is already here, so this imports as <code class="font-mono">{@as || @entry.import_as}</code>.
        </p>
        <p
          :if={@as && @choice && @choice.choice == :keep_both}
          id={"import-as-#{@dom}"}
          class="text-xs text-base-content/60"
        >
          Will import as <code class="font-mono">{@as}</code>.
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-1.5">
        <%= cond do %>
          <% @look? and @choice -> %>
            <span id={"import-choice-#{@dom}"} class="badge badge-sm badge-success badge-soft">
              {if @choice.choice == :keep_both, do: "Keep both", else: "Replace mine"}
            </span>
            <.link
              patch={compare_path(:import, @entry.key)}
              id={"import-compare-#{@dom}"}
              class="btn btn-ghost btn-xs"
            >
              Change
            </.link>
          <% @look? -> %>
            <.link
              patch={compare_path(:import, @entry.key)}
              id={"import-compare-#{@dom}"}
              class="btn btn-outline btn-xs"
            >
              Compare
            </.link>
          <% true -> %>
            <.link
              patch={compare_path(:import, @entry.key)}
              id={"import-compare-#{@dom}"}
              class="btn btn-ghost btn-xs"
            >
              {if @entry.state == :new, do: "View", else: "Compare"}
            </.link>
        <% end %>
      </div>
    </li>
    """
  end

  @doc "`/playbooks?github=import&compare=<key>`"
  def compare_path(mode, key), do: ~p"/playbooks?#{[github: mode, compare: key]}"

  @doc "`/playbooks?github=import&row=<key>`"
  def row_path(mode, key), do: ~p"/playbooks?#{[github: mode, row: key]}"

  # -- Export ---------------------------------------------------------------------------

  @doc """
  The Export dialog: Changed in Canopy (ticks), Can't export, the
  up-to-date count, then the pull request's title and note.
  """
  attr :sharing, :map, required: true
  attr :picks, :any, required: true
  attr :busy, :any, default: nil
  attr :row, :string, default: nil
  attr :stacked, :boolean, default: false
  attr :pr_form, :any, required: true
  attr :pr_branch, :string, default: nil
  attr :setup_form, :any, default: nil
  attr :check, :any, default: nil

  def export_modal(assigns) do
    status = assigns.sharing.status
    groups = PlaybookSharing.export_groups((status && status.entries) || [])
    ticked = Enum.filter(groups.changed, &MapSet.member?(assigns.picks, &1.key))
    title = String.trim(assigns.pr_form[:title].value || "")
    can_push? = status != nil and status.can_push?

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:groups, groups)
      |> assign(:ticked, ticked)
      |> assign(:can_push?, can_push?)
      |> assign(
        :blocked,
        cond do
          ticked == [] -> "Tick at least one playbook"
          title == "" -> "Give the pull request a title"
          !can_push? -> "You can't push to this repo"
          true -> nil
        end
      )

    ~H"""
    <.sharing_modal
      id="github-export-dialog"
      closable={is_nil(@busy) and !@stacked}
      close={close_dialog()}
      busy={!is_nil(@busy)}
    >
      <:header>
        <h2 id="github-export-dialog-title" class="text-lg font-semibold">Export to GitHub</h2>
        <p
          :if={@sharing.config == :not_set_up}
          id="github-export-dialog-sub"
          class="text-sm text-base-content/65"
        >
          Set up sharing once; it's saved in Settings
        </p>
        <div :if={@sharing.config != :not_set_up} id="github-export-dialog-sub">
          <.where_line
            config={@sharing.config}
            status={@status}
            loading={@sharing.loading?}
          />
        </div>
      </:header>

      <%= if @sharing.config == :not_set_up do %>
        <.setup_body form={@setup_form} check={@check} />
      <% else %>
        <.dialog_error sharing={@sharing} />
        <.sharing_error
          :if={@status && !@status.can_push? && is_nil(@sharing.error)}
          id="export-read-only"
          kind={:read_only}
          ctx={%{repo: @sharing.config.repo}}
        />
        <.loading_rows :if={@sharing.loading? and is_nil(@status)} />
        <.empty_folder
          :if={@status && !@status.folder?}
          config={@sharing.config}
          status={@status}
          mode={:export}
        />
        <div
          :if={@status}
          id="export-sections"
          class={["flex flex-col gap-5", @sharing.loading? && "pointer-events-none opacity-60"]}
        >
          <section :if={@groups.changed != []} aria-labelledby="export-changed-heading">
            <h3 id="export-changed-heading" class={heading()}>
              Changed in Canopy <span class="font-normal">{length(@groups.changed)}</span>
            </h3>
            <ul id="export-changed" class={list_box()}>
              <.export_row
                :for={entry <- @groups.changed}
                entry={entry}
                ticked={MapSet.member?(@picks, entry.key)}
                focused={@row == entry.key}
                busy={!is_nil(@busy)}
              />
            </ul>
          </section>

          <section :if={@groups.cant != []} aria-labelledby="export-cant-heading">
            <h3 id="export-cant-heading" class={heading()}>
              Can't export <span class="font-normal">{length(@groups.cant)}</span>
            </h3>
            <ul id="export-cant" class={list_box()}>
              <li
                :for={entry <- @groups.cant}
                id={"export-row-" <> PlaybookSharing.dom_id(entry.key)}
                data-state={entry.state}
                class="flex items-start gap-3 px-3 py-2 text-sm"
              >
                <span class="min-w-0 flex-1 font-mono font-medium">{entry.name}</span>
                <span class="max-w-[60%] text-right text-xs text-base-content/60">
                  <.cant_export_text entry={entry} folder={@sharing.config.folder} />
                </span>
              </li>
            </ul>
          </section>

          <.up_to_date_list
            id="export-up-to-date"
            entries={@groups.up_to_date}
            suffix=" · drafts aren't listed"
          />

          <p
            :if={@groups.changed == [] and @groups.cant == []}
            id="export-nothing"
            class="text-sm text-base-content/60"
          >
            Nothing to export: GitHub has every playbook as it is here.
          </p>

          <.form
            :if={@groups.changed != []}
            for={@pr_form}
            id="export-pr-form"
            phx-change="export_change"
            phx-submit="export"
            class="flex flex-col gap-3"
          >
            <.input
              field={@pr_form[:title]}
              type="text"
              label="Pull request title"
              autocomplete="off"
              phx-debounce="200"
            />
            <.input
              field={@pr_form[:note]}
              type="textarea"
              label="Note (optional)"
              rows="3"
              phx-debounce="300"
            />
          </.form>
        </div>
      <% end %>

      <:footer>
        <div class="flex flex-wrap items-center gap-3">
          <p
            :if={@sharing.config != :not_set_up}
            id="export-branch"
            class="flex min-w-0 flex-1 items-center gap-1.5 text-xs text-base-content/60"
          >
            <.branch_mark class="size-4 shrink-0" />
            <span class="truncate">
              Branch <span class="font-mono">{@pr_branch}</span>
              → <span class="font-mono">{(@status && @status.branch) || "default branch"}</span>
            </span>
          </p>
          <p :if={@sharing.config == :not_set_up} class="flex-1"></p>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click={close_dialog()}
            disabled={!is_nil(@busy)}
          >
            Cancel
          </button>
          <%= if @sharing.config == :not_set_up do %>
            <button
              type="submit"
              form="sharing-setup-form"
              id="sharing-setup-continue"
              class="btn btn-primary btn-sm"
              disabled={!valid_repo?(@setup_form)}
            >
              Continue
            </button>
          <% else %>
            <button
              type="submit"
              form="export-pr-form"
              id="export-submit"
              class="btn btn-primary btn-sm"
              title={@blocked}
              disabled={!is_nil(@blocked) or !is_nil(@busy) or @sharing.loading?}
            >
              <span :if={@busy == :export} class="loading loading-spinner loading-xs"></span>
              <.pr_mark :if={@busy != :export} />
              {if @busy == :export, do: "Opening pull request…", else: "Open pull request"}
            </button>
          <% end %>
        </div>
      </:footer>
    </.sharing_modal>
    """
  end

  attr :entry, :map, required: true
  attr :ticked, :boolean, required: true
  attr :focused, :boolean, default: false
  attr :busy, :boolean, default: false

  defp export_row(assigns) do
    assigns = assign(assigns, :dom, PlaybookSharing.dom_id(assigns.entry.key))

    ~H"""
    <li
      id={"export-row-#{@dom}"}
      data-state={@entry.state}
      class={["flex items-start gap-3 px-3 py-2.5 text-sm", @focused && "bg-primary/5"]}
    >
      <input
        type="checkbox"
        id={"export-tick-#{@dom}"}
        class="checkbox checkbox-sm checkbox-primary mt-0.5"
        checked={@ticked}
        disabled={@busy}
        phx-click="tick"
        phx-value-key={@entry.key}
        phx-mounted={@focused && JS.focus()}
        aria-label={"Export #{@entry.name}"}
      />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
          <label for={"export-tick-#{@dom}"} class="font-mono font-medium">{@entry.name}</label>
          <span :if={@entry.state == :edited} class="badge badge-xs badge-primary badge-soft">
            Edited{PlaybookSharing.versions(@entry.remote_version, @entry.export_version)}
          </span>
          <span :if={@entry.state == :not_on_github} class="badge badge-xs badge-secondary badge-soft">
            Not on GitHub
          </span>
          <span :if={@entry.state == :both_changed} class="badge badge-xs badge-warning badge-soft">
            ⚠ Both changed
          </span>
          <span :if={@entry.state == :name_clash} class="badge badge-xs badge-warning badge-soft">
            ⚠ Same name, different
          </span>
          <span :if={@entry.pr} class="text-xs text-base-content/50">
            in PR #{@entry.pr.number}
          </span>
        </div>
        <p :if={@entry.description} class="truncate text-xs text-base-content/60">
          {@entry.description}
        </p>
        <p :if={@entry.state == :both_changed} class="text-xs text-base-content/60">
          GitHub has a newer v{@entry.remote_version} you haven't seen. Exporting replaces it in the PR.
        </p>
        <p :if={@entry.state == :name_clash} class="text-xs text-base-content/60">
          A different playbook with this name is on GitHub.
        </p>
      </div>
      <.link
        :if={@entry.state in [:both_changed, :name_clash]}
        patch={compare_path(:export, @entry.key)}
        id={"export-compare-#{@dom}"}
        class="btn btn-ghost btn-xs shrink-0"
      >
        Compare first
      </.link>
    </li>
    """
  end

  attr :entry, :map, required: true
  attr :folder, :string, default: nil

  defp cant_export_text(%{entry: %{state: :update}} = assigns) do
    ~H"""
    <span class="font-medium text-base-content/75">GitHub is newer (v{@entry.remote_version})</span>
    · Import the update first.
    """
  end

  defp cant_export_text(%{entry: %{state: :name_taken}} = assigns) do
    assigns =
      assign(
        assigns,
        :path,
        Canopy.Playbooks.Sharing.Text.file_path(assigns.folder || "", assigns.entry.name)
      )

    ~H"""
    <span class="font-medium text-base-content/75">Name taken on GitHub</span>
    · <code class="font-mono">{@path}</code>
    belongs to another playbook there. Rename yours to export it.
    """
  end

  defp cant_export_text(%{entry: %{error: {:too_long, _}}} = assigns) do
    ~H"""
    <span class="font-medium text-base-content/75">Too long for GitHub</span>
    · {PlaybookSharing.export_error(@entry.error)} Shorten it first.
    """
  end

  defp cant_export_text(assigns) do
    ~H"""
    <span class="font-medium text-base-content/75">Can't export</span>
    · {PlaybookSharing.export_error(@entry.error)}
    """
  end

  # -- Shared dialog pieces -----------------------------------------------------------

  attr :sharing, :map, required: true

  defp dialog_error(assigns) do
    ~H"""
    <.sharing_error
      :if={match?({_, _}, @sharing.error)}
      id="sharing-error"
      kind={elem(@sharing.error, 0)}
      raw={elem(@sharing.error, 1)}
      ctx={error_ctx(@sharing)}
      retry
    />
    """
  end

  defp error_ctx(%{config: config, status: status}) do
    base = if is_map(config), do: %{repo: config.repo, folder: config.folder}, else: %{}

    if status,
      do: Map.merge(base, %{account: status.account, branch: status.branch}),
      else: base
  end

  attr :config, :any, required: true
  attr :status, :map, required: true
  attr :mode, :atom, default: :import

  defp empty_folder(assigns) do
    ~H"""
    <.sharing_error
      id="sharing-empty-folder"
      kind={:empty_folder}
      ctx={%{folder: @config.folder, branch: @status.branch, mode: @mode}}
    />
    """
  end

  defp loading_rows(assigns) do
    ~H"""
    <div id="sharing-loading" class="flex flex-col gap-2" role="status" aria-label="Checking GitHub">
      <div class="skeleton h-11 w-full"></div>
      <div class="skeleton h-11 w-full"></div>
      <div class="skeleton h-11 w-full"></div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :suffix, :string, default: ""

  defp up_to_date_list(assigns) do
    ~H"""
    <details :if={@entries != []} id={@id} class="text-sm text-base-content/60">
      <summary class="cursor-pointer select-none">
        {length(@entries)} up to date{@suffix}
      </summary>
      <ul class="mt-2 flex flex-wrap gap-x-3 gap-y-1 pl-4">
        <li :for={entry <- @entries} class="font-mono text-xs">
          {entry.name}
          <a
            :if={entry.state == :in_pr && entry.pr}
            href={entry.pr.url}
            target="_blank"
            rel="noopener"
            class="link font-sans"
          >
            In PR #{entry.pr.number}
          </a>
        </li>
      </ul>
    </details>
    """
  end

  defp heading,
    do:
      "mb-2 flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/55"

  defp list_box,
    do: "rounded-box border border-base-300 bg-base-200 divide-y divide-base-300"

  # -- Compare / View -------------------------------------------------------------------

  @doc """
  Compare, over the dialog it was opened from: what changed and who changed
  it, the steps side by side, the changed instructions word by word, and
  the file diff. For a playbook only on GitHub (`local: nil`), View: the
  playbook as it will arrive, rendered, in one column.
  """
  attr :compare, :map, required: true
  attr :entry, :any, default: nil
  attr :copy_as, :string, default: nil, doc: "the name Keep both would import GitHub's copy as"

  def compare_dialog(assigns) do
    comparison = assigns.compare.comparison
    entry = assigns.entry || (comparison && comparison.entry)
    view? = comparison != nil and comparison.local == nil

    assigns =
      assigns
      |> assign(:comparison, comparison)
      |> assign(:entry, entry)
      |> assign(:view?, view?)
      |> assign(:from, assigns.compare.from)
      |> assign(:ready?, entry != nil and entry.state in [:new, :update])
      |> assign(
        :unreadable?,
        (entry != nil and entry.state == :unreadable) or
          match?({:unreadable, _}, assigns.compare.error)
      )

    ~H"""
    <.sharing_modal
      id="compare-dialog"
      closable
      close={back(@from, @compare.key)}
      layer="z-[60]"
      width={
        if @view? or (@ready? and is_nil(@comparison)), do: "max-w-[720px]", else: "max-w-[960px]"
      }
    >
      <:header>
        <h2 id="compare-dialog-title" class="flex items-baseline gap-2 text-lg font-semibold">
          <%= if @unreadable? do %>
            <span class="min-w-0 break-all font-mono">
              {(@entry && (@entry.path || @entry.name)) || @compare.key}
            </span>
          <% else %>
            <span class="font-mono">{(@entry && @entry.name) || "playbook"}</span>
            <span class="text-base font-normal text-base-content/60">
              {cond do
                @view? -> "on GitHub" <> PlaybookSharing.versions(nil, @comparison.remote.version)
                true -> "· compare"
              end}
            </span>
          <% end %>
        </h2>
        <p id="compare-dialog-sub" class="text-sm text-base-content/65">
          {if !@unreadable?, do: compare_subtitle(@entry, @comparison)}
        </p>
      </:header>

      <%= cond do %>
        <% @compare.error -> %>
          <.sharing_error
            id="compare-error"
            kind={elem(@compare.error, 0)}
            raw={elem(@compare.error, 1)}
            ctx={%{check: "close this and Compare again"}}
          />
        <% is_nil(@comparison) -> %>
          <div id="compare-loading" class="flex flex-col gap-3" role="status" aria-label="Loading">
            <div class="skeleton h-16 w-full"></div>
            <div class="skeleton h-40 w-full"></div>
          </div>
        <% @view? -> %>
          <.view_body definition={@comparison.remote.definition} />
        <% true -> %>
          <.compare_body comparison={@comparison} />
      <% end %>

      <:footer>
        <.compare_footer
          entry={if !@unreadable?, do: @entry}
          from={@from}
          key={@compare.key}
          ready?={@ready?}
          copy_as={@copy_as}
          locked={@compare.loading? or @compare.error != nil}
        />
      </:footer>
    </.sharing_modal>
    """
  end

  defp back(from, key),
    do:
      JS.patch(row_path(from, key))
      |> JS.focus(to: "##{from}-tick-#{PlaybookSharing.dom_id(key)}")

  defp compare_subtitle(nil, _comparison), do: ""

  defp compare_subtitle(entry, comparison) do
    base = entry.base_version || (comparison && comparison[:base_version])

    case entry.state do
      :both_changed when is_integer(base) ->
        "Both changed since v#{base}, the version you last synced"

      :both_changed ->
        "Both changed since you last synced"

      :name_clash ->
        "Yours wasn't imported from this repo"

      :update ->
        "GitHub has v#{entry.remote_version}; yours is v#{entry.local_version}"

      :new ->
        case comparison && comparison.remote do
          %{} = side -> by_at(side)
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp by_at(%{by: by, at: at}) do
    [by && "by #{by}", at && Canopy.Schedules.relative(at)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  attr :definition, :any, required: true

  defp view_body(assigns) do
    guidance = Definition.guidance(assigns.definition)
    assigns = assign(assigns, :guidance, guidance)

    ~H"""
    <div id="compare-view" class="flex flex-col gap-5">
      <p :if={@definition.description} id="view-description" class="text-sm">
        {@definition.description}
      </p>
      <section :if={@guidance != ""}>
        <h3 class={heading()}>Ground rules for every step</h3>
        <div id="view-guidance" class="message-body text-sm">
          {raw(CanopyWeb.Markdown.to_html(@guidance, hardbreaks: false))}
        </div>
      </section>
      <section>
        <h3 class={heading()}>Steps <span class="font-normal">{length(@definition.steps)}</span></h3>
        <ol id="view-steps" class="flex flex-col gap-3">
          <li :for={{step, n} <- Enum.with_index(@definition.steps, 1)} id={"view-step-#{step.id}"}>
            <.compare_step step={step} n={n} definition={@definition} />
            <div
              :if={Definition.step_section(@definition, step.id)}
              class="message-body mt-1.5 pl-3 text-sm"
            >
              {raw(
                CanopyWeb.Markdown.to_html(Definition.step_section(@definition, step.id),
                  hardbreaks: false
                )
              )}
            </div>
          </li>
        </ol>
      </section>
    </div>
    """
  end

  attr :comparison, :map, required: true

  defp compare_body(assigns) do
    ~H"""
    <div class="flex flex-col gap-5">
      <ul
        :if={@comparison.changes != []}
        id="compare-changes"
        class="flex flex-col gap-1 rounded-box border border-base-300 bg-base-200 p-3 text-sm"
      >
        <li :for={change <- @comparison.changes} class="flex items-baseline gap-2">
          <span class={["w-3 shrink-0 text-center font-mono font-semibold", change_tone(change.kind)]}>
            {change_sign(change.kind)}
          </span>
          <span class="min-w-0 flex-1">{change_html(change.text, change.step)}</span>
          <span
            :if={change.by}
            class="shrink-0 rounded-full bg-base-100 px-1.5 text-[11px] text-base-content/55"
          >
            {by_label(change.by)}
          </span>
        </li>
      </ul>

      <div id="compare-steps" class="grid gap-x-4 gap-y-2 md:grid-cols-2">
        <p class="text-xs font-semibold text-base-content/65">
          Yours{PlaybookSharing.versions(nil, @comparison.local.version)}{local_when(
            @comparison.local
          )}
        </p>
        <p class="flex items-center gap-1 text-xs font-semibold text-base-content/65">
          <.github_mark class="size-3.5" />
          GitHub{PlaybookSharing.versions(nil, @comparison.remote.version)}{remote_when(
            @comparison.remote
          )}
        </p>
        <%= for {{local, remote, mark}, i} <- Enum.with_index(@comparison.rows) do %>
          <.compare_step
            id={"compare-local-#{i}"}
            step={local}
            n={local && step_number(@comparison.local.definition, local)}
            mark={local && side_mark(mark, :local)}
            definition={@comparison.local.definition}
            side="Yours"
          />
          <.compare_step
            id={"compare-remote-#{i}"}
            step={remote}
            n={remote && step_number(@comparison.remote.definition, remote)}
            mark={remote && side_mark(mark, :remote)}
            definition={@comparison.remote.definition}
            side="GitHub"
          />
        <% end %>
      </div>

      <div :if={@comparison.instructions != []} id="compare-instructions" class="flex flex-col gap-2">
        <details
          :for={{item, i} <- Enum.with_index(@comparison.instructions)}
          id={"compare-instructions-#{i}"}
          open={i == 0}
          class="rounded-box border border-base-300"
        >
          <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium">
            {if item.step, do: "#{item.step} · instructions", else: "Guidance"}
          </summary>
          <div class="grid gap-3 border-t border-base-300 p-3 md:grid-cols-2">
            <div>
              <p class="mb-1 text-xs font-semibold text-base-content/65">Yours</p>
              <div class="whitespace-pre-wrap text-[13px] leading-relaxed" phx-no-format>{segs_html(item.local)}</div>
            </div>
            <div>
              <p class="mb-1 flex items-center gap-1 text-xs font-semibold text-base-content/65">
                <.github_mark class="size-3.5" /> GitHub
              </p>
              <div class="whitespace-pre-wrap text-[13px] leading-relaxed" phx-no-format>{segs_html(item.remote)}</div>
            </div>
          </div>
        </details>
      </div>

      <details id="compare-file-diff" class="rounded-box border border-base-300">
        <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium">
          View file diff
        </summary>
        <pre
          class="max-h-80 overflow-auto border-t border-base-300 p-3 font-mono text-xs"
          phx-no-format
        >{diff_html(@comparison.file_diff)}</pre>
      </details>
    </div>
    """
  end

  attr :entry, :any, required: true
  attr :from, :atom, required: true
  attr :key, :string, required: true
  attr :ready?, :boolean, required: true
  attr :copy_as, :string, default: nil
  attr :locked, :boolean, default: false, doc: "loading or failed: the choices wait for the diff"

  # no entry (or a file that can't be read): Close only. Until the diff is
  # shown, the choices are disabled; Skip and Close never are.
  defp compare_footer(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@entry) -> %>
        <div class="flex justify-end">
          <button
            type="button"
            id="compare-close"
            class="btn btn-ghost btn-sm"
            phx-click={back(@from, @key)}
          >
            Close
          </button>
        </div>
      <% @from == :export -> %>
        <div class={actions()}>
          <p class="min-w-0 text-xs text-base-content/60 md:flex-1">
            {if @entry.state == :name_clash,
              do: "This is a different playbook with the same name. The PR replaces it.",
              else:
                "The PR replaces GitHub's v#{@entry.remote_version} with yours. Their changes are listed above."}
          </p>
          <button
            type="button"
            id="compare-close"
            class="btn btn-ghost btn-sm"
            phx-click={back(@from, @key)}
          >
            Close
          </button>
          <button
            :if={@entry.export_version}
            type="button"
            id="compare-export"
            class="btn btn-primary btn-sm"
            disabled={@locked}
            title={@locked && locked_title()}
            phx-click={JS.push("compare_pick", value: %{key: @key, choice: "export"})}
          >
            Export mine as v{@entry.export_version}
          </button>
        </div>
      <% @ready? -> %>
        <div class={actions()}>
          <button
            type="button"
            id="compare-close"
            class="btn btn-ghost btn-sm"
            phx-click={back(@from, @key)}
          >
            Close
          </button>
          <span class="hidden md:block md:flex-1"></span>
          <button
            type="button"
            id="compare-import-this"
            class="btn btn-primary btn-sm"
            disabled={@locked}
            title={@locked && locked_title()}
            phx-click={JS.push("compare_pick", value: %{key: @key, choice: "tick"})}
          >
            Import this
          </button>
        </div>
      <% true -> %>
        <div class="flex flex-col gap-2">
          <div class={actions()}>
            <button
              type="button"
              id="compare-skip"
              class="btn btn-ghost btn-sm"
              phx-click={JS.push("compare_pick", value: %{key: @key, choice: "skip"})}
            >
              Skip
            </button>
            <span class="hidden md:block md:flex-1"></span>
            <%= if @entry.state == :name_clash do %>
              <button
                type="button"
                id="compare-take"
                class="btn btn-soft btn-sm"
                disabled={@locked}
                title={@locked && locked_title()}
                phx-click={JS.push("compare_pick", value: %{key: @key, choice: "take"})}
              >
                Replace mine
              </button>
              <button
                type="button"
                id="compare-keep-both"
                class="btn btn-primary btn-sm"
                disabled={@locked}
                title={@locked && locked_title()}
                phx-click={JS.push("compare_pick", value: %{key: @key, choice: "keep_both"})}
              >
                Keep both
              </button>
            <% else %>
              <button
                type="button"
                id="compare-keep-both"
                class="btn btn-soft btn-sm"
                disabled={@locked}
                title={@locked && locked_title()}
                phx-click={JS.push("compare_pick", value: %{key: @key, choice: "keep_both"})}
              >
                Keep both
              </button>
              <button
                type="button"
                id="compare-take"
                class="btn btn-primary btn-sm"
                disabled={@locked}
                title={@locked && locked_title()}
                phx-click={JS.push("compare_pick", value: %{key: @key, choice: "take"})}
              >
                Replace mine{if @entry.remote_version, do: " with v#{@entry.remote_version}"}
              </button>
            <% end %>
          </div>
          <p class="text-xs text-base-content/55">
            Keep both adds GitHub's copy as <code class="whitespace-nowrap font-mono">{@copy_as || "#{@entry.name}-2"}</code>, which follows the file from now on. Yours stays as it is and is no longer linked.
          </p>
        </div>
    <% end %>
    """
  end

  # below md the buttons stack full width, primary first (the DOM order is
  # the desktop one, least to most)
  defp actions,
    do:
      "flex flex-col-reverse gap-2 md:flex-row md:flex-wrap md:items-center md:gap-3 [&>.btn]:w-full md:[&>.btn]:w-auto"

  defp locked_title, do: "Loading the comparison…"

  defp step_number(definition, step),
    do: Enum.find_index(definition.steps, &(&1.id == step.id)) |> then(&(&1 && &1 + 1))

  # a row's kind, as each side shows it: added on GitHub's side, removed on yours
  defp side_mark(:same, _side), do: nil
  defp side_mark(mark, _side), do: mark

  defp local_when(%{at: nil}), do: ""
  defp local_when(%{at: at}), do: " · edited #{Calendar.strftime(at, "%b %-d")}"

  defp remote_when(side) do
    case by_at(side) do
      "" -> ""
      text -> " · " <> text
    end
  end

  defp change_sign(:added), do: "+"
  defp change_sign(:removed), do: "−"
  defp change_sign(_), do: "~"

  defp change_tone(:added), do: "text-success"
  defp change_tone(:removed), do: "text-error"
  defp change_tone(_), do: "text-warning"

  defp by_label(:remote), do: "GitHub"
  defp by_label(:local), do: "you"
  defp by_label(:both), do: "both"

  # the sentence with its step's title (first match) in <strong>; escaped
  # on both sides, never raw
  defp change_html(text, step) when is_binary(step) and step != "" do
    case String.split(text, step, parts: 2) do
      [before, rest] ->
        {:safe, [esc(before), "<strong>", esc(step), "</strong>", esc(rest)]}

      _ ->
        text
    end
  end

  defp change_html(text, _step), do: text

  defp segs_html(segs) do
    {:safe,
     Enum.map(segs, fn
       {:ins, text} ->
         [~s(<mark class="rounded-sm bg-warning/25 text-inherit">), esc(text), "</mark>"]

       {_eq, text} ->
         esc(text)
     end)}
  end

  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # each line a <span> coloured by its first character
  defp diff_html(diff) do
    {:safe,
     diff
     |> String.split("\n")
     |> Enum.map(fn line ->
       case diff_tone(line) do
         nil -> [esc(line), "\n"]
         tone -> [~s(<span class="), tone, ~s(">), esc(line), "</span>\n"]
       end
     end)}
  end

  defp diff_tone("+" <> _), do: "text-success"
  defp diff_tone("-" <> _), do: "text-error"
  defp diff_tone("@" <> _), do: "text-base-content/50"
  defp diff_tone(_), do: nil

  # -- Setup and Settings -------------------------------------------------------------

  @doc """
  Repository, Branch and Folder, for the first-run setup and the Settings
  panel. `form` is a `Sharing.change_config/1` form (`repo`, `branch`, `folder`).
  """
  attr :form, :any, required: true
  attr :on_repo_blur, :string, default: nil, doc: "event pushed when Repository loses focus"
  attr :repo_help, :string, default: "owner/name, or paste the repo URL"

  def setup_fields(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_10rem]">
      <div>
        <label for="sharing-repo" class="mb-1 block text-sm font-medium">Repository</label>
        <label class="input w-full">
          <.github_mark class="size-4 text-base-content/50" />
          <input
            type="text"
            id="sharing-repo"
            name={@form[:repo].name}
            value={@form[:repo].value}
            placeholder="owner/name"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="100"
            phx-blur={@on_repo_blur}
            phx-hook=".RepoUrl"
            aria-describedby="sharing-repo-help"
          />
        </label>
        <p id="sharing-repo-help" class="mt-1 text-xs text-base-content/55">{@repo_help}</p>
        <.field_errors field={@form[:repo]} />
      </div>
      <div>
        <label for="sharing-branch" class="mb-1 block text-sm font-medium">Branch</label>
        <input
          type="text"
          id="sharing-branch"
          name={@form[:branch].name}
          value={@form[:branch].value}
          placeholder="default branch"
          autocomplete="off"
          spellcheck="false"
          phx-debounce="300"
          class="input w-full"
        />
        <p class="mt-1 text-xs text-base-content/55">PRs merge into it</p>
        <.field_errors field={@form[:branch]} />
      </div>
    </div>
    <div>
      <label for="sharing-folder" class="mb-1 block text-sm font-medium">Folder</label>
      <input
        type="text"
        id="sharing-folder"
        name={@form[:folder].name}
        value={@form[:folder].value}
        placeholder="repository root"
        autocomplete="off"
        spellcheck="false"
        phx-debounce="300"
        class="input w-full sm:w-80"
      />
      <p class="mt-1 text-xs text-base-content/55">
        One Markdown file per playbook, named after it. Created by the first export.
      </p>
      <.field_errors field={@form[:folder]} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RepoUrl">
      // A github.com address still in Repository when it loses focus fills
      // the three fields here: after a quick paste and Tab, focus is in Branch
      // before the server's fill (PlaybookSharing.fill_from_url/1) arrives,
      // and LiveView never patches a focused input. Mirrors
      // Sharing.parse_location/1; the server parses and checks it again.
      export default {
        mounted() {
          this.el.addEventListener("blur", () => {
            if (!/github\.com/i.test(this.el.value)) return
            const path = this.el.value.trim()
              .replace(/[?#].*$/, "")
              .replace(/^https?:\/\//i, "")
              .replace(/^(www\.)?github\.com\//i, "")
              .replace(/^\/+|\/+$/g, "")
            const [owner, name, ...rest] = path.split("/")
            // an SSH address (git@github.com:o/r) or anything else that isn't
            // owner/name is left as typed, as the server leaves it
            const part = /^[A-Za-z0-9_.-]+$/
            if (!part.test(owner || "") || !part.test(name || "")) return
            if (rest.length > 0 && !(rest[0] === "tree" && rest[1])) return

            const set = (id, value) => {
              const input = document.getElementById(id)
              if (input) input.value = value
            }
            this.el.value = `${owner}/${name.replace(/\.git$/, "")}`
            if (rest[1]) set("sharing-branch", rest[1])
            if (rest.length > 2) set("sharing-folder", rest.slice(2).join("/"))
          })
        },
      }
    </script>
    """
  end

  attr :field, :any, required: true

  defp field_errors(assigns) do
    assigns =
      assign(
        assigns,
        :errors,
        if(Phoenix.Component.used_input?(assigns.field),
          do: Enum.map(assigns.field.errors, &translate_error/1),
          else: []
        )
      )

    ~H"""
    <p :for={msg <- @errors} class="mt-1 flex items-center gap-1 text-xs text-error">
      <.icon name="hero-exclamation-circle-mini" class="size-4" /> {msg}
    </p>
    """
  end

  attr :form, :any, required: true
  attr :check, :any, default: nil

  defp setup_body(assigns) do
    ~H"""
    <.form
      for={@form}
      id="sharing-setup-form"
      phx-change="setup_change"
      phx-submit="setup_save"
      class="flex flex-col gap-3"
    >
      <%!-- a pasted URL fills Branch and Folder while focus is still in
      Repository (LiveView won't overwrite the focused field); the check
      waits for Repository to lose focus --%>
      <.setup_fields form={@form} on_repo_blur="setup_check" />
      <div id="sharing-check-result" role="status">
        <.check_result check={@check} />
      </div>
    </.form>
    """
  end

  @doc "Whether the form's repository is `owner/name`."
  def valid_repo?(nil), do: false
  def valid_repo?(form), do: Canopy.GitHub.valid_repo?(String.trim(form[:repo].value || ""))

  @doc """
  The result of `Sharing.check/1`: checking, the green line (can push), the
  amber one (import only), or the error box.
  """
  attr :check, :any, default: nil
  attr :repo, :string, default: nil
  attr :check_label, :string, default: nil, doc: "the button the error copy names"

  def check_result(assigns) do
    ~H"""
    <%= case @check do %>
      <% nil -> %>
      <% :checking -> %>
        <p class="flex items-center gap-1.5 text-sm text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span> Checking…
        </p>
      <% {:ok, %{can_push?: true} = result} -> %>
        <p id="sharing-check-ok" class="flex items-center gap-1.5 text-sm text-success">
          <.icon name="hero-check-circle-mini" class="size-4" />
          Connected as {result.account} · can push · {playbooks_count(result)}
        </p>
      <% {:ok, result} -> %>
        <p id="sharing-check-ok" class="flex items-center gap-1.5 text-sm text-warning">
          <.icon name="hero-exclamation-triangle-mini" class="size-4" />
          Connected as {result.account} · import only · {playbooks_count(result)}
        </p>
      <% {:error, {kind, raw}} -> %>
        <.sharing_error
          id="sharing-check-error"
          kind={kind}
          raw={raw}
          ctx={%{repo: @repo, check: @check_label}}
        />
      <% {:error, other} -> %>
        <.sharing_error id="sharing-check-error" kind={:gh_failed} raw={inspect(other)} />
    <% end %>
    """
  end

  defp playbooks_count(%{folder?: false}), do: "no folder yet"
  defp playbooks_count(%{count: 1}), do: "1 playbook"
  defp playbooks_count(%{count: n}), do: "#{n} playbooks"

  # -- Error box and toast ------------------------------------------------------------

  @doc """
  An error box: an icon and the lead in the tone's colour, gh's own text in
  mono, then what to do. `retry` adds Check again (`sharing_retry`), except
  where reading again wouldn't help (`:pr_failed`: Open pull request is the
  retry).
  """
  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :raw, :string, default: nil
  attr :ctx, :map, default: %{}
  attr :retry, :boolean, default: false

  def sharing_error(assigns) do
    case PlaybookSharing.error_copy(assigns.kind, assigns.ctx) do
      nil ->
        ~H""

      {tone, lead, next} ->
        assigns = assign(assigns, tone: tone, lead: lead, next: next)

        ~H"""
        <div
          id={@id}
          data-kind={@kind}
          role={if @tone == :error, do: "alert", else: "status"}
          class={[
            "mb-4 flex gap-3 rounded-box border px-4 py-3 text-sm",
            @tone == :error && "border-error/40 bg-error/5",
            @tone == :warning && "border-warning/40 bg-warning/5",
            @tone == :info && "border-info/40 bg-info/5"
          ]}
        >
          <.icon
            name={
              case @tone do
                :error -> "hero-exclamation-circle-mini"
                :warning -> "hero-exclamation-triangle-mini"
                :info -> "hero-information-circle-mini"
              end
            }
            class={[
              "mt-0.5 size-4 shrink-0",
              @tone == :error && "text-error",
              @tone == :warning && "text-warning",
              @tone == :info && "text-info"
            ]}
          />
          <div class="min-w-0 flex-1">
            <p class={[
              "font-medium",
              @tone == :error && "text-error",
              @tone == :warning && "text-warning",
              @tone == :info && "text-info"
            ]}>
              {@lead}
            </p>
            <p
              :if={@raw && @raw != ""}
              class="mt-1 break-words font-mono text-xs text-base-content/70"
            >
              {@raw}
            </p>
            <p class="mt-1">{code_html(@next)}</p>
          </div>
          <button
            :if={@retry && @kind not in [:read_only, :stale, :pr_failed]}
            type="button"
            id={"#{@id}-retry"}
            class="btn btn-ghost btn-xs shrink-0 self-start"
            phx-click="sharing_retry"
          >
            Check again
          </button>
        </div>
        """
    end
  end

  # `text with `code`` → the code in <code>, escaped either side
  defp code_html(text) do
    {:safe,
     text
     |> String.split("`")
     |> Enum.with_index()
     |> Enum.map(fn
       {part, i} when rem(i, 2) == 1 -> ["<code class=\"font-mono\">", esc(part), "</code>"]
       {part, _} -> esc(part)
     end)}
  end

  @doc "After an export: the pull request, its link, and what the library shows until it merges."
  attr :toast, :map, required: true

  def pr_toast(assigns) do
    ~H"""
    <div
      id="pr-toast"
      role="status"
      class="fixed bottom-6 left-1/2 z-40 flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-start gap-3 rounded-2xl bg-neutral px-4 py-3 text-sm text-neutral-content shadow-lg"
    >
      <.icon name="hero-check-circle-mini" class="mt-0.5 size-4 shrink-0 text-success" />
      <div class="min-w-0">
        <p class="font-medium">Opened PR #{@toast.number} on {@toast.repo}</p>
        <p class="text-xs opacity-80">
          {if @toast.count == 1,
            do: "1 playbook. It shows",
            else: "#{@toast.count} playbooks. They show"} In PR #{@toast.number} until it's merged.
        </p>
        <p :if={@toast[:branch]} id="pr-toast-branch" class="truncate text-xs opacity-60">
          Branch <span class="font-mono">{@toast.branch}</span>
        </p>
      </div>
      <a
        href={@toast.url}
        id="pr-toast-link"
        target="_blank"
        rel="noopener"
        class="flex shrink-0 items-center gap-1 font-semibold underline"
      >
        <.pr_mark class="size-3.5" /> View
      </a>
      <button
        type="button"
        class="shrink-0 opacity-60 hover:opacity-100"
        phx-click="dismiss_pr_toast"
        aria-label="Dismiss"
      >
        ×
      </button>
    </div>
    """
  end
end
