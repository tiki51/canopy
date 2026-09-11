defmodule CanopyWeb.RepositoriesLive do
  @moduledoc """
  Repositories: list the registered git repositories (with current branch and
  channel count), add one by absolute path, and delete.
  """
  use CanopyWeb, :live_view

  alias Canopy.Repositories
  alias Canopy.Repositories.Repository
  alias CanopyWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Repositories")
     |> assign(:home, System.user_home!())
     |> assign(:allow_outside_home, false)
     |> assign_form(Repositories.change(%Repository{}))
     |> load_rows()}
  end

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
                navigate={~p"/channels/new?repository_id=#{row.repository.id}"}
                class="btn btn-ghost btn-xs"
                title="New channel in this repository"
              >
                <.icon name="hero-plus" class="size-4" /> Channel
              </.link>
              <button
                type="button"
                id={"delete-repository-#{row.repository.id}"}
                class="btn btn-ghost btn-xs text-error opacity-60 transition group-hover:opacity-100"
                phx-click="delete"
                phx-value-id={row.repository.id}
                data-canopy-confirm={"Remove #{row.repository.name} from Canopy? Its #{row.channel_count} channel(s) and their history are deleted. Files on disk are not touched."}
                title="Remove repository"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
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
end
