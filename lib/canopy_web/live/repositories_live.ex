defmodule CanopyWeb.RepositoriesLive do
  @moduledoc """
  Repositories: list the registered git repositories (with current branch and
  channel count), add one by absolute path, and delete.

  `/repositories/:id` shows one repository and the MCP servers its agents get
  from each engine (`Canopy.MCP.Inventory`, already redacted), loaded in the
  background on mount, on Refresh, and when the MCP token rotates; never
  polled. OpenCode's section carries the actions: re-register Canopy,
  reconnect a failed server, reinstall the identity plugin.
  """
  use CanopyWeb, :live_view

  alias Canopy.{Channels, MCP, Repositories, Runtime, Settings}
  alias Canopy.Engine.OpenCode
  alias Canopy.MCP.Redact
  alias Canopy.Repositories.Repository
  alias CanopyWeb.Nav

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :home, System.user_home!())

    case socket.assigns.live_action do
      :show -> {:ok, mount_show(socket, params["id"])}
      _ -> {:ok, mount_index(socket)}
    end
  end

  defp mount_index(socket) do
    socket
    |> assign(:page_title, "Repositories")
    |> assign(:allow_outside_home, false)
    |> assign_form(Repositories.change(%Repository{}))
    |> load_rows()
  end

  defp mount_show(socket, id) do
    repository = Repositories.get!(id)
    if connected?(socket), do: Settings.subscribe()

    socket
    |> assign(:page_title, repository.name)
    |> assign(:repository, repository)
    |> assign(:branch, branch_of(repository))
    |> assign(:missing?, not File.dir?(repository.path))
    |> assign(:channel_count, length(Channels.list_by_repository(repository.id)))
    |> assign(:expanded, MapSet.new())
    |> load_inventory()
  end

  # File reads and engine calls happen in the async task, never in mount.
  defp load_inventory(socket) do
    repository = socket.assigns.repository

    socket
    |> assign(:busy?, busy?(repository))
    |> assign_async(
      :inventory,
      fn ->
        {:ok, %{inventory: MCP.Inventory.for_repository(repository)}}
      end,
      reset: true
    )
  end

  # Any agent with a turn in flight (or waiting) in one of the repository's channels.
  defp busy?(repository) do
    repository.id
    |> Channels.list_by_repository()
    |> Enum.any?(fn channel ->
      channel.id |> Runtime.status() |> Map.values() |> Enum.any?(&(&1 != :idle))
    end)
  end

  @impl true
  def handle_info({:settings, :mcp_token_rotated}, socket), do: {:noreply, load_inventory(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", params, socket) do
    repository_params = Map.get(params, "repository", %{})

    changeset =
      %Repository{}
      |> Repositories.change(repository_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:allow_outside_home, truthy?(params["allow_outside_home"]))
     |> assign_form(changeset)}
  end

  def handle_event("save", params, socket) do
    repository_params = Map.get(params, "repository", %{})
    allow_outside_home = truthy?(params["allow_outside_home"])

    initialised? = Repositories.needs_init?(repository_params["path"])

    case Repositories.create(repository_params, allow_outside_home: allow_outside_home) do
      {:ok, repository} ->
        note =
          if initialised?,
            do: " It was not a git repository yet, so one was initialised.",
            else: ""

        {:noreply,
         socket
         |> assign(:allow_outside_home, false)
         |> assign_form(Repositories.change(%Repository{}))
         |> load_rows()
         |> Nav.refresh_nav()
         |> put_flash(:info, "Added #{repository.name}.#{note}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:allow_outside_home, allow_outside_home)
         |> assign_form(changeset)}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_inventory(socket)}

  def handle_event("toggle_engine", %{"engine" => engine}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, engine),
        do: MapSet.delete(expanded, engine),
        else: MapSet.put(expanded, engine)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("reregister", _params, socket) do
    socket.assigns.repository
    |> OpenCode.reregister()
    |> action_done(socket, "Canopy re-registered with OpenCode for this repository.")
  end

  def handle_event("reconnect", %{"name" => name}, socket) do
    socket.assigns.repository
    |> OpenCode.reconnect(name)
    |> action_done(socket, "OpenCode reconnected #{name}.")
  end

  def handle_event("reinstall_plugin", _params, socket) do
    repository = socket.assigns.repository

    if busy?(repository) do
      {:noreply,
       socket
       |> assign(:busy?, true)
       |> put_flash(:error, "An agent is working in this repository; try again when it is idle.")}
    else
      repository
      |> OpenCode.reinstall_plugin()
      |> action_done(socket, "Identity plugin reinstalled; OpenCode reloaded this repository.")
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    repository = Repositories.get!(id)

    case Repositories.delete(repository) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_rows()
         |> Nav.refresh_nav()
         |> put_flash(:info, "Removed #{repository.name}.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not remove #{repository.name}.")}
    end
  end

  defp action_done(:ok, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> load_inventory()}

  defp action_done({:error, reason}, socket, _message),
    do:
      {:noreply,
       socket
       |> put_flash(:error, "OpenCode refused: #{action_error(reason)}")
       |> load_inventory()}

  defp action_error({:http, status, _body}), do: "HTTP #{status}"
  defp action_error({:transport, _reason}), do: "it did not answer"
  defp action_error(:not_connected), do: "the server still could not connect"
  defp action_error(reason), do: Redact.text(inspect(reason))

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, id: "repository-form"))
  end

  defp load_rows(socket) do
    rows =
      Enum.map(Repositories.list_with_channels(), fn repository ->
        %{
          repository: repository,
          branch: branch_of(repository),
          channel_count: length(repository.channels),
          missing?: not File.dir?(repository.path)
        }
      end)

    assign(socket, :rows, rows)
  end

  defp branch_of(repository) do
    case Repositories.current_branch(repository) do
      {:ok, branch} -> branch
      {:error, _} -> nil
    end
  end

  defp truthy?(value), do: value in ["true", "on", true]

  defp pretty_path(path, home) do
    if String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: show_page(assigns)

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
      <Layouts.page title="Repositories" subtitle="Local git repositories that channels work in">
        <Layouts.panel
          id="repositories-panel"
          title="Registered repositories"
          description="Every channel belongs to one repository; agents run inside its working tree."
        >
          <Layouts.empty_state
            :if={@rows == []}
            id="repositories-empty"
            icon="hero-folder-open"
            title="No repositories yet"
          >
            Add the absolute path of a project folder below to get started.
          </Layouts.empty_state>

          <ul :if={@rows != []} id="repositories" class="divide-y divide-base-300">
            <li
              :for={row <- @rows}
              id={"repository-#{row.repository.id}"}
              class="group flex items-center gap-4 py-3 first:pt-0 last:pb-0"
            >
              <div class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 text-base-content/60">
                <.icon name="hero-folder" class="size-5" />
              </div>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="truncate text-sm font-semibold">{row.repository.name}</span>
                  <span
                    :if={row.branch}
                    class="badge badge-ghost badge-sm gap-1 font-mono"
                    title="Current branch"
                  >
                    <.icon name="hero-code-bracket-mini" class="size-3" />
                    {row.branch}
                  </span>
                  <span :if={row.missing?} class="badge badge-error badge-soft badge-sm">
                    path missing
                  </span>
                </div>
                <div
                  class="truncate font-mono text-xs text-base-content/60"
                  title={row.repository.path}
                >
                  {pretty_path(row.repository.path, @home)}
                </div>
              </div>
              <div class="shrink-0 text-xs text-base-content/60">
                {row.channel_count}
                {if row.channel_count == 1, do: "channel", else: "channels"}
              </div>
              <.link
                navigate={~p"/repositories/#{row.repository.id}"}
                id={"repository-mcp-#{row.repository.id}"}
                class="btn btn-ghost btn-xs"
                title="MCP servers agents get in this repository"
              >
                <.icon name="hero-puzzle-piece" class="size-4" /> MCP
              </.link>
              <.link
                navigate={~p"/channels/new?repository_id=#{row.repository.id}"}
                class="btn btn-ghost btn-xs"
                title="New channel in this repository"
              >
                <.icon name="hero-plus" class="size-4" /> Channel
              </.link>
              <.row_menu
                id={"repository-menu-#{row.repository.id}"}
                label={"More for #{row.repository.name}"}
              >
                <.row_menu_item
                  id={"delete-repository-#{row.repository.id}"}
                  icon="hero-trash-mini"
                  danger
                  phx-click="delete"
                  phx-value-id={row.repository.id}
                  data-canopy-confirm={"Remove #{row.repository.name} from Canopy? Its #{row.channel_count} channel(s) and their history are deleted. Files on disk are not touched."}
                >
                  Remove repository
                </.row_menu_item>
              </.row_menu>
            </li>
          </ul>
        </Layouts.panel>

        <Layouts.panel
          id="add-repository-panel"
          title="Add a repository"
          description="An absolute path to a project folder. If it is not a git repository yet, Canopy runs git init there; otherwise it never modifies it directly."
        >
          <.form
            for={@form}
            id="repository-form"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-3"
          >
            <.input
              field={@form[:path]}
              type="text"
              label="Absolute path"
              placeholder={Path.join(@home, "code/my-project")}
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:name]}
              type="text"
              label="Name (optional, defaults to the folder name)"
              autocomplete="off"
            />
            <.input
              type="checkbox"
              id="repository-allow-outside-home"
              name="allow_outside_home"
              value={@allow_outside_home}
              label="Allow a path outside my home directory"
            />
            <div>
              <.button type="submit" variant="primary" id="save-repository">
                <.icon name="hero-plus" class="size-4" /> Add repository
              </.button>
            </div>
          </.form>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end

  # -- Show page ----------------------------------------------------------------

  defp show_page(assigns) do
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
        title={@repository.name}
        subtitle={pretty_path(@repository.path, @home)}
        max_width="max-w-5xl"
      >
        <:actions>
          <.link navigate={~p"/repositories"} class="btn btn-ghost btn-sm" id="back-to-repositories">
            <.icon name="hero-arrow-left-mini" class="size-4" /> All repositories
          </.link>
        </:actions>

        <div id="repository-summary" class="flex flex-wrap items-center gap-2 text-xs">
          <span
            :if={@branch}
            class="badge badge-ghost badge-sm gap-1 font-mono"
            title="Current branch"
          >
            <.icon name="hero-code-bracket-mini" class="size-3" />
            {@branch}
          </span>
          <span :if={@missing?} class="badge badge-error badge-soft badge-sm">path missing</span>
          <span class="text-base-content/60">
            {@channel_count} {if @channel_count == 1, do: "channel", else: "channels"}
          </span>
        </div>

        <Layouts.panel id="repository-mcp-panel" title="MCP servers">
          <:subtitle>
            The tools each engine gives agents in this repository, and whether they work. Secrets
            are masked; Canopy's own token shows only its last 4 characters.
          </:subtitle>
          <:actions>
            <button
              type="button"
              id="refresh-mcp"
              class="btn btn-soft btn-sm"
              phx-click="refresh"
              disabled={@inventory.loading not in [nil, false]}
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </button>
          </:actions>

          <.async_result :let={inventory} assign={@inventory}>
            <:loading>
              <div id="mcp-loading" class="flex items-center gap-2 text-sm text-base-content/60">
                <span class="loading loading-spinner loading-xs"></span> Asking the engines…
              </div>
            </:loading>
            <:failed :let={_reason}>
              <div id="mcp-failed" class="alert alert-soft alert-error text-sm">
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                Could not build the MCP inventory. Try Refresh.
              </div>
            </:failed>

            <div class="flex flex-col gap-6">
              <div
                id="mcp-token"
                class="flex flex-wrap items-center gap-2 text-xs text-base-content/70"
              >
                <.icon name="hero-key-mini" class="size-4 text-base-content/50" /> Canopy's MCP token
                <code class="font-mono">{inventory.token}</code>
                <span class="text-base-content/50">·</span>
                <.link navigate={~p"/settings#mcp-panel"} id="mcp-rotate-link" class="link">
                  Reveal or rotate in Settings
                </.link>
              </div>

              <.engine_section
                :for={engine <- inventory.engines}
                engine={engine}
                open?={engine.in_use? or MapSet.member?(@expanded, engine.engine)}
                busy?={@busy?}
              />
            </div>
          </.async_result>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :engine, :map, required: true
  attr :open?, :boolean, required: true
  attr :busy?, :boolean, required: true

  defp engine_section(assigns) do
    ~H"""
    <section id={"mcp-engine-#{@engine.engine}"} class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <button
          type="button"
          id={"mcp-engine-#{@engine.engine}-toggle"}
          class="flex items-center gap-2 text-left"
          phx-click="toggle_engine"
          phx-value-engine={@engine.engine}
          disabled={@engine.in_use?}
        >
          <.icon
            :if={not @engine.in_use?}
            name={if @open?, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="size-4 text-base-content/50"
          />
          <h3 class="text-sm font-semibold">{Canopy.Engine.label(@engine.engine)}</h3>
          <span :if={not @engine.in_use?} class="text-xs text-base-content/60">
            No agent in this repository's channels uses {Canopy.Engine.label(@engine.engine)}
          </span>
        </button>
        <div :if={@open? and @engine.engine == "opencode"} class="flex items-center gap-2">
          <button
            type="button"
            id="mcp-reregister"
            class="btn btn-soft btn-xs"
            phx-click="reregister"
            title="Post Canopy's registration to OpenCode for this repository again"
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Re-register Canopy
          </button>
          <button
            type="button"
            id="mcp-reinstall-plugin"
            class="btn btn-soft btn-xs"
            phx-click="reinstall_plugin"
            disabled={@busy?}
            title={
              if @busy?,
                do: "An agent is working in this repository",
                else: "Rewrite the identity plugin and reload OpenCode for this repository"
            }
            data-canopy-confirm="Reinstall the identity plugin? OpenCode reloads this repository, which interrupts any OpenCode session running in it."
          >
            <.icon name="hero-wrench-screwdriver" class="size-4" /> Reinstall plugin
          </button>
        </div>
      </div>

      <div :if={@open?} class="flex flex-col gap-3">
        <div
          :if={not @engine.reachable?}
          id={"mcp-unreachable-#{@engine.engine}"}
          class="alert alert-soft alert-warning text-xs"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <span>
            {@engine.error || "Not reachable."} Showing what the config files say; status unknown.
          </span>
        </div>
        <div
          :if={@engine.reachable? and @engine.error}
          id={"mcp-error-#{@engine.engine}"}
          class="alert alert-soft alert-warning text-xs"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <span>{@engine.error}</span>
        </div>

        <dl
          :if={@engine.canopy != %{}}
          id={"mcp-canopy-#{@engine.engine}"}
          class="flex flex-wrap gap-x-6 gap-y-1 text-xs"
        >
          <div class="flex gap-1">
            <dt class="text-base-content/60">Registered by this Canopy run</dt>
            <dd class="font-medium">{yes_no(@engine.canopy[:registered_this_boot?])}</dd>
          </div>
          <div class="flex gap-1">
            <dt class="text-base-content/60">Identity plugin in the repository</dt>
            <dd id="mcp-plugin-state" class={["font-medium", plugin_class(@engine.canopy[:plugin])]}>
              {plugin_text(@engine.canopy[:plugin])}
            </dd>
          </div>
          <div class="flex gap-1">
            <dt class="text-base-content/60">Global plugin</dt>
            <dd class="font-medium">
              {if @engine.canopy[:global_plugin?], do: "installed", else: "not installed"}
            </dd>
          </div>
        </dl>

        <.server_table
          id={"mcp-servers-#{@engine.engine}"}
          engine={@engine.engine}
          servers={@engine.servers}
          actions?={@engine.engine == "opencode" and @engine.reachable?}
          row_prefix="mcp-server"
        />

        <ul :if={@engine.notes != []} id={"mcp-notes-#{@engine.engine}"} class="flex flex-col gap-1">
          <li :for={note <- @engine.notes} class="flex items-start gap-1.5 text-xs text-warning">
            <.icon name="hero-exclamation-triangle-mini" class="mt-px size-3.5 shrink-0" />
            <span class="min-w-0 wrap-anywhere">{note}</span>
          </li>
        </ul>

        <div
          :if={@engine.engine == "claude_code" and length(@engine.servers) > 1}
          id="mcp-claude-security"
          class="alert alert-soft alert-warning text-xs"
        >
          <.icon name="hero-shield-exclamation" class="size-4 shrink-0" />
          <span>
            The repository's <code class="font-mono">.mcp.json</code>
            servers start on every Claude Code turn, running commands from the repository,
            without Claude Code's usual approval prompt. Only keep servers there you trust.
          </span>
        </div>

        <div
          :if={@engine.ignored != []}
          id={"mcp-ignored-#{@engine.engine}"}
          class="flex flex-col gap-2"
        >
          <div>
            <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Configured but not loaded by Canopy agents
            </h4>
            <p :if={@engine.engine == "claude_code"} class="mt-0.5 text-xs text-base-content/60">
              Canopy runs Claude Code with <code class="font-mono">--strict-mcp-config</code>:
              agents load Canopy's server and this repository's <code class="font-mono">.mcp.json</code>, never your personal
              <code class="font-mono">~/.claude.json</code>
              servers.
            </p>
          </div>
          <.server_table
            id={"mcp-ignored-table-#{@engine.engine}"}
            engine={@engine.engine}
            servers={@engine.ignored}
            actions?={false}
            row_prefix="mcp-ignored"
            status?={false}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :engine, :string, required: true
  attr :servers, :list, required: true
  attr :actions?, :boolean, required: true
  attr :row_prefix, :string, required: true
  attr :status?, :boolean, default: true

  defp server_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
      <table id={@id} class="table table-sm">
        <thead>
          <tr class="text-xs text-base-content/60">
            <th>Server</th>
            <th :if={@status?}>Status</th>
            <th>Transport</th>
            <th>Command or URL</th>
            <th>Source</th>
            <th :if={@status?} class="text-right">Tools</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={server <- @servers}
            id={"#{@row_prefix}-#{@engine}-#{dom_name(server.name)}"}
            class="align-top"
          >
            <td class="min-w-32">
              <div class="font-mono text-xs font-semibold">{server.name}</div>
              <div :if={server.note} class="mt-0.5 text-xs text-base-content/60">{server.note}</div>
            </td>
            <td :if={@status?} class="min-w-28">
              <span
                class={["badge badge-sm", status_class(server.status)]}
                title={server.error || status_title(server)}
                data-status={server.status}
              >
                {status_text(server.status)}
              </span>
              <div :if={server.error} class="mt-1 max-w-56 break-words text-xs text-error">
                {server.error}
              </div>
              <button
                :if={
                  @actions? and server.status in [:failed, :needs_client_registration] and
                    server.source.kind != :canopy
                }
                type="button"
                id={"mcp-reconnect-#{dom_name(server.name)}"}
                class="btn btn-soft btn-xs mt-1"
                phx-click="reconnect"
                phx-value-name={server.name}
              >
                <.icon name="hero-arrow-path-mini" class="size-3.5" /> Reconnect
              </button>
            </td>
            <td class="text-xs text-base-content/70">{server.transport || "—"}</td>
            <td class="max-w-72">
              <code class="block truncate font-mono text-xs" title={server.target}>
                {server.target || "—"}
              </code>
              <div :if={server.secrets != []} class="mt-0.5 text-xs text-base-content/50">
                masked: {Enum.join(server.secrets, ", ")}
              </div>
            </td>
            <td>
              <%!-- plain text: the pills in a row are its status only --%>
              <span class="whitespace-nowrap text-xs text-base-content/70" title={server.source.path}>
                {source_text(server.source)}
              </span>
            </td>
            <td :if={@status?} class="text-right text-xs text-base-content/70">
              {server.tool_count || "—"}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp dom_name(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"

  defp plugin_text(:current), do: "current"
  defp plugin_text(:outdated), do: "outdated"
  defp plugin_text(_), do: "missing"

  defp plugin_class(:current), do: "text-success"
  defp plugin_class(_), do: "text-warning"

  defp status_text(:connected), do: "connected"
  defp status_text(:failed), do: "failed"
  defp status_text(:disabled), do: "disabled"
  defp status_text(:needs_auth), do: "needs auth"
  defp status_text(:needs_client_registration), do: "needs registration"
  defp status_text(_), do: "unknown"

  defp status_class(:connected), do: "badge-success badge-soft"

  defp status_class(s) when s in [:failed, :needs_auth, :needs_client_registration],
    do: "badge-error badge-soft"

  defp status_class(:disabled), do: "badge-neutral badge-soft"
  # unknown: the neutral badge, apart from the coloured states
  defp status_class(_), do: "badge-ghost"

  defp status_title(%{observed_at: %DateTime{} = at}),
    do: "As the newest turn reported at #{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC"

  defp status_title(%{status: :unknown}), do: "Not reported yet"
  defp status_title(_), do: nil

  defp source_text(%{kind: :canopy}), do: "Canopy runtime"
  defp source_text(%{kind: :server}), do: "OpenCode server"

  defp source_text(%{kind: :project, path: path}) when is_binary(path),
    do: "project · #{Path.basename(path)}"

  defp source_text(%{kind: kind, path: path}) when is_binary(path),
    do: "#{kind} · #{short_path(path)}"

  defp source_text(%{kind: kind}), do: to_string(kind)

  defp short_path(path) do
    home = System.user_home!()

    if String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end
end
