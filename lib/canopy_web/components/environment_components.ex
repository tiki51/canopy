defmodule CanopyWeb.EnvironmentComponents do
  @moduledoc """
  The Settings page's Environment section (`CanopyWeb.SettingsLive`): the
  seeder's result, the reset row, the reset modal and the banner a reset
  leaves behind. The data comes from `Canopy.Environment`; the page owns the
  assigns and events, these only render them.

  The modal's states are `:confirm` (counts and the typed phrase),
  `:running` (locked: no Cancel, no Esc, no backdrop) and `:failed` (nothing
  was deleted; Try again). A reset that deleted something reloads every tab
  onto `/settings?reset=<id>` (`CanopyWeb.Nav`), where `reset_result/1` says
  how it went.
  """
  use Phoenix.Component

  import CanopyWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias CanopyWeb.TimelineComponents

  @steps [
    stopping: "Stopping agents",
    backing_up: "Backing up the database",
    clearing: "Clearing",
    seeding: "Creating starters"
  ]

  @doc "What a refused runtime action says while a reset runs."
  def resetting_message, do: "Canopy is resetting. Try again when it finishes."

  @doc "The name of a reset step, as the modal shows it."
  def step_label(step), do: Keyword.get(@steps, step, to_string(step))

  @doc "A failure before anything was deleted, in one sentence (the modal, or a flash)."
  def failed_sentence(%{step: step, reason: reason}),
    do: "#{step_label(step)} failed: #{sentence(reason)} Nothing was deleted."

  @doc "True while the modal is locked on a running reset."
  def running?(%{state: :running}), do: true
  def running?(_reset), do: false

  # -- Seeder ------------------------------------------------------------------

  attr :seed, :any, required: true, doc: "`{:ok, report, at}` or `{:error, reason, report, at}`"

  @doc "The seeder's result under its row; it stays until the page is left."
  def seed_result(%{seed: {:ok, report, at}} = assigns) do
    assigns =
      assign(assigns,
        report: report,
        at: at,
        created: length(report.created),
        existing: length(report.existing),
        skipped: report.skipped
      )

    ~H"""
    <div
      :if={@created == 0}
      id="seed-result"
      role="status"
      class="mt-3 rounded-lg border border-base-300 bg-base-100 px-3 py-2.5 text-sm"
    >
      <p :if={@skipped == []}>Nothing to add. All {@existing} starters already exist.</p>
      <p :if={@skipped != []}>Nothing added. {@existing} starters already exist.</p>
      <.seed_skipped items={@skipped} />
    </div>
    <div
      :if={@created > 0}
      id="seed-result"
      role="status"
      class="mt-3 rounded-lg border border-success/30 bg-success/5 px-3 py-2.5 text-sm"
    >
      <p>
        <span class="text-success">✓</span>
        <strong class="font-medium">Created {@created}</strong> · {@existing} already existed
        · <time class="text-xs text-base-content/60" title={DateTime.to_iso8601(@at)}>just now</time>
      </p>
      <ul class="mt-1.5 flex flex-wrap gap-1.5" aria-label="Created">
        <li :for={item <- @report.created} class="badge badge-soft badge-success badge-sm">
          {item_label(item)}
        </li>
      </ul>
      <details class="mt-2">
        <summary class="cursor-pointer text-xs text-base-content/70">
          Show all {@created + @existing}
        </summary>
        <.seed_details report={@report} />
      </details>
      <.seed_skipped items={@skipped} />
    </div>
    """
  end

  def seed_result(%{seed: {:error, reason, _report, _at}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <div id="seed-result" role="status" class="alert alert-soft alert-error mt-3 text-sm">
      <.icon name="hero-x-circle-mini" class="size-4 shrink-0" />
      <span class="min-w-0 [overflow-wrap:anywhere]">
        The seeder stopped: {sentence(@reason)} Anything created before that is kept.
      </span>
    </div>
    """
  end

  attr :items, :list, required: true

  # Only starter teams are skipped: when an agent holds the team's name, or
  # none of its agents exist.
  defp seed_skipped(assigns) do
    ~H"""
    <p :if={@items != []} id="seed-skipped" class="mt-2 text-xs text-base-content/70">
      Not created: {@items |> Enum.map(&item_label/1) |> Enum.join(", ")} (the name is taken, or none of the team's agents exist).
    </p>
    """
  end

  attr :report, :map, required: true

  defp seed_details(assigns) do
    ~H"""
    <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-xs">
      <%= for {kind, label} <- [agent: "Agents", team: "Teams", playbook: "Playbooks"] do %>
        <dt class="text-base-content/60">{label}</dt>
        <dd>{kind_line(@report, kind)}</dd>
      <% end %>
      <dt class="text-base-content/60">Cost auditor</dt>
      <dd>
        <%= case @report.cost_auditor do %>
          <% {:assigned, name} -> %>
            @{name} <span class="text-success">assigned</span>
          <% {:unchanged, name} -> %>
            @{name}
          <% _ -> %>
            <span class="text-base-content/60">none</span>
        <% end %>
      </dd>
    </dl>
    """
  end

  # "@finops created · @backend, @frontend exist"
  defp kind_line(report, kind) do
    created = names(report.created, kind)
    existing = names(report.existing, kind)

    assigns = %{created: created, existing: existing}

    ~H"""
    <span :if={@created != []}>
      {Enum.join(@created, ", ")} <span class="text-success">created</span>
    </span>
    <span :if={@created != [] and @existing != []}>·</span>
    <span :if={@existing != []}>
      {Enum.join(@existing, ", ")} {if length(@existing) == 1, do: "exists", else: "exist"}
    </span>
    <span :if={@created == [] and @existing == []} class="text-base-content/60">none</span>
    """
  end

  defp names(items, kind), do: for(%{kind: ^kind} = item <- items, do: item_name(item))

  defp item_name(%{kind: :playbook, name: name}), do: name
  defp item_name(%{name: name}), do: "@" <> name

  defp item_label(%{kind: kind} = item), do: "#{kind} #{item_name(item)}"

  # -- Reset row and banner ----------------------------------------------------

  attr :disabled, :boolean, default: false

  @doc "The red-outlined row whose button opens the modal."
  def reset_row(assigns) do
    ~H"""
    <div class="flex items-start gap-4 rounded-lg border border-error/30 bg-error/5 p-3">
      <div class="min-w-0 flex-1">
        <h3 class="text-sm font-medium text-error">Reset from scratch</h3>
        <p class="mt-0.5 text-xs text-base-content/70">
          Deletes every channel, message, agent and their history, then runs the seeder. Your settings, display name and repositories stay. A copy of the database is saved first.
        </p>
      </div>
      <button
        type="button"
        id="open-reset"
        class="btn btn-outline btn-error btn-sm shrink-0"
        phx-click="open_reset"
        disabled={@disabled}
      >
        Reset…
      </button>
    </div>
    """
  end

  attr :result, :map, required: true, doc: "`Canopy.Environment.last_reset/0`"
  attr :files_dir, :string, required: true
  slot :copy, doc: "the copy button for `#reset-backup-path`"

  @doc """
  The banner after a reset: done, cleared but the seeder stopped, or reset
  but some shared files stayed.
  """
  def reset_result(%{result: %{status: :done}} = assigns) do
    ~H"""
    <div
      id="reset-result"
      tabindex="-1"
      phx-mounted={JS.focus()}
      role="status"
      class="rounded-lg border border-success/30 bg-success/5 px-3 py-2.5 text-sm outline-none"
    >
      <p>
        <span class="text-success">✓</span>
        <strong class="font-medium">Canopy was reset</strong>
        <span class="text-xs text-base-content/60">· {TimelineComponents.short_time(@result.at)}</span>
      </p>
      <p class="mt-1">{seed_sentence(@result.seed)}</p>
      <.backup_line path={@result.backup_path} copy={@copy} />
    </div>
    """
  end

  def reset_result(%{result: %{status: :failed, step: :clearing}} = assigns) do
    ~H"""
    <div
      id="reset-result"
      tabindex="-1"
      phx-mounted={JS.focus()}
      role="status"
      class="rounded-lg border border-warning/30 bg-warning/5 px-3 py-2.5 text-sm outline-none"
    >
      <p class="flex items-center gap-1.5">
        <.icon name="hero-exclamation-triangle-mini" class="size-4 text-warning" />
        <strong class="font-medium">Canopy was reset, but some shared files couldn't be deleted.</strong>
        <span class="text-xs text-base-content/60">· {TimelineComponents.short_time(@result.at)}</span>
      </p>
      <p class="mt-1">
        {sentence(@result.reason)} They're in <code class="font-mono text-xs">{@files_dir}</code>
        and can be removed by hand.
      </p>
      <.backup_line path={@result.backup_path} copy={@copy} />
    </div>
    """
  end

  def reset_result(%{result: %{status: :failed}} = assigns) do
    ~H"""
    <div
      id="reset-result"
      role="alert"
      tabindex="-1"
      phx-mounted={JS.focus()}
      class="alert alert-soft alert-error block min-w-0 text-sm outline-none [overflow-wrap:anywhere]"
    >
      <p class="flex items-center gap-1.5 text-error">
        <.icon name="hero-x-circle-mini" class="size-4 shrink-0" />
        <strong class="font-medium">Canopy was cleared, but the seeder stopped.</strong>
        <span class="text-xs opacity-70">· {TimelineComponents.short_time(@result.at)}</span>
      </p>
      <.failure_reason reason={@result.reason} />
      <p class="mt-1 text-base-content/80">Rerun the seeder below to add the missing starters.</p>
      <.backup_line path={@result.backup_path} copy={@copy} />
    </div>
    """
  end

  attr :reason, :any, required: true

  # The cause, under a failure's lead and apart from what to do next.
  defp failure_reason(assigns) do
    ~H"""
    <p class="mt-1 font-mono text-xs text-base-content/70">
      {@reason |> to_string() |> String.trim_trailing(".")}
    </p>
    """
  end

  attr :path, :string, default: nil
  attr :copy, :list, default: []

  defp backup_line(assigns) do
    ~H"""
    <div :if={@path} class="mt-1.5 flex flex-wrap items-center gap-2 text-xs">
      <span class="text-base-content/70">Backup:</span>
      <code id="reset-backup-path" class="min-w-0 break-all font-mono">{@path}</code>
      {render_slot(@copy)}
    </div>
    """
  end

  # "Seeder created 10 agents, 2 teams and 2 playbooks, and assigned the cost auditor."
  defp seed_sentence(%{created: created} = report) do
    counts =
      for {kind, one, many} <- [
            {:agent, "agent", "agents"},
            {:team, "team", "teams"},
            {:playbook, "playbook", "playbooks"}
          ],
          n = Enum.count(created, &(&1.kind == kind)),
          n > 0,
          do: "#{n} #{if n == 1, do: one, else: many}"

    auditor =
      if match?({:assigned, _}, report.cost_auditor),
        do: ", and assigned the cost auditor",
        else: ""

    case counts do
      [] -> "Seeder found every starter already there#{auditor}."
      _ -> "Seeder created #{join_and(counts)}#{auditor}."
    end
  end

  defp seed_sentence(_report), do: "The seeder ran."

  defp join_and([one]), do: one
  defp join_and(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  # -- Modal -------------------------------------------------------------------

  attr :reset, :map, required: true, doc: "the page's `@reset`"
  attr :hold, :string, default: nil, doc: "`Canopy.Hold.reason/0` (the Kept column says it stays)"

  @doc """
  The reset modal. Not a `<dialog>` (Chrome closes a modal dialog on a
  repeated Esc, and a running reset must not close); `focus_wrap` keeps focus
  inside, and Esc and the backdrop close it only in `:confirm` and `:failed`.
  """
  def reset_modal(assigns) do
    assigns = assign(assigns, :closable?, assigns.reset.state in [:confirm, :failed])

    ~H"""
    <div
      id="reset-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown={@closable? && close_reset()}
      phx-key="Escape"
    >
      <div
        class="absolute inset-0 bg-neutral/30 backdrop-blur-[2px] dark:bg-black/50"
        aria-hidden="true"
      >
      </div>
      <%!-- the panel is #reset-dialog itself, so a click in its padding isn't "away" --%>
      <.focus_wrap id="reset-focus" class="relative flex max-h-full w-full max-w-[520px]">
        <div
          id="reset-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="reset-title"
          aria-describedby="reset-sub"
          aria-busy={to_string(running?(@reset))}
          tabindex="-1"
          phx-click-away={@closable? && close_reset()}
          class="w-full overflow-y-auto rounded-2xl bg-base-100 p-6 text-base-content shadow-2xl outline-none ring-1 ring-base-content/10"
        >
          <.modal_body reset={@reset} hold={@hold} />
        </div>
      </.focus_wrap>
    </div>
    """
  end

  # Back to the row's button, also when another tab's reset opened the modal.
  defp close_reset, do: JS.push("close_reset") |> JS.focus(to: "#open-reset")

  attr :reset, :map, required: true
  attr :hold, :string, default: nil

  defp modal_body(%{reset: %{state: :confirm}} = assigns) do
    assigns = assign(assigns, :d, assigns.reset.preview.deleted)

    ~H"""
    <h2 id="reset-title" class="text-lg font-semibold">Reset Canopy from scratch?</h2>
    <p id="reset-sub" class="mt-1 text-sm text-base-content/70">
      Running agent turns are stopped and everything below is deleted. The starter agents, teams and playbooks are then created fresh.
    </p>

    <div class="mt-4 grid gap-3 sm:grid-cols-2">
      <section class="rounded-lg border border-error/30 bg-error/5 p-3">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-error">Deleted</h3>
        <dl id="reset-deleted" class="mt-2 grid grid-cols-[1fr_auto] gap-x-3 gap-y-1 text-sm">
          <dt>Channels &amp; DMs</dt>
          <dd class="text-right tabular-nums">{n(@d.channels + @d.dms)}</dd>
          <dt>Messages</dt>
          <dd class="text-right tabular-nums">{n(@d.messages)}</dd>
          <dt>Agents &amp; teams</dt>
          <dd class="text-right tabular-nums">{n(@d.agents)} · {n(@d.teams)}</dd>
          <dt>Playbooks &amp; runs</dt>
          <dd class="text-right tabular-nums">{n(@d.playbooks)} · {n(@d.runs)}</dd>
          <dt>Tasks, schedules, watches</dt>
          <dd class="text-right tabular-nums">{n(@d.tasks)} · {n(@d.schedules + @d.watches)}</dd>
          <dt>Agent memory</dt>
          <dd class="text-right tabular-nums">{n(@d.memories)}</dd>
          <dt>Shared files</dt>
          <dd class="text-right tabular-nums">
            {n(@d.documents)} · {Canopy.Documents.size_label(@d.document_bytes)}
          </dd>
          <dt>Cost history</dt>
          <dd
            class="text-right tabular-nums"
            title={CanopyWeb.CostFormat.estimate_title(@d.cost_usd, @d[:cost_estimated])}
          >
            {CanopyWeb.CostFormat.money(@d.cost_usd, @d[:cost_estimated])}
          </dd>
        </dl>
      </section>
      <section class="rounded-lg border border-base-300 bg-base-100 p-3">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-success">Kept</h3>
        <ul id="reset-kept" class="mt-2 flex flex-col gap-1 text-sm">
          <li :for={item <- kept(@reset.preview, @hold)} class="flex gap-1.5">
            <.icon name="hero-check-mini" class="mt-0.5 size-4 shrink-0 text-success" />
            <span>{item}</span>
          </li>
        </ul>
        <p class="mt-2 text-xs text-base-content/60">
          Claude Code, Codex and OpenCode session files on disk are left alone; Canopy just forgets them.
        </p>
      </section>
    </div>

    <div class="mt-3 flex gap-1.5 text-xs text-base-content/70">
      <.icon name="hero-archive-box-mini" class="mt-px size-4 shrink-0" />
      <div class="min-w-0">
        First, the database is copied to
        <code id="reset-backup-preview" class="block break-all font-mono">
          {@reset.preview.backup_path}
        </code>
      </div>
    </div>

    <form id="reset-form" class="mt-4" phx-change="reset_phrase" phx-submit="start_reset">
      <label for="reset-confirm" id="reset-confirm-label" class="text-sm">
        Type <strong class="font-mono">reset</strong> to confirm
      </label>
      <input
        type="text"
        id="reset-confirm"
        name="phrase"
        class="input mt-1 w-full font-mono"
        autocomplete="off"
        spellcheck="false"
        autocapitalize="off"
        phx-mounted={JS.focus()}
      />
      <div class="mt-5 flex justify-end gap-2">
        <button type="button" id="cancel-reset" class="btn btn-ghost btn-sm" phx-click={close_reset()}>
          Cancel
        </button>
        <button
          type="submit"
          id="confirm-reset"
          class="btn btn-error btn-sm"
          disabled={!@reset.phrase_ok?}
          aria-describedby="reset-confirm-label"
          phx-disable-with="Resetting…"
        >
          Reset Canopy
        </button>
      </div>
    </form>
    """
  end

  defp modal_body(%{reset: %{state: :running}} = assigns) do
    assigns = assign(assigns, :progress, assigns.reset.progress)

    ~H"""
    <h2 id="reset-title" class="text-lg font-semibold">Resetting Canopy…</h2>
    <p id="reset-step" role="status" aria-live="polite" class="mt-3 flex items-center gap-2 text-sm">
      <span class="loading loading-spinner loading-sm text-error" aria-hidden="true"></span>
      <%= if @progress do %>
        <span class="font-medium">{step_label(@progress.step)}</span>
        <span class="text-base-content/60">(step {@progress.index} of {@progress.total})</span>
      <% else %>
        <span class="font-medium">Starting</span>
      <% end %>
    </p>
    <p id="reset-sub" class="mt-1 text-xs text-base-content/60">
      {if @reset.origin?,
        do: "Keep this tab open. Other Canopy tabs reload when it finishes.",
        else: "A reset is running. This page reloads when it finishes."}
    </p>
    <%!-- every button is disabled, so focus rests on the dialog itself --%>
    <span id="reset-running-focus" tabindex="-1" class="sr-only" phx-mounted={JS.focus()}>
      Resetting
    </span>
    <div class="mt-5 flex justify-end gap-2">
      <button type="button" id="cancel-reset" class="btn btn-ghost btn-sm" disabled>Cancel</button>
      <button type="button" id="confirm-reset" class="btn btn-error btn-sm" disabled>
        <span class="loading loading-spinner loading-xs" aria-hidden="true"></span> Resetting
      </button>
    </div>
    """
  end

  defp modal_body(%{reset: %{state: :failed}} = assigns) do
    assigns = assign(assigns, :failure, assigns.reset.failure)

    ~H"""
    <h2 id="reset-title" class="text-lg font-semibold">The reset stopped</h2>
    <div
      id="reset-failure"
      role="alert"
      class="alert alert-soft alert-error mt-3 block min-w-0 text-sm [overflow-wrap:anywhere]"
    >
      <div id="reset-sub">
        <p class="font-medium text-error">{step_label(@failure.step)} failed.</p>
        <.failure_reason reason={@failure.reason} />
        <p class="mt-1 text-base-content/80">
          Nothing was deleted.<span :if={backup_shown?(@failure)}> Your backup is at</span>
        </p>
        <code
          :if={backup_shown?(@failure)}
          class="block break-all font-mono text-xs text-base-content/80"
        >
          {@failure.backup_path}
        </code>
      </div>
    </div>
    <div class="mt-5 flex justify-end gap-2">
      <button type="button" id="cancel-reset" class="btn btn-ghost btn-sm" phx-click={close_reset()}>
        Close
      </button>
      <button
        type="button"
        id="retry-reset"
        class="btn btn-error btn-sm"
        phx-click="retry_reset"
        phx-mounted={JS.focus()}
      >
        Try again
      </button>
    </div>
    """
  end

  # A failed backup has no file to point at.
  defp backup_shown?(failure), do: failure.step == :clearing and failure.backup_path != nil

  defp kept(preview, hold) do
    [
      "Engine, model & brake settings",
      "MCP token & collaboration prompt",
      "Your display name",
      "Registered repositories (#{preview.kept.repositories})",
      "Everything inside your repositories"
    ] ++ if(hold, do: ["Spend hold (on)"], else: [])
  end

  defp n(count) when is_integer(count), do: CanopyWeb.FileViewer.delimit(count)
  defp n(_count), do: "0"

  # A reason with exactly one full stop after it.
  defp sentence(reason), do: String.trim_trailing(to_string(reason), ".") <> "."
end
