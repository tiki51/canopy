defmodule CanopyWeb.PlaybookComponents do
  @moduledoc """
  Playbook pieces shared by the channel's run panel and the Playbooks page:
  a run's steps (status, round, owners, result, delegations), the start
  form, and the preview of a definition's steps in the editor.
  """

  use CanopyWeb, :html

  alias Canopy.Playbooks.{Run, Runs}

  @doc "`bug-fix · 3/6 Fix · @backend @frontend`: the header chip's text for a run."
  def chip_text(%Run{} = run, names) do
    case Runs.current_step(run) do
      nil ->
        run.playbook_name

      step ->
        owners =
          case step.owner_ids do
            [] -> ""
            ids -> " · " <> Enum.map_join(ids, " ", &("@" <> Map.get(names, &1, "agent")))
          end

        "#{run.playbook_name} · #{step.position}/#{length(run.steps)} #{step.title}#{owners}"
    end
  end

  @doc """
  The channel's run panel: where the run is, every step, and what the user
  can do (Approve or Request changes on a step held for them, reassign the
  coordinator, Cancel). Without a run, the start form.
  """
  attr :run, :any, default: nil
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :members, :list, default: []
  attr :start_form, :any, default: nil
  attr :playbooks, :list, default: []
  attr :agents, :list, default: []
  attr :recent, :list, default: []

  attr :bare, :boolean,
    default: false,
    doc: "inside another panel: no band, border or scroll of its own"

  def run_panel(assigns) do
    ~H"""
    <section
      id="playbook-panel"
      class={
        if @bare,
          do: "py-2",
          else:
            "max-h-[60vh] overflow-y-auto border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6"
      }
    >
      <%= if @run do %>
        <div class="mb-2 flex flex-wrap items-center gap-2">
          <span
            :if={!@bare}
            class="text-xs font-semibold uppercase tracking-wider text-base-content/60"
          >
            Playbook
          </span>
          <span id="playbook-run-name" class="font-mono text-sm font-semibold">
            {@run.playbook_name}
          </span>
          <span
            id="playbook-run-status"
            data-status={@run.status}
            class={[
              "badge badge-xs",
              @run.status == "active" && "badge-primary badge-soft",
              @run.status == "awaiting_approval" && "badge-warning"
            ]}
          >
            {status_label(@run.status)}
          </span>
          <span class="text-xs text-base-content/60">
            coordinated by {agent_name(@names, @run.coordinator_agent_id)} · started by {starter(
              @run,
              @names,
              @user_name
            )}
          </span>
          <button
            type="button"
            id="cancel-playbook-run"
            class="btn btn-ghost btn-xs ml-auto text-error"
            phx-click="cancel_playbook_run"
            phx-value-id={@run.id}
            data-canopy-confirm="The run stops here; its steps and results stay on record."
            data-canopy-confirm-title={"Cancel #{@run.playbook_name}?"}
            data-canopy-confirm-label="Cancel run"
          >
            <.icon name="hero-x-mark-mini" class="size-4" /> Cancel run
          </button>
        </div>

        <p id="playbook-run-brief" class="mb-2 whitespace-pre-wrap text-sm text-base-content/80">
          {@run.brief}
        </p>

        <p
          :if={Runs.definition_changed?(@run)}
          id="playbook-definition-changed"
          class="mb-2 text-xs text-warning"
        >
          The playbook was edited since this run started; the run keeps the text it started with.
        </p>

        <div class="mb-3 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-base-content/70">
          <div id="playbook-roster" class="flex flex-wrap items-center gap-1.5">
            <span class="font-medium text-base-content/60">Roster</span>
            <span :if={@run.roster == %{}}>the coordinator only</span>
            <span
              :for={{role, id} <- Enum.sort(@run.roster)}
              id={"playbook-roster-#{role}"}
              class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-100 px-2 py-0.5"
            >
              <span>{role}</span>
              <span class="text-base-content/40" aria-label="filled by">→</span>
              <span class="font-mono text-base-content/80">{agent_name(@names, id)}</span>
            </span>
          </div>
          <.form
            for={%{}}
            as={:reassign}
            id="reassign-coordinator-form"
            phx-submit="reassign_coordinator"
            class="flex items-center gap-1.5"
          >
            <input type="hidden" name="run_id" value={@run.id} />
            <label for="reassign-coordinator" class="font-medium text-base-content/60">
              Coordinator
            </label>
            <select
              id="reassign-coordinator"
              name="agent_id"
              class="select select-xs w-44"
              aria-label="New coordinator"
            >
              <option
                :for={agent <- @agents}
                value={agent.id}
                selected={agent.id == @run.coordinator_agent_id}
              >
                @{agent.name}
              </option>
            </select>
            <button type="submit" id="reassign-coordinator-submit" class="btn btn-ghost btn-xs">
              Reassign
            </button>
          </.form>
        </div>

        <.step_list run={@run} names={@names} />
      <% else %>
        <div class="mb-2 flex items-center gap-2">
          <span
            :if={!@bare}
            class="text-xs font-semibold uppercase tracking-wider text-base-content/60"
          >
            Playbook
          </span>
          <span class="text-xs text-base-content/60">
            No playbook is running here. Start one, or ask an agent to run one.
          </span>
        </div>
        <.start_form
          :if={@start_form}
          form={@start_form}
          playbooks={@playbooks}
          agents={@agents}
          channels={[]}
        />
        <p :if={@playbooks == []} id="playbooks-none" class="text-xs text-base-content/60">
          No playbooks are enabled. <.link navigate={~p"/playbooks"} class="link link-primary">Open the library</.link>.
        </p>
        <ul :if={@recent != []} id="playbook-recent" class="mt-3 flex flex-col gap-1 text-xs">
          <li :for={run <- @recent} id={"playbook-recent-#{run.id}"} class="text-base-content/60">
            <span class="font-mono">{run.playbook_name}</span>
            {status_label(run.status)} · {Canopy.Schedules.relative(run.inserted_at)}
            <span :if={run.outcome}>: {truncate(run.outcome, 120)}</span>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  @doc "A run's steps, with the Approve and Request changes controls on a held step."
  attr :run, :map, required: true
  attr :names, :map, required: true

  def step_list(assigns) do
    ~H"""
    <ol id="playbook-steps" class="flex flex-col divide-y divide-base-300">
      <li
        :for={step <- @run.steps}
        id={"playbook-step-#{step.step_id}"}
        data-status={step.status}
        class={["flex items-start gap-3 py-2 text-sm", step.status == "pending" && "opacity-60"]}
      >
        <.icon
          name={step_icon(step.status)}
          class={["mt-0.5 size-4 shrink-0", step_tone(step.status)]}
        />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span class="font-medium">{step.position}. {step.title}</span>
            <%!-- the id is shown unless a marker already says it (a step
                 named "sign-off" with its sign-off marker) --%>
            <span
              :if={step.step_id not in step_markers(step)}
              class="font-mono text-xs text-base-content/50"
            >
              {step.step_id}
            </span>
            <span :if={step.round > 1} class="badge badge-ghost badge-xs">round {step.round}</span>
            <span :if={step.approval} class="badge badge-ghost badge-xs" title="Needs your approval">
              sign-off
            </span>
            <span :if={step.optional} class="badge badge-ghost badge-xs">optional</span>
            <span class="text-xs text-base-content/60">{owners(step, @names)}</span>
            <span :if={step.completed_at} class="text-[11px] text-base-content/50">
              {Canopy.Schedules.relative(step.completed_at)}
            </span>
          </div>
          <p
            :if={step.result}
            id={"playbook-step-#{step.step_id}-result"}
            class="mt-0.5 whitespace-pre-wrap break-words text-xs text-base-content/75"
          >
            {truncate(step.result, 400)}
          </p>
          <ul
            :if={Runs.round_delegations(step) != []}
            id={"playbook-step-#{step.step_id}-delegations"}
            class="mt-1 flex flex-col gap-0.5 text-[11px] text-base-content/65"
          >
            <li :for={d <- Runs.round_delegations(step)} id={"playbook-delegation-#{d.id}"}>
              <.icon name="hero-arrow-uturn-right-micro" class="size-3" />
              <span class="font-mono">@{d.to_agent && d.to_agent.name}</span>
              <span class={delegation_tone(d.status)}>{d.status}</span>
              — {truncate(d.description, 100)}
            </li>
          </ul>
          <div
            :if={step.status == "awaiting_approval"}
            id="playbook-approval"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <button
              type="button"
              id="approve-playbook-step"
              class="btn btn-xs btn-primary"
              phx-click="approve_playbook_step"
              phx-value-id={@run.id}
            >
              <.icon name="hero-check-mini" class="size-4" /> Approve
            </button>
            <.form
              for={%{}}
              as={:changes}
              id="request-changes-form"
              phx-submit="request_playbook_changes"
              class="flex flex-1 items-center gap-1.5"
            >
              <input type="hidden" name="run_id" value={@run.id} />
              <input
                type="text"
                name="note"
                id="request-changes-note"
                placeholder="What should change?"
                class="input input-xs min-w-40 flex-1"
                aria-label="What should change"
              />
              <button type="submit" id="request-playbook-changes" class="btn btn-xs btn-ghost">
                Request changes
              </button>
            </.form>
          </div>
        </div>
      </li>
    </ol>
    """
  end

  @doc """
  Starting a run: the playbook, the channel (on the Playbooks page), the
  coordinator, the brief, and role overrides. Emits `start_validate` and
  `start_playbook` with `start[...]` params.
  """
  attr :form, :any, required: true
  attr :playbooks, :list, required: true
  attr :agents, :list, required: true
  attr :channels, :list, default: [], doc: "`[{label, id}]`; empty when the channel is fixed"
  attr :hint, :string, default: nil

  def start_form(assigns) do
    ~H"""
    <.form
      :if={@playbooks != []}
      for={@form}
      id="start-playbook-form"
      phx-change="start_validate"
      phx-submit="start_playbook"
      class="flex flex-col gap-2"
    >
      <div class="grid gap-2 sm:grid-cols-3">
        <.input
          field={@form[:playbook_id]}
          type="select"
          id="start-playbook"
          label="Playbook"
          options={Enum.map(@playbooks, &{&1.name, &1.id})}
        />
        <.input
          :if={@channels != []}
          field={@form[:channel_id]}
          type="select"
          id="start-channel"
          label="Channel"
          options={@channels}
        />
        <.input
          field={@form[:coordinator_id]}
          type="select"
          id="start-coordinator"
          label="Coordinator"
          options={Enum.map(@agents, &{"@#{&1.name}", &1.id})}
        />
      </div>
      <.input
        field={@form[:brief]}
        type="textarea"
        id="start-brief"
        label="Brief"
        rows="3"
        placeholder={@form[:inputs].value || "What this run is about"}
      />
      <.input
        field={@form[:assign]}
        type="text"
        id="start-assign"
        label="Role overrides (optional)"
        placeholder="fix=@fullstack, test=@qa"
        autocomplete="off"
      />
      <p :if={@hint || @form[:hint].value} id="start-hint" class="text-xs text-base-content/60">
        {@hint || @form[:hint].value}
      </p>
      <div>
        <.button type="submit" variant="primary" id="start-playbook-submit">
          <.icon name="hero-play-mini" class="size-4" /> Start run
        </.button>
      </div>
    </.form>
    """
  end

  @doc "The steps of a parsed definition, for the editor's preview."
  attr :definition, :any, required: true

  def definition_preview(assigns) do
    ~H"""
    <div id="playbook-preview" class="flex flex-col gap-2 text-sm">
      <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/70">
        <span class="font-mono font-semibold text-base-content">{@definition.name}</span>
        <span :if={@definition.team}>team <span class="font-mono">@{@definition.team}</span></span>
        <span :if={@definition.coordinator}>
          coordinator <span class="font-mono">@{@definition.coordinator}</span>
        </span>
        <span>{if @definition.channel == "new",
          do: "runs in a new channel",
          else: "runs in the channel"}</span>
        <span>
          {if @definition.stall_after,
            do: "nudges after #{@definition.stall_after} min quiet",
            else: "never nudged"}
        </span>
      </div>
      <ol id="playbook-preview-steps" class="flex flex-col gap-1">
        <li
          :for={{step, n} <- Enum.with_index(@definition.steps, 1)}
          id={"preview-step-#{step.id}"}
          class="flex flex-wrap items-baseline gap-2"
        >
          <span class="w-5 text-right text-xs text-base-content/50">{n}.</span>
          <span class="font-medium">{step.title}</span>
          <span class="font-mono text-xs text-base-content/50">{step.id}</span>
          <span class="text-xs text-base-content/70">{Enum.join(step.owner, ", ")}</span>
          <span :if={step.approval} class="badge badge-warning badge-xs">your sign-off</span>
          <span :if={step.optional} class="badge badge-ghost badge-xs">optional</span>
          <span :if={step.on_reject} class="text-[11px] text-base-content/50">
            on reject → {step.on_reject}
          </span>
        </li>
      </ol>
    </div>
    """
  end

  # -- Helpers ------------------------------------------------------------------------

  defp step_markers(step) do
    [step.approval && "sign-off", step.optional && "optional"] |> Enum.filter(& &1)
  end

  def status_label("active"), do: "in progress"
  def status_label("awaiting_approval"), do: "waiting for you"
  def status_label("completed"), do: "completed"
  def status_label("cancelled"), do: "cancelled"
  def status_label(other), do: other

  defp starter(%Run{started_by_agent_id: nil, trigger: %{} = trigger}, _names, _user)
       when map_size(trigger) > 0,
       do: "a GitHub watch"

  defp starter(%Run{started_by_agent_id: nil}, _names, user), do: user
  defp starter(%Run{started_by_agent_id: id}, names, _user), do: agent_name(names, id)

  defp agent_name(_names, nil), do: "nobody"
  defp agent_name(names, id), do: "@" <> Map.get(names, id, "agent")

  defp owners(%{owner_ids: [], owner_roles: roles}, _names) do
    if "coordinator" in roles, do: "coordinator", else: ""
  end

  defp owners(%{owner_ids: ids}, names), do: Enum.map_join(ids, " ", &agent_name(names, &1))

  defp step_icon("done"), do: "hero-check-circle-mini"
  defp step_icon("skipped"), do: "hero-forward-mini"
  defp step_icon("active"), do: "hero-play-circle-mini"
  defp step_icon("awaiting_approval"), do: "hero-hand-raised-mini"
  defp step_icon(_), do: "hero-ellipsis-horizontal-circle-mini"

  defp step_tone("done"), do: "text-success"
  defp step_tone("active"), do: "text-primary"
  defp step_tone("awaiting_approval"), do: "text-warning"
  defp step_tone(_), do: "text-base-content/40"

  defp delegation_tone("completed"), do: "text-success"
  defp delegation_tone("failed"), do: "text-error"
  defp delegation_tone(_), do: "text-base-content/60"

  defp truncate(nil, _max), do: ""

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
