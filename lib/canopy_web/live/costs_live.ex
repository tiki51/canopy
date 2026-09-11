defmodule CanopyWeb.CostsLive do
  @moduledoc """
  Spend, from the cost OpenCode reports per turn: totals, a daily bar for the
  last two weeks, and breakdowns by agent, channel, and model for a chosen
  period. Updates live as turns finish.
  """

  use CanopyWeb, :live_view

  alias Canopy.Costs
  alias Canopy.Costs.Auditor

  @periods [today: "Today", week: "7 days", month: "30 days", all: "All time"]
  @page 6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Costs")
     |> assign(:period, :week)
     |> assign(:expanded, MapSet.new())
     |> assign(:auditor, Auditor.agent())
     |> assign(:audit_focus, "")
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period =
      case params["period"] do
        p when p in ~w(today week month all) -> String.to_existing_atom(p)
        _ -> socket.assigns.period
      end

    {:noreply, socket |> assign(:period, period) |> load()}
  end

  @impl true
  def handle_info({:timeline_any, %{event_type: "agent_turn_completed"}}, socket),
    do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_rows", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id),
        do: MapSet.delete(socket.assigns.expanded, id),
        else: MapSet.put(socket.assigns.expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("set_auditor", %{"agent_id" => agent_id}, socket) do
    case Auditor.assign(agent_id) do
      {:ok, _} -> {:noreply, assign(socket, :auditor, Auditor.agent())}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not pick that agent.")}
    end
  end

  def handle_event("request_audit", params, socket) do
    focus = Map.get(params, "focus", "")
    repository_id = socket.assigns.current_repository_id || first_repository(socket)

    cond do
      is_nil(socket.assigns.auditor) ->
        {:noreply, put_flash(socket, :error, "Pick an auditor first.")}

      is_nil(repository_id) ->
        {:noreply,
         put_flash(socket, :error, "Register a repository first; the audit runs in a DM.")}

      true ->
        case Auditor.request(repository_id, focus) do
          {:ok, dm} ->
            {:noreply,
             socket
             |> put_flash(:info, "Asked @#{socket.assigns.auditor.name} for an audit.")
             |> push_navigate(to: ~p"/channels/#{dm.id}")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not ask for an audit: #{inspect(reason)}")}
        end
    end
  end

  defp first_repository(socket) do
    case socket.assigns.repositories do
      [first | _] -> first.id
      _ -> nil
    end
  end

  defp load(socket) do
    since = Costs.since(socket.assigns.period)

    socket
    |> assign(:today, Costs.total(Costs.since(:today)))
    |> assign(:week, Costs.total(Costs.since(:week)))
    |> assign(:all, Costs.total(nil))
    |> assign(:period_total, Costs.total(since))
    |> assign(:by_agent, Costs.by_agent(since))
    |> assign(:by_channel, Costs.by_channel(since))
    |> assign(:by_model, Costs.by_model(since))
    |> assign(:by_trigger, Costs.by_trigger(since))
    |> assign(:efficiency, Costs.efficiency(since))
    |> assign(:top_turns, Costs.top_turns(since, @page))
    |> assign(:budgets, Costs.channel_budgets())
    |> assign(:by_day, Costs.by_day(14))
  end

  # "@name · first words of the role", short enough for a select box.
  defp agent_option(%{name: name, role: role}) when is_binary(role) and role != "" do
    role = if String.length(role) > 32, do: String.slice(role, 0, 31) <> "…", else: role
    "@#{name} · #{role}"
  end

  defp agent_option(%{name: name}), do: "@" <> name

  defp tokens(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp tokens(n) when is_number(n), do: to_string(round(n))
  defp tokens(_), do: "0"

  defp rate(nil), do: "—"
  defp rate(r), do: "#{round(r * 100)}%"

  defp when_local(%DateTime{} = at),
    do: at |> Canopy.Schedules.When.to_local_naive() |> Calendar.strftime("%b %d %H:%M")

  defp periods, do: @periods

  defp share(cost, total) when is_number(total) and total > 0,
    do: min(100, round(cost / total * 100))

  defp share(_cost, _total), do: 0

  defp duration(ms) when is_integer(ms) and ms >= 3_600_000,
    do: "#{Float.round(ms / 3_600_000, 1)}h"

  defp duration(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)}m"
  defp duration(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp duration(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      repositories={@repositories}
      agents={@agents}
      dms={@dms}
      unread={@unread}
      schedule_counts={@schedule_counts}
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
    >
      <Layouts.page
        title="Costs"
        subtitle="What agents spend, as reported by the model providers through OpenCode"
        max_width="max-w-none"
      >
        <:actions>
          <div id="cost-periods" class="join">
            <.link
              :for={{key, label} <- periods()}
              patch={~p"/costs?period=#{key}"}
              class={["btn btn-xs join-item", @period == key && "btn-active"]}
              id={"period-#{key}"}
            >
              {label}
            </.link>
          </div>
        </:actions>

        <div class="grid gap-4 sm:grid-cols-3">
          <.stat id="cost-today" label="Today" total={@today} />
          <.stat id="cost-week" label="Last 7 days" total={@week} />
          <.stat id="cost-all" label="All time" total={@all} />
        </div>

        <.auditor_panel auditor={@auditor} agents={@agents} focus={@audit_focus} />

        <Layouts.panel id="cost-days" title="Last 14 days" description="Per day, your local time.">
          <div class="flex h-36 items-end gap-1">
            <div
              :for={day <- @by_day}
              id={"day-#{day.day}"}
              class="flex h-full flex-1 flex-col items-center justify-end"
              title={"#{day.day}: #{Costs.money(day.cost)} · #{day.turns} turns"}
            >
              <span :if={day.cost > 0} class="mb-1 text-[9px] tabular-nums text-base-content/60">
                {Costs.money(day.cost)}
              </span>
              <div
                class={[
                  "w-full rounded-t",
                  day.cost > 0 && "bg-primary/70",
                  day.cost == 0 && "bg-base-300"
                ]}
                style={"height: #{max(2, share(day.cost, Enum.max_by(@by_day, & &1.cost).cost))}%"}
              />
              <span class="mt-1 text-[9px] text-base-content/40">{Calendar.strftime(day.day, "%d")}</span>
            </div>
          </div>
        </Layouts.panel>

        <Layouts.panel
          id="efficiency"
          title="Where the tokens go"
          description="For the chosen period. Context is what each model call carries; the cache rate is how much of it the provider served from cache."
        >
          <dl class="grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-4">
            <.metric id="eff-steps" label="Model calls" value={@efficiency.steps} />
            <.metric id="eff-avg-cost" label="Per turn" value={Costs.money(@efficiency.avg_cost)} />
            <.metric
              id="eff-context"
              label="Context per call"
              value={tokens(@efficiency.avg_context)}
              hint={"compaction cap #{tokens(Canopy.Runtime.ChannelServer.context_cap())}"}
            />
            <.metric id="eff-cache" label="Cache hit rate" value={rate(@efficiency.cache_rate)} />
            <.metric
              id="eff-prompt"
              label="Prompt tokens"
              value={tokens(@efficiency.tokens.input + @efficiency.tokens.cache_read)}
              hint={"#{tokens(@efficiency.tokens.cache_read)} cached"}
            />
            <.metric
              id="eff-output"
              label="Output tokens"
              value={tokens(@efficiency.tokens.output)}
              hint={"#{tokens(@efficiency.tokens.reasoning)} reasoning"}
            />
            <.metric
              id="eff-passed"
              label="Passed turns"
              value={@efficiency.passed.turns}
              hint={Costs.money(@efficiency.passed.cost) <> " for no reply"}
            />
            <.metric
              id="eff-errors"
              label="Error turns"
              value={@efficiency.errors.turns}
              hint={"#{Costs.money(@efficiency.errors.cost)} · #{@efficiency.compactions} compactions"}
            />
          </dl>
        </Layouts.panel>

        <div class="grid gap-6 lg:grid-cols-2 xl:grid-cols-4">
          <.breakdown
            id="by-agent"
            title="By agent"
            rows={@by_agent}
            total={@period_total.cost}
            expanded={MapSet.member?(@expanded, "by-agent")}
          />
          <.breakdown
            id="by-channel"
            title="By channel"
            rows={@by_channel}
            total={@period_total.cost}
            link={:channel}
            expanded={MapSet.member?(@expanded, "by-channel")}
          />
          <.breakdown
            id="by-model"
            title="By model"
            rows={@by_model}
            total={@period_total.cost}
            expanded={MapSet.member?(@expanded, "by-model")}
          />
          <.breakdown
            id="by-trigger"
            title="By trigger"
            rows={@by_trigger}
            total={@period_total.cost}
            expanded={MapSet.member?(@expanded, "by-trigger")}
          />
        </div>

        <div class="grid gap-6 lg:grid-cols-3">
          <div class="lg:col-span-2">
            <Layouts.panel
              id="top-turns"
              title="Costliest turns"
              description="The single turns that cost the most in the period."
            >
              <p :if={@top_turns == []} class="text-xs text-base-content/50">
                Nothing in this period.
              </p>
              <div :if={@top_turns != []} class="overflow-x-auto">
                <table class="table table-xs">
                  <thead>
                    <tr>
                      <th>Cost</th>
                      <th>Agent</th>
                      <th>Where</th>
                      <th>When</th>
                      <th>Woken by</th>
                      <th class="text-right">Tools</th>
                      <th class="text-right">Calls</th>
                      <th class="text-right">Context</th>
                      <th class="text-right">Time</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={t <- @top_turns} id={"turn-#{t.id}"}>
                      <td class="tabular-nums font-medium">{Costs.money(t.cost)}</td>
                      <td>{t.agent}</td>
                      <td>
                        <.link
                          :if={t.channel_id}
                          navigate={~p"/channels/#{t.channel_id}"}
                          class="hover:underline"
                        >
                          {t.channel}
                        </.link>
                      </td>
                      <td class="whitespace-nowrap">{when_local(t.at)}</td>
                      <td>
                        {t.trigger || "—"}
                        <span :if={t.passed} class="badge badge-xs badge-ghost">passed</span>
                        <span :if={t.outcome == "error"} class="badge badge-xs badge-error badge-soft">
                          error
                        </span>
                      </td>
                      <td class="text-right tabular-nums">{t.tools}</td>
                      <td class="text-right tabular-nums">{t.steps}</td>
                      <td class="text-right tabular-nums">{tokens(t.context)}</td>
                      <td class="text-right tabular-nums">{duration(t.duration_ms)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </Layouts.panel>
          </div>

          <Layouts.panel
            id="budgets"
            title="Channel spend limits"
            description="Set on a channel's Budget panel. Agents in a channel that reached its limit stay quiet until you raise it."
          >
            <p :if={@budgets == []} class="text-xs text-base-content/50">No channel has a limit.</p>
            <ul :if={@budgets != []} class="flex flex-col divide-y divide-base-300">
              <li :for={b <- @budgets} id={"budget-#{b.channel_id}"} class="py-2 text-sm">
                <div class="flex items-baseline justify-between gap-3">
                  <.link
                    navigate={~p"/channels/#{b.channel_id}"}
                    class="min-w-0 truncate font-medium hover:underline"
                  >
                    {b.label}
                  </.link>
                  <span class={["shrink-0 tabular-nums", b.reached? && "text-error"]}>
                    {Costs.money(b.spent)} / {Costs.money(b.limit)}
                  </span>
                </div>
                <div class="mt-1 h-1.5 w-full overflow-hidden rounded bg-base-300">
                  <div
                    class={[
                      "h-full rounded",
                      b.reached? && "bg-error/70",
                      !b.reached? && "bg-primary/70"
                    ]}
                    style={"width: #{share(b.spent, b.limit)}%"}
                  />
                </div>
              </li>
            </ul>
          </Layouts.panel>
        </div>

        <p class="text-xs text-base-content/50">
          Costs are what each provider reports per turn. Turns that ended in an error or ran on a
          provider that reports nothing count as $0, so treat these as a floor.
        </p>
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div id={@id}>
      <dt class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
        {@label}
      </dt>
      <dd class="mt-0.5 text-lg font-semibold tabular-nums">{@value}</dd>
      <dd :if={@hint} class="text-[11px] text-base-content/50">{@hint}</dd>
    </div>
    """
  end

  attr :auditor, :any, default: nil
  attr :agents, :list, required: true
  attr :focus, :string, default: ""

  # Pick an agent to audit spend, then ask; the audit is a DM with that agent.
  defp auditor_panel(assigns) do
    ~H"""
    <Layouts.panel
      id="auditor"
      title="Auditor"
      description="An agent you ask to read this page's numbers (through canopy_costs_report) and recommend where to cut. The audit runs in a DM with it."
    >
      <div class="flex flex-col gap-3 lg:flex-row lg:items-end">
        <form id="auditor-form" phx-change="set_auditor" class="lg:w-72">
          <label class="fieldset mb-0" for="auditor-select">
            <span class="label mb-1">Auditor</span>
            <select id="auditor-select" name="agent_id" class="w-full select select-sm">
              <option value="" selected={is_nil(@auditor)}>No auditor</option>
              <option
                :for={agent <- @agents}
                value={agent.id}
                selected={@auditor && @auditor.id == agent.id}
              >
                {agent_option(agent)}
              </option>
            </select>
          </label>
        </form>
        <form
          id="audit-form"
          phx-submit="request_audit"
          class="flex flex-1 flex-col gap-2 sm:flex-row sm:items-end"
        >
          <label class="fieldset mb-0 flex-1" for="audit-focus">
            <span class="label mb-1">Focus (optional)</span>
            <input
              id="audit-focus"
              name="focus"
              type="text"
              value={@focus}
              class="input input-sm w-full"
              placeholder="e.g. the todo-webapp channel, or scheduled tasks"
              autocomplete="off"
            />
          </label>
          <.button type="submit" variant="primary" id="request-audit" disabled={is_nil(@auditor)}>
            <.icon name="hero-magnifying-glass-circle" class="size-4" />
            {if @auditor, do: "Ask @#{@auditor.name} to audit", else: "Pick an auditor"}
          </.button>
        </form>
      </div>
    </Layouts.panel>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :total, :map, required: true

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-200 px-5 py-4">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">{@label}</p>
      <p class="mt-1 text-2xl font-semibold tabular-nums">{Costs.money(@total.cost)}</p>
      <p class="mt-0.5 text-xs text-base-content/60">
        {@total.turns} turns · {@total.tools} tool calls
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :total, :float, required: true
  attr :link, :atom, default: nil
  attr :expanded, :boolean, default: false

  # The first six rows, with the rest behind a toggle.
  defp breakdown(assigns) do
    assigns =
      assign(assigns,
        shown: if(assigns.expanded, do: assigns.rows, else: Enum.take(assigns.rows, @page)),
        hidden: max(length(assigns.rows) - @page, 0)
      )

    ~H"""
    <Layouts.panel id={@id} title={@title}>
      <ul :if={@rows != []} class="flex flex-col divide-y divide-base-300">
        <li :for={row <- @shown} id={"#{@id}-#{row.key}"} class="py-2 text-sm">
          <div class="flex items-baseline justify-between gap-3">
            <span class="min-w-0 truncate font-medium">
              <.link
                :if={@link == :channel and is_binary(row.key)}
                navigate={~p"/channels/#{row.key}"}
                class="hover:underline"
              >
                {row.label}
              </.link>
              <span :if={not (@link == :channel and is_binary(row.key))}>{row.label}</span>
            </span>
            <span class="shrink-0 tabular-nums">{Costs.money(row.cost)}</span>
          </div>
          <div class="mt-1 h-1.5 w-full overflow-hidden rounded bg-base-300">
            <div class="h-full rounded bg-secondary/70" style={"width: #{share(row.cost, @total)}%"} />
          </div>
          <p class="mt-1 text-[11px] text-base-content/50">
            {row.turns} turns · {row.tools} tool calls · {duration(row.duration_ms)}
          </p>
        </li>
      </ul>
      <p :if={@rows == []} class="text-xs text-base-content/50">Nothing in this period.</p>
      <button
        :if={@hidden > 0}
        type="button"
        id={"#{@id}-toggle"}
        class="btn btn-ghost btn-xs mt-2 w-full"
        phx-click="toggle_rows"
        phx-value-id={@id}
      >
        {if @expanded, do: "Show fewer", else: "Show #{@hidden} more"}
      </button>
    </Layouts.panel>
    """
  end
end
