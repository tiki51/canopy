defmodule CanopyWeb.PlaybooksLive do
  @moduledoc """
  The playbook library, in three pages under one LiveView (the builder is
  `CanopyWeb.PlaybookBuilderLive`; a playbook's export is a plain download
  from `CanopyWeb.TemplateController`):

    * `/playbooks` — a card per playbook: its steps as a strip of pills,
      who leads it, where it runs; Enabled, Start, Duplicate, Export, Delete.
      Filtered to all, enabled, or drafts (`?show=`).
    * `/playbooks/new` — how to start: copy a playbook, start blank, or
      describe it to an agent, which drafts it (`CanopyWeb.PlaybookAsk`)
    * `/playbooks/:id/start` — start a run: the brief, where it runs, who
      leads it and who does what, beside what will happen

  Playbooks are global to Canopy. An enabled playbook is listed in every
  agent's system prompt, so a draft an agent saved stays disabled until the
  user enables it.
  """

  use CanopyWeb, :live_view

  import CanopyWeb.PlaybookComponents, only: [avatar: 1]

  alias Canopy.{Agents, Channels, Playbooks, Repositories}
  alias Canopy.Playbooks.{Definition, Playbook, Runs}
  alias CanopyWeb.{PlaybookAsk, PlaybookBuilder, PlaybookStart}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Playbooks.subscribe()
      Runs.subscribe()
    end

    active = Agents.list_active()

    {:ok,
     socket
     |> assign(:playbook, nil)
     |> assign(:active_agents, active)
     |> assign(:by_name, Map.new(active, &{&1.name, &1}))
     |> load_list()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case {socket.assigns.live_action, params} do
      {:index, _} ->
        show = if params["show"] in ~w(enabled drafts), do: params["show"], else: "all"

        {:noreply,
         socket
         |> assign(:playbook, nil)
         |> assign(:show, show)
         |> assign(:page_title, "Playbooks")}

      {:new, _} ->
        agents = socket.assigns.active_agents

        {:noreply,
         socket
         |> assign(:page_title, "New playbook")
         |> assign(:copy_id, socket.assigns.playbooks |> List.first() |> then(&(&1 && &1.id)))
         |> assign(:describe, "")
         |> assign(:drafter, lead_like(agents))}

      {:start, %{"id" => id}} ->
        case Playbooks.get(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That playbook no longer exists.")
             |> push_navigate(to: ~p"/playbooks")}

          playbook ->
            {:noreply,
             socket
             |> assign(:playbook, playbook)
             |> assign(:page_title, "Start " <> playbook.name)
             |> assign_start(%{})}
        end
    end
  end

  @impl true
  def handle_info({:playbooks, :changed}, socket), do: {:noreply, load_list(socket)}

  def handle_info({:playbook_runs, :changed, _channel_id}, socket) do
    {:noreply,
     socket
     |> assign(:run_counts, Playbooks.active_run_counts())
     |> assign(:last_runs, Playbooks.last_run_at())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Library ---------------------------------------------------------------------

  @impl true
  # The toggle carries the version on the page: enabling approves the text
  # the user saw, so a draft an agent replaced since is not enabled.
  def handle_event("toggle", %{"id" => id} = params, socket) do
    seen = params |> Map.get("version") |> parse_version()

    with %Playbook{} = playbook <- Playbooks.get(id),
         {:ok, playbook} <- Playbooks.set_enabled(playbook, not playbook.enabled, seen) do
      {:noreply,
       socket
       |> load_list()
       |> put_flash(
         :info,
         if(playbook.enabled,
           do: "Enabled #{playbook.name}: agents see it from their next turn.",
           else: "Disabled #{playbook.name}: agents no longer see it; runs in progress continue."
         )
       )}
    else
      {:error, :stale} ->
        {:noreply,
         socket
         |> load_list()
         |> put_flash(:error, "That playbook changed since the page loaded; read it again first.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "That playbook does not parse; fix it before enabling.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    with %Playbook{} = playbook <- Playbooks.get(id),
         {:ok, copy} <- Playbooks.duplicate(playbook) do
      {:noreply,
       socket
       |> put_flash(:info, "Copied to #{copy.name} (disabled until you enable it).")
       |> push_navigate(to: ~p"/playbooks/#{copy.id}/edit")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not copy that playbook.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Playbooks.get(id) do
      nil ->
        {:noreply, socket}

      playbook ->
        case Playbooks.delete(playbook) do
          {:ok, _} ->
            {:noreply, socket |> load_list() |> put_flash(:info, "Deleted #{playbook.name}.")}

          {:error, reason} when is_binary(reason) ->
            {:noreply, put_flash(socket, :error, String.capitalize(reason) <> ".")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete #{playbook.name}.")}
        end
    end
  end

  # -- New ---------------------------------------------------------------------------

  def handle_event("new_change", params, socket) do
    drafter =
      case params["drafter"] && Map.get(socket.assigns.by_name, params["drafter"]) do
        nil -> socket.assigns.drafter
        agent -> agent
      end

    {:noreply,
     socket
     |> assign(:copy_id, params["copy_id"] || socket.assigns.copy_id)
     |> assign(:describe, params["describe"] || socket.assigns.describe)
     |> assign(:drafter, drafter)}
  end

  def handle_event("copy", _params, socket) do
    handle_event("duplicate", %{"id" => socket.assigns.copy_id || ""}, socket)
  end

  def handle_event("describe", params, socket) do
    socket = elem(handle_event("new_change", params, socket), 1)
    text = String.trim(socket.assigns.describe || "")

    cond do
      text == "" ->
        {:noreply, put_flash(socket, :error, "Say how the work should go first.")}

      is_nil(socket.assigns.drafter) ->
        {:noreply, put_flash(socket, :error, "There's no active agent to ask.")}

      true ->
        agent = socket.assigns.drafter

        case PlaybookAsk.ask(agent, PlaybookAsk.draft_request(text)) do
          {:ok, channel} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Asked @#{agent.name} to draft it. It shows up in Playbooks under Drafts for you to review."
             )
             |> push_navigate(to: ~p"/channels/#{channel.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
    end
  end

  # -- Start ---------------------------------------------------------------------------

  def handle_event("start_validate", %{"start" => params}, socket),
    do: {:noreply, assign_start(socket, params)}

  def handle_event("start_playbook", %{"start" => params}, socket) do
    params = start_params(socket, params)

    case PlaybookStart.start(params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Started #{run.playbook_name} in ##{run.channel.name}.")
         |> push_navigate(to: ~p"/channels/#{run.channel_id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_start(params)
         |> put_flash(:error, PlaybookBuilder.plain_words(reason))}
    end
  end

  # -- Helpers -------------------------------------------------------------------------

  defp parse_version(nil), do: nil

  defp parse_version(text) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp load_list(socket) do
    playbooks = Playbooks.list()

    socket
    |> assign(:playbooks, playbooks)
    |> assign(:definitions, Map.new(playbooks, &{&1.id, ok_definition(&1)}))
    |> assign(:run_counts, Playbooks.active_run_counts())
    |> assign(:last_runs, Playbooks.last_run_at())
  end

  defp ok_definition(playbook) do
    case Playbooks.definition(playbook) do
      {:ok, d} -> d
      {:error, _} -> nil
    end
  end

  # The project manager knows the team and the runs, so it drafts by default.
  defp lead_like(agents) do
    Enum.find(agents, &(&1.name == "project-manager")) ||
      Enum.find(
        agents,
        &Regex.match?(~r/lead|manager|coordinat|\bpm\b/i, "#{&1.name} #{&1.role}")
      ) ||
      List.first(agents)
  end

  defp visible(playbooks, "enabled"), do: Enum.filter(playbooks, & &1.enabled)
  defp visible(playbooks, "drafts"), do: Enum.reject(playbooks, & &1.enabled)
  defp visible(playbooks, _), do: playbooks

  # The start form's state: the playbook's defaults, then what was typed.
  defp assign_start(socket, params) do
    playbook = socket.assigns.playbook
    definition = ok_definition(playbook)
    repositories = Repositories.list()
    channels = channel_options()
    rows = if definition, do: PlaybookStart.roster_rows(definition), else: []

    # a `channel: new` playbook always gets a new channel (`Runs.start`)
    always_new = definition && definition.channel == "new"

    runs_in =
      if always_new, do: "new", else: params["runs_in"] || "current"

    repository_id =
      params["repository_id"] || (List.first(repositories) && List.first(repositories).id)

    coordinator_id =
      params["coordinator_id"] ||
        case definition && Runs.default_coordinator(definition, nil) do
          %{id: id} -> id
          _ -> nil
        end

    roles =
      Map.new(rows, fn row ->
        {row.role, get_in(params, ["roles", row.role]) || (row.agent && row.agent.name) || ""}
      end)

    name_touched = params["channel_name_touched"] == "true"

    channel_name =
      if name_touched,
        do: params["channel_name"] || "",
        else: PlaybookStart.channel_name(playbook.name, params["brief"], repository_id)

    form =
      to_form(
        %{
          "playbook_id" => playbook.id,
          "brief" => params["brief"] || "",
          "runs_in" => runs_in,
          "repository_id" => repository_id,
          "channel_id" =>
            params["channel_id"] || (List.first(channels) && elem(List.first(channels), 1)),
          "channel_name" => channel_name,
          "channel_name_touched" => to_string(name_touched),
          "coordinator_id" => coordinator_id,
          "roles" => roles
        },
        as: :start,
        id: "start-run-form"
      )

    socket
    |> assign(:definition, definition)
    |> assign(:always_new, always_new)
    |> assign(:start_rows, rows)
    |> assign(:start_repositories, repositories)
    |> assign(:start_channels, channels)
    |> assign(:start_form, form)
  end

  defp start_params(socket, params) do
    params
    |> Map.put("playbook_id", socket.assigns.playbook.id)
    |> then(fn p ->
      if p["channel_name_touched"] == "true", do: p, else: Map.delete(p, "channel_name")
    end)
  end

  # open channels, by repository; DMs keep their agents, so they are left out
  defp channel_options do
    Channels.list()
    |> Enum.reject(&(Channels.dm?(&1) or Channels.archived?(&1)))
    |> Enum.map(&{"##{&1.name} · #{&1.repository.name}", &1.id})
  end

  defp title(%Playbook{body: body, name: name}) do
    case Regex.run(~r/^---\n.*?\n---\s*\n+#[ \t]+(.+?)[ \t]*$/ms, body) do
      [_, title] -> String.trim(title)
      nil -> PlaybookBuilder.humanize(name)
    end
  end

  defp source_label(%Playbook{source: "agent", enabled: false, created_by: %{name: name}}),
    do: "draft by @#{name}"

  defp source_label(%Playbook{source: "agent", enabled: false}), do: "agent draft"
  defp source_label(%Playbook{source: "agent", created_by: %{name: name}}), do: "by @#{name}"
  defp source_label(%Playbook{source: "agent"}), do: "by an agent"
  defp source_label(%Playbook{source: "seed"}), do: "starter"
  defp source_label(%Playbook{}), do: "yours"

  defp source_word(%Playbook{source: "seed"}), do: "starter"
  defp source_word(%Playbook{source: "agent"}), do: "an agent's"
  defp source_word(_), do: "yours"

  defp role_agent(definition, role, by_name) do
    case definition.roles[role] do
      nil -> nil
      name -> Map.get(by_name, name) || %{name: name, color: nil}
    end
  end

  defp owner_agents(definition, step, by_name) do
    Enum.map(step.owner, fn
      "coordinator" -> definition.coordinator && Map.get(by_name, definition.coordinator)
      role -> role_agent(definition, role, by_name)
    end)
  end

  defp meta(playbook, definition, last_run) do
    if playbook.source == "agent" and not playbook.enabled do
      by =
        if playbook.created_by,
          do: "Drafted by @#{playbook.created_by.name}",
          else: "Drafted by an agent"

      "#{by} #{Canopy.Schedules.relative(playbook.updated_at)} · agents can't use it until you enable it"
    else
      [
        if(definition.coordinator,
          do: "Led by @#{definition.coordinator}",
          else: "Led by whoever starts it"
        ),
        definition.team && "@#{definition.team}",
        if(definition.channel == "new",
          do: "runs in a new channel",
          else: "runs in the channel it's started from"
        ),
        if(last_run, do: "last run #{Canopy.Schedules.relative(last_run)}", else: "never run")
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")
    end
  end

  defp arrows(definition), do: Enum.map_join(definition.steps, " → ", & &1.title)

  defp stall_text(nil), do: "never nudges the lead"
  defp stall_text(m) when m < 60, do: "nudges the lead after #{m} min quiet"
  defp stall_text(m) when rem(m, 60) == 0, do: "nudges the lead after #{div(m, 60)} h quiet"
  defp stall_text(m), do: "nudges the lead after #{div(m, 60)} h #{rem(m, 60)} min quiet"

  # who does each step, given the form's choices: "@backend + @frontend"
  defp step_agents(step, form, agents) do
    by_id = Map.new(agents, &{&1.id, &1})
    roles = form[:roles].value || %{}

    step.owner
    |> Enum.map(fn
      "coordinator" ->
        case by_id[form[:coordinator_id].value] do
          nil -> "the lead"
          agent -> "@" <> agent.name
        end

      role ->
        case roles[role] do
          name when name in [nil, ""] -> "no #{PlaybookBuilder.humanize(role)} yet"
          name -> "@" <> name
        end
    end)
    |> Enum.join(" + ")
  end

  defp consequence(form, agents, definition) do
    lead =
      case Enum.find(agents, &(&1.id == form[:coordinator_id].value)) do
        nil -> "The lead"
        agent -> "@" <> agent.name
      end

    where =
      if form[:runs_in].value == "new",
        do: "and opens ##{form[:channel_name].value}",
        else: "in the channel you picked"

    team = if definition && definition.team, do: " @#{definition.team} joins it.", else: ""
    "#{lead} is woken with your brief #{where}.#{team}"
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
      <%= case @live_action do %>
        <% :index -> %>
          <.index_page {assigns} />
        <% :new -> %>
          <.new_page {assigns} />
        <% :start -> %>
          <.start_page {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp index_page(assigns) do
    assigns =
      assigns
      |> assign(:shown, visible(assigns.playbooks, assigns.show))
      |> assign(:counts, %{
        "all" => length(assigns.playbooks),
        "enabled" => Enum.count(assigns.playbooks, & &1.enabled),
        "drafts" => Enum.count(assigns.playbooks, &(!&1.enabled))
      })

    ~H"""
    <Layouts.page
      title="Playbooks"
      subtitle="Processes your agents run step by step, with Canopy keeping track"
      max_width="max-w-5xl"
    >
      <:actions>
        <.link navigate={~p"/agents/import"} id="import-playbook" class="btn btn-ghost btn-sm">
          Import file
        </.link>
        <.link navigate={~p"/playbooks/new"} id="new-playbook" class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> New playbook
        </.link>
      </:actions>

      <Layouts.empty_state
        :if={@playbooks == []}
        id="playbooks-empty"
        icon="hero-book-open"
        title="No playbooks yet"
      >
        A playbook names the roles and steps of a process you repeat, like fixing a bug. Ask an
        agent to run it, or start it here. <.link
          navigate={~p"/playbooks/new"}
          class="link link-primary"
        >Write one</.link>.
      </Layouts.empty_state>

      <div :if={@playbooks != []} class="flex flex-wrap items-center justify-between gap-3">
        <div class="join" role="group" aria-label="Show">
          <.link
            :for={{key, label} <- [{"all", "All"}, {"enabled", "Enabled"}, {"drafts", "Drafts"}]}
            patch={if key == "all", do: ~p"/playbooks", else: ~p"/playbooks?show=#{key}"}
            id={"show-#{key}"}
            class={["btn join-item btn-sm font-normal", @show == key && "btn-active font-medium"]}
            aria-current={@show == key && "page"}
          >
            {label} <span class="text-base-content/50">{@counts[key]}</span>
          </.link>
        </div>
        <p class="text-xs text-base-content/55">
          Agents see enabled playbooks. A run keeps the version it started with.
        </p>
      </div>

      <ul :if={@playbooks != []} id="playbooks" class="flex flex-col gap-3">
        <li
          :if={@shown == []}
          class="rounded-box border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/55"
        >
          {if @show == "drafts", do: "No drafts.", else: "No enabled playbooks."}
        </li>
        <li
          :for={playbook <- @shown}
          id={"playbook-#{playbook.id}"}
          data-enabled={to_string(playbook.enabled)}
          class="rounded-box border border-base-300 bg-base-200 p-4 transition-colors hover:border-base-content/25"
        >
          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={~p"/playbooks/#{playbook.id}/edit"}
              id={"edit-playbook-#{playbook.id}"}
              class="text-[15px] font-semibold hover:underline"
            >
              {title(playbook)}
            </.link>
            <span class="font-mono text-xs text-base-content/45">{playbook.name}</span>
            <span class={[
              "rounded-full px-1.5 text-[10px] font-medium uppercase tracking-wide",
              playbook.source == "agent" && !playbook.enabled && "bg-warning/15 text-warning",
              !(playbook.source == "agent" && !playbook.enabled) &&
                "bg-base-300/70 text-base-content/60"
            ]}>
              {source_label(playbook)}
            </span>
            <span
              :if={Map.get(@run_counts, playbook.id, 0) > 0}
              id={"playbook-runs-#{playbook.id}"}
              class="badge badge-primary badge-xs"
              title="Runs in progress"
            >
              {Map.get(@run_counts, playbook.id)} running
            </span>
            <div class="ml-auto flex items-center gap-1">
              <label class="flex cursor-pointer items-center gap-1.5 text-xs text-base-content/70">
                <input
                  type="checkbox"
                  id={"toggle-playbook-#{playbook.id}"}
                  class="toggle toggle-xs toggle-primary"
                  checked={playbook.enabled}
                  phx-click="toggle"
                  phx-value-id={playbook.id}
                  phx-value-version={playbook.lock_version}
                /> Enabled
              </label>
              <.link
                :if={playbook.enabled}
                navigate={~p"/playbooks/#{playbook.id}/start"}
                id={"start-playbook-#{playbook.id}"}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-play-mini" class="size-4" /> Start
              </.link>
              <.link
                :if={!playbook.enabled}
                navigate={~p"/playbooks/#{playbook.id}/edit"}
                id={"review-playbook-#{playbook.id}"}
                class={[
                  "btn btn-sm",
                  playbook.source == "agent" && "btn-primary",
                  playbook.source != "agent" && "btn-ghost"
                ]}
              >
                {if playbook.source == "agent", do: "Review draft", else: "Edit"}
              </.link>
              <.row_menu
                id={"playbook-menu-#{playbook.id}"}
                label={"More for #{playbook.name}"}
                size="sm"
              >
                <.row_menu_item
                  id={"duplicate-playbook-#{playbook.id}"}
                  icon="hero-document-duplicate-mini"
                  phx-click="duplicate"
                  phx-value-id={playbook.id}
                >
                  Duplicate
                </.row_menu_item>
                <.row_menu_item
                  id={"export-playbook-#{playbook.id}"}
                  icon="hero-arrow-down-tray-mini"
                  href={~p"/playbooks/#{playbook.id}/export"}
                  title="Export as a file, to import on another machine"
                >
                  Export file
                </.row_menu_item>
                <.row_menu_item
                  id={"delete-playbook-#{playbook.id}"}
                  icon="hero-trash-mini"
                  danger
                  phx-click="delete"
                  phx-value-id={playbook.id}
                  data-canopy-confirm="Finished runs keep their own copy of the text."
                  data-canopy-confirm-title={"Delete #{playbook.name}?"}
                  data-canopy-confirm-label="Delete"
                >
                  Delete
                </.row_menu_item>
              </.row_menu>
            </div>
          </div>
          <p class="mt-1 text-sm text-base-content/80">{playbook.description}</p>
          <%= if definition = @definitions[playbook.id] do %>
            <ol
              id={"playbook-strip-#{playbook.id}"}
              class="mt-3 flex flex-wrap items-center gap-x-1.5 gap-y-2"
              aria-label="Steps"
            >
              <%!-- each arrow stays on the line of the step after it --%>
              <li
                :for={{step, n} <- Enum.with_index(definition.steps, 1)}
                class="inline-flex items-center gap-1.5 whitespace-nowrap"
              >
                <span :if={n > 1} class="text-base-content/30" aria-hidden="true">→</span>
                <span class={[
                  "inline-flex items-center gap-1.5 rounded-lg border px-2 py-0.5 text-[13px]",
                  step.on_reject && "border-secondary/30 bg-secondary/5",
                  step.approval && !step.on_reject && "border-warning/40 bg-warning/5",
                  !step.approval && !step.on_reject && "border-base-300 bg-base-100"
                ]}>
                  <span class="text-base-content/45">{n}</span>
                  <span>{step.title}</span>
                  <span
                    :if={step.on_reject}
                    class="text-secondary"
                    title={"can send work back to #{step.on_reject}"}
                  >↩︎</span>
                  <span :if={step.approval} class="text-warning" title="waits for you">✓</span>
                  <span :if={step.optional} class="text-base-content/50" title="can be skipped">⤼</span>
                  <span class="flex -space-x-0.5">
                    <.avatar
                      :for={agent <- owner_agents(definition, step, @by_name)}
                      agent={agent}
                      size="size-4"
                      class="ring-2 ring-base-100"
                    />
                  </span>
                </span>
              </li>
            </ol>
            <p class="mt-3 text-xs text-base-content/50">
              {meta(playbook, definition, @last_runs[playbook.id])}
            </p>
          <% else %>
            <p class="mt-3 text-xs text-error">This playbook has problems; open it to see them.</p>
          <% end %>
        </li>
      </ul>

      <p
        :if={@playbooks != []}
        id="playbook-legend"
        class="flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-base-content/55"
      >
        <span><span class="text-secondary">↩︎</span> can send work back</span>
        <span><span class="text-warning">✓</span> waits for you</span>
        <span>⤼ can be skipped</span>
        <span class="inline-flex items-center gap-1.5">
          <span class="flex -space-x-0.5" aria-hidden="true">
            <span class="flex size-4 items-center justify-center rounded-md bg-primary/15 text-[10px] font-bold text-primary ring-2 ring-base-200">
              A
            </span>
            <span class="flex size-4 items-center justify-center rounded-md bg-secondary/15 text-[10px] font-bold text-secondary ring-2 ring-base-200">
              B
            </span>
          </span>
          in parallel
        </span>
      </p>
    </Layouts.page>
    """
  end

  defp new_page(assigns) do
    ~H"""
    <Layouts.page title="New playbook" max_width="max-w-6xl">
      <:actions>
        <.link navigate={~p"/playbooks"} id="cancel-new" class="btn btn-ghost btn-sm">Cancel</.link>
      </:actions>
      <div class="py-4 text-center">
        <h2 class="text-2xl font-semibold">How do you want to start?</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Whichever you pick, you finish in the same editor and can change everything.
        </p>
      </div>

      <.form
        for={%{}}
        id="new-playbook-form"
        phx-change="new_change"
        class="grid gap-4 lg:grid-cols-3"
      >
        <%!-- Copy --%>
        <section
          id="new-copy"
          class="new-card flex flex-col rounded-box border border-base-300 bg-base-200 p-5 focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/15"
        >
          <span class="flex size-9 items-center justify-center rounded-lg bg-primary/10 text-primary">
            <.icon name="hero-document-duplicate" class="size-5" />
          </span>
          <h3 class="mt-3 font-semibold">Copy a playbook</h3>
          <p class="text-sm text-base-content/60">
            Start from one that already works and change what's different.
          </p>
          <fieldset class="mt-4 flex flex-1 flex-col gap-2">
            <legend class="sr-only">Playbook to copy</legend>
            <p :if={@playbooks == []} class="text-xs text-base-content/50">
              No playbooks to copy yet.
            </p>
            <label
              :for={playbook <- @playbooks}
              class={[
                "flex cursor-pointer items-start gap-2.5 rounded-lg border px-3 py-2",
                @copy_id == playbook.id && "border-primary/50 bg-primary/5",
                @copy_id != playbook.id && "border-base-300 bg-base-100 hover:border-base-content/25"
              ]}
            >
              <input
                type="radio"
                name="copy_id"
                value={playbook.id}
                checked={@copy_id == playbook.id}
                class="radio radio-sm radio-primary mt-0.5"
              />
              <span class="min-w-0">
                <span class="font-medium">{title(playbook)}</span>
                <span class="text-xs text-base-content/50">
                  {source_word(playbook)}{if @definitions[playbook.id],
                    do: " · #{length(@definitions[playbook.id].steps)} steps"}
                </span>
                <span :if={@definitions[playbook.id]} class="block text-xs text-base-content/60">
                  {arrows(@definitions[playbook.id])}
                </span>
              </span>
            </label>
          </fieldset>
          <button
            type="button"
            id="copy-playbook"
            class="new-card-go btn btn-block mt-4"
            phx-click="copy"
            disabled={is_nil(@copy_id)}
          >
            Copy {(Enum.find(@playbooks, &(&1.id == @copy_id)) || %{name: ""})
            |> then(&if(&1.name == "", do: "", else: title(&1)))}
          </button>
        </section>

        <%!-- Blank --%>
        <section
          id="new-blank"
          class="new-card flex flex-col rounded-box border border-base-300 bg-base-200 p-5 focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/15"
        >
          <span class="flex size-9 items-center justify-center rounded-lg bg-base-100 text-base-content/70">
            <.icon name="hero-plus" class="size-5" />
          </span>
          <h3 class="mt-3 font-semibold">Start blank</h3>
          <p class="text-sm text-base-content/60">
            One empty step and sensible settings. Good when you know the process.
          </p>
          <div
            class="mt-4 flex flex-1 flex-col gap-2 rounded-lg border border-dashed border-base-300 p-3"
            aria-hidden="true"
          >
            <div class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content/45">
              <span class="flex size-5 items-center justify-center rounded-full bg-base-200 text-[10px]">1</span>
              What happens first?
            </div>
            <div class="rounded-lg border border-dashed border-base-300 py-1.5 text-center text-xs text-base-content/45">
              + Add step
            </div>
          </div>
          <.link
            navigate={~p"/playbooks/new/blank"}
            id="start-blank"
            class="new-card-go btn btn-block mt-4"
          >
            Start blank
          </.link>
        </section>

        <%!-- Describe --%>
        <section
          id="new-describe"
          class="new-card flex flex-col rounded-box border border-base-300 bg-base-200 p-5 focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/15"
        >
          <span class="flex size-9 items-center justify-center rounded-lg bg-secondary/10 text-secondary">
            <.icon name="hero-sparkles" class="size-5" />
          </span>
          <h3 class="mt-3 font-semibold">Describe it to an agent</h3>
          <p class="text-sm text-base-content/60">
            Say how the work should go. An agent drafts the steps for you to check.
          </p>
          <label for="describe-text" class="sr-only">How the work should go</label>
          <textarea
            id="describe-text"
            name="describe"
            rows="6"
            phx-debounce="300"
            placeholder="e.g. When I tag a release, collect the merged PRs, draft release notes, have the reviewer check them against the PRs, then let me approve before anything is published."
            class="textarea mt-4 w-full flex-1 text-sm"
          >{@describe}</textarea>
          <div class="mt-2 flex items-center gap-2 text-sm">
            <label for="describe-drafter" class="text-base-content/60">Drafted by</label>
            <select id="describe-drafter" name="drafter" class="select select-sm min-w-0 flex-1">
              <option
                :for={agent <- @active_agents}
                value={agent.name}
                selected={@drafter && @drafter.name == agent.name}
              >
                @{agent.name}
              </option>
            </select>
          </div>
          <button
            type="button"
            id="describe-playbook"
            class="new-card-go btn btn-block mt-4"
            phx-click="describe"
            disabled={is_nil(@drafter)}
          >
            Ask {if @drafter, do: "@#{@drafter.name}", else: "an agent"}
          </button>
        </section>
      </.form>

      <p class="text-center text-sm text-base-content/60">
        Have a playbook file? <.link navigate={~p"/agents/import"} class="link">Import it</.link>
      </p>
    </Layouts.page>
    """
  end

  defp start_page(assigns) do
    ~H"""
    <Layouts.page title={title(@playbook)} subtitle="Start a run" max_width="max-w-6xl">
      <:actions>
        <.link navigate={~p"/playbooks"} id="cancel-start" class="btn btn-ghost btn-sm">Cancel</.link>
      </:actions>

      <p
        :if={!@playbook.enabled}
        id="start-disabled"
        class="rounded-box border border-warning/40 bg-warning/5 px-4 py-3 text-sm"
      >
        {title(@playbook)} is disabled.
        <.link navigate={~p"/playbooks/#{@playbook.id}/edit"} class="link">Enable it</.link>
        first.
      </p>
      <p :if={is_nil(@definition)} class="text-sm text-error">
        This playbook has problems.
        <.link navigate={~p"/playbooks/#{@playbook.id}/edit"} class="link">Open it</.link>
        to see them.
      </p>

      <div :if={@definition} class="grid items-start gap-4 lg:grid-cols-[1fr_360px]">
        <.form
          for={@start_form}
          id="start-run-form"
          phx-change="start_validate"
          phx-submit="start_playbook"
          class="rounded-box border border-base-300 bg-base-200 p-5 sm:p-6"
        >
          <label for="start-brief" class="block font-semibold">What's this run about?</label>
          <p
            :if={@definition.inputs}
            id="start-inputs"
            class="mt-0.5 whitespace-pre-line text-xs text-base-content/60"
          >
            {@definition.inputs}
          </p>
          <textarea
            id="start-brief"
            name="start[brief]"
            rows="4"
            phx-debounce="300"
            class="textarea mt-2 w-full text-[15px]"
            placeholder="What this run is about"
          >{@start_form[:brief].value}</textarea>

          <dl class="mt-5 grid gap-x-4 gap-y-4 text-sm md:grid-cols-[112px_1fr] md:items-center">
            <dt class="text-base-content/60">Runs in</dt>
            <dd class="flex flex-col gap-2">
              <span :if={@always_new} id="start-runs-in-new" class="text-sm">
                <input type="hidden" name="start[runs_in]" value="new" /> A new channel
              </span>
              <div :if={!@always_new} class="join" role="radiogroup" aria-label="Runs in">
                <label class={[
                  "btn join-item btn-sm border-base-300",
                  @start_form[:runs_in].value == "new" &&
                    "btn-active bg-base-200 font-medium shadow-sm",
                  @start_form[:runs_in].value != "new" &&
                    "bg-base-100 font-normal text-base-content/70"
                ]}>
                  <input
                    type="radio"
                    name="start[runs_in]"
                    value="new"
                    checked={@start_form[:runs_in].value == "new"}
                    class="sr-only"
                  /> A new channel
                </label>
                <label class={[
                  "btn join-item btn-sm border-base-300",
                  @start_form[:runs_in].value == "current" &&
                    "btn-active bg-base-200 font-medium shadow-sm",
                  @start_form[:runs_in].value != "current" &&
                    "bg-base-100 font-normal text-base-content/70"
                ]}>
                  <input
                    type="radio"
                    name="start[runs_in]"
                    value="current"
                    checked={@start_form[:runs_in].value == "current"}
                    class="sr-only"
                  /> A channel that exists
                </label>
              </div>
              <div
                :if={@start_form[:runs_in].value == "new"}
                class="flex flex-wrap items-center gap-2"
              >
                <span class="flex min-w-0 flex-1 items-center gap-2">
                  <span class="text-base-content/45">#</span>
                  <input
                    type="hidden"
                    name="start[channel_name_touched]"
                    value={@start_form[:channel_name_touched].value}
                  />
                  <input
                    id="start-channel-name"
                    name="start[channel_name]"
                    type="text"
                    value={@start_form[:channel_name].value}
                    phx-debounce="300"
                    aria-label="New channel name"
                    class="input input-sm min-w-0 flex-1 font-medium"
                    phx-focus={
                      JS.set_attribute({"value", "true"}, to: "[name='start[channel_name_touched]']")
                    }
                  />
                </span>
                <span class="text-xs text-base-content/50">new, in</span>
                <select
                  id="start-repository"
                  name="start[repository_id]"
                  class="select select-sm w-48"
                  aria-label="Repository"
                >
                  <option
                    :for={repo <- @start_repositories}
                    value={repo.id}
                    selected={repo.id == @start_form[:repository_id].value}
                  >
                    {repo.name}
                  </option>
                </select>
              </div>
              <select
                :if={@start_form[:runs_in].value != "new"}
                id="start-channel"
                name="start[channel_id]"
                class="select select-sm w-80 max-w-full"
                aria-label="Channel"
              >
                <option
                  :for={{label, id} <- @start_channels}
                  value={id}
                  selected={id == @start_form[:channel_id].value}
                >
                  {label}
                </option>
              </select>
            </dd>

            <dt><label for="start-coordinator" class="text-base-content/60">Led by</label></dt>
            <dd>
              <select
                id="start-coordinator"
                name="start[coordinator_id]"
                class="select select-sm w-80 max-w-full"
              >
                <option value="" selected={@start_form[:coordinator_id].value in [nil, ""]}>
                  Pick a lead
                </option>
                <option
                  :for={agent <- @active_agents}
                  value={agent.id}
                  selected={agent.id == @start_form[:coordinator_id].value}
                >
                  @{agent.name}
                </option>
              </select>
            </dd>

            <dt :if={@start_rows != []} class="self-start pt-1.5 text-base-content/60">
              Who does what
            </dt>
            <dd :if={@start_rows != []} class="flex flex-col divide-y divide-base-300">
              <div
                :for={row <- @start_rows}
                id={"start-role-#{row.role}"}
                class="grid grid-cols-[112px_192px_1fr] items-center gap-3 py-1.5"
              >
                <span class="flex items-center gap-2">
                  <.avatar agent={row.agent} />
                  <label for={"start-role-#{row.role}-agent"} class="font-medium">{PlaybookBuilder.humanize(
                    row.role
                  )}</label>
                </span>
                <select
                  id={"start-role-#{row.role}-agent"}
                  name={"start[roles][#{row.role}]"}
                  class="select select-sm"
                >
                  <option
                    :if={!row.agent}
                    value=""
                    selected={@start_form[:roles].value[row.role] in [nil, ""]}
                  >
                    Pick an agent
                  </option>
                  <option
                    :for={agent <- @active_agents}
                    value={agent.name}
                    selected={agent.name == @start_form[:roles].value[row.role]}
                  >
                    @{agent.name}
                  </option>
                </select>
                <span class={[
                  "text-xs",
                  row.agent && "text-base-content/50",
                  !row.agent && "text-warning"
                ]}>
                  {if row.agent && @start_form[:roles].value[row.role] != row.agent.name,
                    do: "your pick",
                    else: row.source}
                </span>
              </div>
            </dd>
          </dl>

          <div class="mt-5 flex flex-wrap items-center gap-3 border-t border-base-300 pt-4">
            <button
              type="submit"
              id="start-playbook-submit"
              class="btn btn-primary"
              disabled={!@playbook.enabled}
            >
              <.icon name="hero-play-mini" class="size-4" /> Start run
            </button>
            <.link navigate={~p"/playbooks"} class="btn btn-ghost">Cancel</.link>
            <p id="start-consequence" class="min-w-0 flex-1 text-xs text-base-content/60">
              {consequence(@start_form, @active_agents, @definition)}
            </p>
          </div>
        </.form>

        <aside id="start-preview" class="rounded-box border border-base-300 bg-base-200 p-5">
          <h2 class="font-semibold">What will happen</h2>
          <p class="text-xs text-base-content/55">
            {title(@playbook)} · {length(@definition.steps)} steps · {stall_text(
              @definition.stall_after
            )}
          </p>
          <ol class="mt-3 flex flex-col divide-y divide-base-300 text-sm">
            <li
              :for={{step, n} <- Enum.with_index(@definition.steps, 1)}
              class="flex items-center gap-2 py-2"
            >
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-base-100 text-[10px] text-base-content/60">{n}</span>
              <span class="min-w-0 flex-1">
                {step.title}
                <span :if={step.on_reject} class="text-xs text-secondary">↩︎ {(Definition.step(
                                                                                @definition,
                                                                                step.on_reject
                                                                              ) ||
                                                                                %{
                                                                                  title:
                                                                                    step.on_reject
                                                                                }).title}</span>
                <span
                  :if={step.approval}
                  class="rounded-full bg-warning/10 px-1.5 text-[11px] font-medium text-warning"
                >you approve</span>
                <span :if={step.optional} class="text-[11px] text-base-content/50">may be skipped</span>
              </span>
              <span class="shrink-0 text-xs text-base-content/60">{step_agents(
                step,
                @start_form,
                @active_agents
              )}</span>
            </li>
          </ol>
          <.link navigate={~p"/playbooks/#{@playbook.id}/edit"} class="link mt-3 inline-block text-sm">Edit the playbook</.link>
        </aside>
      </div>
    </Layouts.page>
    """
  end
end
