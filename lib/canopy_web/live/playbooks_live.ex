defmodule CanopyWeb.PlaybooksLive do
  @moduledoc """
  The playbook library, in four pages under one LiveView:

    * `/playbooks` — every playbook: name, description, where it came from,
      enabled, runs in progress; Start, Edit, Duplicate, Delete
    * `/playbooks/new` and `/playbooks/:id/edit` — one textarea with the
      Markdown, the reasons it does not parse as you type, and a preview of
      its steps
    * `/playbooks/:id/start` — start a run in a channel

  Playbooks are global to Canopy. An enabled playbook is listed in every
  agent's system prompt, so a draft an agent saved stays disabled until the
  user enables it here.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Channels, Playbooks}
  alias Canopy.Playbooks.{Definition, Playbook, Runs}
  alias CanopyWeb.{PlaybookComponents, PlaybookStart}

  @template """
  ---
  name: my-playbook
  description: One sentence saying when to use this playbook.
  roles:
    dev: backend
  steps:
    - id: plan
      title: Plan the work
      owner: coordinator
    - id: build
      title: Build it
      owner: dev
    - id: sign-off
      title: User sign-off
      owner: coordinator
      approval: user
  ---

  Ground rules for the whole run: what the channel task holds, how steps are
  handed out, what nobody does without asking.

  ## plan

  What the coordinator does first.

  Done when: the plan is in the channel task.

  ## build

  Delegate to the dev role: what to build and how to check it.

  Done when: the dev reports the change and the tests that cover it.

  ## sign-off

  Post a summary for the user, then advance: Canopy holds the step for their approval.
  """

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Playbooks.subscribe()
      Runs.subscribe()
    end

    {:ok,
     socket
     |> assign(:playbook, nil)
     |> assign(:definition, nil)
     |> assign(:warnings, [])
     |> load_list()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case {socket.assigns.live_action, params} do
      {:index, _} ->
        {:noreply, socket |> assign(:playbook, nil) |> assign(:page_title, "Playbooks")}

      {:new, _} ->
        {:noreply,
         socket
         |> assign(:playbook, nil)
         |> assign(:page_title, "New playbook")
         |> assign_form(%Playbook{}, %{"body" => @template})}

      {action, %{"id" => id}} when action in [:edit, :start] ->
        case Playbooks.get(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That playbook no longer exists.")
             |> push_navigate(to: ~p"/playbooks")}

          playbook when action == :edit ->
            {:noreply,
             socket
             |> assign(:playbook, playbook)
             |> assign(:page_title, "Edit " <> playbook.name)
             |> assign_form(playbook, %{"body" => playbook.body})}

          playbook ->
            {:noreply,
             socket
             |> assign(:playbook, playbook)
             |> assign(:page_title, "Start " <> playbook.name)
             |> assign_start(%{"playbook_id" => playbook.id})}
        end
    end
  end

  @impl true
  def handle_info({:playbooks, :changed}, socket), do: {:noreply, load_list(socket)}

  def handle_info({:playbook_runs, :changed, _channel_id}, socket),
    do: {:noreply, assign(socket, :run_counts, Playbooks.active_run_counts())}

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

  # -- Editor ------------------------------------------------------------------------

  def handle_event("validate", %{"playbook" => params}, socket) do
    {:noreply, assign_form(socket, socket.assigns.playbook || %Playbook{}, params, :validate)}
  end

  def handle_event("save", %{"playbook" => params}, socket) do
    editing = socket.assigns.playbook
    attrs = Map.take(params, ["body"])

    result =
      if editing,
        do: Playbooks.update(editing, attrs),
        else: Playbooks.create(Map.merge(attrs, %{"source" => "user"}))

    case result do
      {:ok, playbook} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{if editing, do: "Saved", else: "Created"} #{playbook.name}.")
         |> push_navigate(to: ~p"/playbooks")}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        socket = assign(socket, :form, to_form(changeset, id: "playbook-form"))

        if Keyword.has_key?(errors, :lock_version),
          do:
            {:noreply,
             put_flash(
               socket,
               :error,
               "This playbook changed since you opened it; reload it first."
             )},
          else: {:noreply, socket}
    end
  end

  # -- Start ---------------------------------------------------------------------------

  def handle_event("start_validate", %{"start" => params}, socket),
    do: {:noreply, assign_start(socket, params)}

  def handle_event("start_playbook", %{"start" => params}, socket) do
    case PlaybookStart.start(params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Started #{run.playbook_name} in ##{run.channel.name}.")
         |> push_navigate(to: ~p"/channels/#{run.channel_id}")}

      {:error, reason} ->
        {:noreply, socket |> assign_start(params) |> put_flash(:error, reason)}
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
    socket
    |> assign(:playbooks, Playbooks.list())
    |> assign(:run_counts, Playbooks.active_run_counts())
  end

  defp assign_form(socket, playbook, params, action \\ nil) do
    changeset = playbook |> Playbooks.change(params) |> Map.put(:action, action)

    {definition, warnings} =
      case Definition.parse(params["body"]) do
        {:ok, definition} -> {definition, definition.warnings}
        {:error, _} -> {nil, []}
      end

    socket
    |> assign(:form, to_form(changeset, id: "playbook-form"))
    |> assign(:definition, definition)
    |> assign(:warnings, warnings)
  end

  defp assign_start(socket, params) do
    playbooks =
      case socket.assigns.playbook do
        %Playbook{enabled: true} = playbook -> [playbook]
        _ -> []
      end

    socket
    |> assign(:start_playbooks, playbooks)
    |> assign(:start_agents, Agents.list_active())
    |> assign(:start_channels, channel_options())
    |> assign(:start_form, PlaybookStart.form(params, playbooks))
  end

  # open channels, by repository; DMs keep their agents, so they are left out
  defp channel_options do
    Channels.list()
    |> Enum.reject(&(Channels.dm?(&1) or Channels.archived?(&1)))
    |> Enum.map(&{"##{&1.name} · #{&1.repository.name}", &1.id})
  end

  defp body_errors(form) do
    if form.source.action != nil,
      do: Enum.map(form[:body].errors, &translate_error/1),
      else: []
  end

  defp step_titles(playbook) do
    case Playbooks.definition(playbook) do
      {:ok, d} -> Enum.map_join(d.steps, " → ", & &1.title)
      {:error, _} -> "does not parse"
    end
  end

  defp source_label(%Playbook{source: "agent", enabled: false, created_by: %{name: name}}),
    do: "draft by @#{name}"

  defp source_label(%Playbook{source: "agent", enabled: false}), do: "agent draft"
  defp source_label(%Playbook{source: "agent", created_by: %{name: name}}), do: "by @#{name}"
  defp source_label(%Playbook{source: "agent"}), do: "by an agent"
  defp source_label(%Playbook{source: "seed"}), do: "starter"
  defp source_label(%Playbook{}), do: "yours"

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
    >
      <%= case @live_action do %>
        <% :index -> %>
          <.index_page {assigns} />
        <% :start -> %>
          <.start_page {assigns} />
        <% _ -> %>
          <.form_page {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp index_page(assigns) do
    ~H"""
    <Layouts.page
      title="Playbooks"
      subtitle="Reusable processes a coordinator agent runs step by step, with Canopy keeping track"
    >
      <:actions>
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

      <Layouts.panel
        :if={@playbooks != []}
        id="playbooks-panel"
        title="Library"
        description="Enabled playbooks are listed in every agent's prompt. A run keeps the text it started with, so editing never moves a run in progress."
      >
        <ul id="playbooks" class="divide-y divide-base-300">
          <li
            :for={playbook <- @playbooks}
            id={"playbook-#{playbook.id}"}
            data-enabled={to_string(playbook.enabled)}
            class={["flex flex-col gap-1.5 py-3", !playbook.enabled && "opacity-70"]}
          >
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-mono text-sm font-semibold">{playbook.name}</span>
              <span class={[
                "rounded-full px-1.5 text-[10px] font-medium uppercase tracking-wide",
                playbook.source == "agent" && "bg-warning/15 text-warning",
                playbook.source != "agent" && "bg-base-300/70 text-base-content/60"
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
                  /> enabled
                </label>
                <.link
                  :if={playbook.enabled}
                  navigate={~p"/playbooks/#{playbook.id}/start"}
                  id={"start-playbook-#{playbook.id}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-play-mini" class="size-3.5" /> Start…
                </.link>
                <.link
                  navigate={~p"/playbooks/#{playbook.id}/edit"}
                  id={"edit-playbook-#{playbook.id}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-pencil-square-mini" class="size-3.5" /> Edit
                </.link>
                <button
                  type="button"
                  id={"duplicate-playbook-#{playbook.id}"}
                  class="btn btn-ghost btn-xs"
                  phx-click="duplicate"
                  phx-value-id={playbook.id}
                  title="Duplicate"
                >
                  <.icon name="hero-document-duplicate-mini" class="size-3.5" />
                </button>
                <button
                  type="button"
                  id={"delete-playbook-#{playbook.id}"}
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete"
                  phx-value-id={playbook.id}
                  data-canopy-confirm="Finished runs keep their own copy of the text."
                  data-canopy-confirm-title={"Delete #{playbook.name}?"}
                  data-canopy-confirm-label="Delete"
                  title="Delete"
                >
                  <.icon name="hero-trash-mini" class="size-3.5" />
                </button>
              </div>
            </div>
            <p class="text-xs text-base-content/75">{playbook.description}</p>
            <p class="text-[11px] text-base-content/55">{step_titles(playbook)}</p>
          </li>
        </ul>
      </Layouts.panel>
    </Layouts.page>
    """
  end

  defp form_page(assigns) do
    ~H"""
    <Layouts.page
      title={if @playbook, do: "Edit #{@playbook.name}", else: "New playbook"}
      subtitle="Markdown with YAML frontmatter: the roles and steps, then a ## section per step"
      max_width="max-w-5xl"
    >
      <:actions>
        <.link navigate={~p"/playbooks"} id="cancel-playbook" class="btn btn-ghost btn-sm">
          Cancel
        </.link>
      </:actions>

      <div class="grid gap-4 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <Layouts.panel id="playbook-form-panel" title="Text">
          <.form
            for={@form}
            id="playbook-form"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-3"
          >
            <textarea
              id="playbook-body"
              name="playbook[body]"
              rows="28"
              phx-debounce="300"
              spellcheck="false"
              class="textarea w-full font-mono text-xs leading-relaxed"
              aria-label="Playbook text"
            >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
            <ul :if={body_errors(@form) != []} id="playbook-errors" class="flex flex-col gap-1">
              <li :for={msg <- body_errors(@form)} class="flex items-start gap-2 text-sm text-error">
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {msg}
              </li>
            </ul>
            <ul :if={@warnings != []} id="playbook-warnings" class="flex flex-col gap-1">
              <li :for={msg <- @warnings} class="flex items-start gap-2 text-xs text-warning">
                <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
                {msg}
              </li>
            </ul>
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" id="save-playbook">
                {if @playbook, do: "Save playbook", else: "Create playbook"}
              </.button>
              <.link navigate={~p"/playbooks"} class="btn btn-ghost">Cancel</.link>
            </div>
          </.form>
        </Layouts.panel>

        <Layouts.panel
          id="playbook-preview-panel"
          title="Steps"
          description="What a run will track. Owners are roles; the coordinator is whoever runs it."
        >
          <PlaybookComponents.definition_preview :if={@definition} definition={@definition} />
          <p :if={is_nil(@definition)} id="playbook-preview-none" class="text-xs text-base-content/60">
            Fix the text to see its steps.
          </p>
        </Layouts.panel>
      </div>
    </Layouts.page>
    """
  end

  defp start_page(assigns) do
    ~H"""
    <Layouts.page
      title={"Start #{@playbook.name}"}
      subtitle={@playbook.description}
    >
      <:actions>
        <.link navigate={~p"/playbooks"} id="cancel-start" class="btn btn-ghost btn-sm">
          Cancel
        </.link>
      </:actions>

      <Layouts.panel
        id="start-panel"
        title="New run"
        description="The coordinator is woken with the brief and drives the steps; you approve the steps that need your sign-off."
      >
        <p :if={!@playbook.enabled} id="start-disabled" class="text-sm text-warning">
          {@playbook.name} is disabled. Enable it in the library first.
        </p>
        <PlaybookComponents.start_form
          form={@start_form}
          playbooks={@start_playbooks}
          agents={@start_agents}
          channels={@start_channels}
        />
      </Layouts.panel>
    </Layouts.page>
    """
  end
end
