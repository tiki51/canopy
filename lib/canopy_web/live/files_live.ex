defmodule CanopyWeb.FilesLive do
  @moduledoc """
  Every document shared in the workspace: what it is, who shared it, where it
  has been posted, with download, "share to" another chat, and delete.
  """

  use CanopyWeb, :live_view

  import CanopyWeb.TimelineComponents, only: [short_time: 1]

  alias Canopy.{Channels, Documents}

  @kinds [
    {"all", "All"},
    {"image", "Images"},
    {"text", "Text"},
    {"pdf", "PDF"},
    {"other", "Other"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Documents.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Files")
     |> assign(:search, "")
     |> assign(:kind, "all")
     |> assign(:kinds, @kinds)
     |> assign(:targets, share_targets())
     |> load_rows()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:search, Map.get(params, "q", socket.assigns.search))
     |> load_rows()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:search, Map.get(params, "q", ""))
     |> assign(:kind, Map.get(params, "kind", "all"))
     |> load_rows()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Documents.get(id) do
      nil ->
        {:noreply, load_rows(socket)}

      document ->
        {:ok, _} = Documents.delete(document)

        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{document.filename}.")
         |> load_rows()}
    end
  end

  def handle_event("share", %{"document_id" => id, "channel_id" => channel_id}, socket)
      when channel_id != "" do
    {:noreply, push_navigate(socket, to: ~p"/channels/#{channel_id}?attach=#{id}")}
  end

  def handle_event("share", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:document_deleted, _id, _message_ids}, socket),
    do: {:noreply, load_rows(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_rows(socket) do
    %{search: search, kind: kind} = socket.assigns
    kind = if kind == "all", do: nil, else: kind

    rows =
      [search: search, kind: kind, limit: 200]
      |> Documents.list()
      |> Enum.map(fn document ->
        %{
          document: document,
          usages: Documents.usages(document),
          sharer: sharer(document)
        }
      end)

    socket
    |> assign(:rows, rows)
    |> assign(:total_bytes, Documents.total_bytes())
    |> assign(:count, Documents.count())
  end

  defp sharer(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp sharer(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp sharer(_), do: "unknown"

  # Channels and DMs a document can be shared into, grouped for a select.
  defp share_targets do
    channels =
      Channels.list()
      |> Enum.reject(&(&1.kind == "dm" or Channels.archived?(&1)))
      |> Enum.map(&{&1.id, "#" <> &1.name})

    dms = Channels.list_dms() |> Enum.map(&{&1.id, Channels.dm_label(&1)})
    [{"Channels", channels}, {"Direct messages", dms}]
  end

  defp channel_label(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp channel_label(channel), do: "#" <> channel.name

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
        title="Files"
        subtitle="Everything shared in chats, by you or by agents. A file is uploaded once and can be posted anywhere."
        max_width="max-w-5xl"
      >
        <Layouts.panel
          id="files-panel"
          title="Shared files"
          description={"#{@count} file(s), #{Documents.size_label(@total_bytes)} on disk"}
        >
          <:actions>
            <form id="files-filter" phx-change="filter" class="flex flex-wrap items-center gap-2">
              <input
                type="search"
                name="q"
                value={@search}
                placeholder="Search by name"
                class="input input-sm w-48"
                phx-debounce="200"
                autocomplete="off"
              />
              <select name="kind" class="select select-sm w-32">
                <option :for={{value, label} <- @kinds} value={value} selected={value == @kind}>
                  {label}
                </option>
              </select>
            </form>
          </:actions>

          <Layouts.empty_state
            :if={@rows == []}
            id="files-empty"
            icon="hero-paper-clip"
            title="No files yet"
          >
            Paste a screenshot or drop a file into any channel's composer to share it.
          </Layouts.empty_state>

          <ul :if={@rows != []} id="files" class="divide-y divide-base-300">
            <li
              :for={row <- @rows}
              id={"file-#{row.document.id}"}
              class="flex items-center gap-4 py-3 first:pt-0 last:pb-0"
              data-kind={row.document.kind}
            >
              <a
                href={Documents.url_path(row.document)}
                target="_blank"
                rel="noopener"
                class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-200 text-base-content/60"
              >
                <img
                  :if={row.document.kind == "image"}
                  src={Documents.url_path(row.document)}
                  alt=""
                  loading="lazy"
                  class="size-12 object-cover"
                />
                <.icon
                  :if={row.document.kind != "image"}
                  name={kind_icon(row.document.kind)}
                  class="size-6"
                />
              </a>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <a
                    href={Documents.url_path(row.document)}
                    target="_blank"
                    rel="noopener"
                    class="truncate text-sm font-semibold hover:underline"
                  >
                    {row.document.filename}
                  </a>
                  <span class="badge badge-ghost badge-sm">{row.document.kind}</span>
                  <span class="text-xs text-base-content/60">
                    {Documents.size_label(row.document.byte_size)}
                  </span>
                </div>
                <div class="mt-0.5 truncate text-xs text-base-content/60">
                  {row.sharer} · {short_date(row.document.inserted_at)}
                  <span :if={row.usages != []}>
                    · in
                    <.link
                      :for={usage <- Enum.uniq_by(row.usages, & &1.channel.id)}
                      navigate={~p"/channels/#{usage.channel.id}"}
                      class="link link-hover mr-1"
                    >
                      {channel_label(usage.channel)}
                    </.link>
                  </span>
                  <span :if={row.usages == []}>· not posted anywhere</span>
                </div>
                <div :if={row.document.caption} class="mt-0.5 truncate text-xs">
                  {row.document.caption}
                </div>
              </div>
              <form phx-submit="share" class="flex shrink-0 items-center gap-1">
                <input type="hidden" name="document_id" value={row.document.id} />
                <select
                  name="channel_id"
                  class="select select-xs w-40"
                  aria-label={"Share #{row.document.filename} to"}
                >
                  <option value="">Share to…</option>
                  <optgroup :for={{group, options} <- @targets} :if={options != []} label={group}>
                    <option :for={{id, label} <- options} value={id}>{label}</option>
                  </optgroup>
                </select>
                <button type="submit" class="btn btn-xs btn-ghost">Go</button>
              </form>
              <button
                type="button"
                id={"delete-file-#{row.document.id}"}
                class="btn btn-ghost btn-xs btn-square text-error"
                phx-click="delete"
                phx-value-id={row.document.id}
                data-confirm={"Delete #{row.document.filename}? It disappears from every message it is attached to."}
                title="Delete"
                aria-label={"Delete #{row.document.filename}"}
              >
                <.icon name="hero-trash-mini" class="size-4" />
              </button>
            </li>
          </ul>
        </Layouts.panel>
      </Layouts.page>
    </Layouts.app>
    """
  end

  defp kind_icon("text"), do: "hero-document-text"
  defp kind_icon("pdf"), do: "hero-document"
  defp kind_icon(_), do: "hero-paper-clip"

  defp short_date(%DateTime{} = at) do
    local = Canopy.Schedules.When.to_local_naive(at)
    Calendar.strftime(local, "%Y-%m-%d") <> " " <> short_time(at)
  end
end
