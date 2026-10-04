defmodule CanopyWeb.ThreadsLive do
  @moduledoc """
  The Threads inbox: threads across every channel, newest activity first, in
  three tabs: the ones you follow, every thread active in the last week, and
  the ones an agent is working in right now. Each row shows the root, the
  last two replies, who is in it, and what you have not read; Open thread
  goes to the channel with the thread in its side panel.

  The rows are a stream, reloaded when a thread gets a reply, an agent's turn
  moves, or a thread is read or followed elsewhere (`Canopy.Threads`). Which
  threads agents work in is asked of the channels once, on mount, and kept
  current from the turn messages.
  """

  use CanopyWeb, :live_view

  import CanopyWeb.TimelineComponents, only: [mini_avatar: 1, short_time: 1]

  alias Canopy.{Agents, Channels, Runtime, Threads, Users}
  alias Canopy.MCP.Format
  alias CanopyWeb.{ChannelLive, Nav}

  @tabs [
    {"following", "Following"},
    {"active", "All active"},
    {"working", "Agents working"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Threads.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Threads")
     |> assign(:user, Users.local())
     |> assign(:names, Map.new(Agents.list(), &{&1.id, &1.name}))
     |> assign(:tabs, @tabs)
     |> assign(:tab, "following")
     |> assign(:empty?, true)
     |> assign(:working, if(connected?(socket), do: Runtime.working_threads(), else: []))
     |> stream_configure(:threads, dom_id: &"thread-row-#{&1.id}")
     |> stream(:threads, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "following"
    {:noreply, socket |> assign(:tab, tab) |> load_rows()}
  end

  @impl true
  def handle_info({:thread_reply, _channel_id, _root_id}, socket),
    do: {:noreply, socket |> load_rows() |> Nav.refresh_unread()}

  # The turn message says it all: no channel needs asking.
  def handle_info({:thread_turn, channel_id, agent_id, thread_id}, socket) do
    working =
      Enum.reject(
        socket.assigns.working,
        &(&1.channel_id == channel_id and &1.agent_id == agent_id)
      )

    working =
      if thread_id,
        do: working ++ [%{channel_id: channel_id, agent_id: agent_id, thread_id: thread_id}],
        else: working

    # an agent created since the page opened
    socket =
      if Map.has_key?(socket.assigns.names, agent_id),
        do: socket,
        else: assign(socket, :names, Map.new(Agents.list(), &{&1.id, &1.name}))

    {:noreply, socket |> assign(:working, working) |> load_rows()}
  end

  # read or followed in another view (Nav has refreshed the badge)
  def handle_info({:thread_reads, _root_id}, socket), do: {:noreply, load_rows(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_rows(socket) do
    rows =
      Threads.inbox(socket.assigns.user, String.to_existing_atom(socket.assigns.tab),
        working: Enum.map(socket.assigns.working, & &1.thread_id)
      )

    socket
    |> assign(:empty?, rows == [])
    |> stream(:threads, rows, reset: true)
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
    >
      <Layouts.page
        title="Threads"
        subtitle="Side conversations across every channel"
        max_width="max-w-4xl"
      >
        <nav id="threads-tabs" class="flex flex-wrap items-center gap-1" aria-label="Threads">
          <.link
            :for={{value, label} <- @tabs}
            patch={~p"/threads?#{[tab: value]}"}
            id={"threads-tab-#{value}"}
            class={[
              "btn btn-sm",
              @tab == value && "btn-primary btn-soft",
              @tab != value && "btn-ghost"
            ]}
            aria-current={@tab == value && "page"}
          >
            {label}
            <span
              :if={value == "following" and @threads_unread > 0}
              id="threads-tab-following-count"
              class="badge badge-xs badge-primary"
            >
              {@threads_unread}
            </span>
            <span
              :if={value == "working" and @working != []}
              class="badge badge-xs badge-success badge-soft"
            >
              {@working |> Enum.uniq_by(& &1.thread_id) |> length()}
            </span>
          </.link>
        </nav>

        <Layouts.empty_state
          :if={@empty?}
          id="threads-empty"
          icon="hero-chat-bubble-left-right"
          title={empty_title(@tab)}
        >
          {empty_hint(@tab)}
        </Layouts.empty_state>

        <ul id="threads" phx-update="stream" class="flex flex-col gap-3">
          <li
            :for={{id, row} <- @streams.threads}
            id={id}
            class={[
              "rounded-xl border bg-base-200 shadow-xs transition hover:border-primary/40",
              row.unread > 0 && "border-primary/40",
              row.unread == 0 && "border-base-300"
            ]}
          >
            <.thread_row
              row={row}
              user_name={@user.display_name}
              working={@working}
              names={@names}
            />
          </li>
        </ul>
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :user_name, :string, required: true
  attr :working, :list, required: true
  attr :names, :map, required: true

  defp thread_row(assigns) do
    assigns =
      assigns
      |> assign(:href, ChannelLive.thread_path(assigns.row.channel.id, assigns.row.id))
      |> assign(:working_names, working_names(assigns.working, assigns.row.id, assigns.names))
      |> assign(:participants, participants(assigns.row.summary))

    ~H"""
    <div class="flex flex-col gap-2 px-4 py-3">
      <div class="flex min-w-0 items-baseline gap-2 text-sm">
        <span class="shrink-0 font-semibold text-base-content/70">{channel_label(@row.channel)}</span>
        <span class="text-base-content/30">·</span>
        <span class="shrink-0 font-semibold">{sender(@row.root, @user_name)}:</span>
        <span class="min-w-0 truncate text-base-content/80">“{excerpt(@row.root.body)}”</span>
        <span
          :if={@row.unread > 0}
          id={"thread-row-#{@row.id}-unread"}
          class="ml-auto flex shrink-0 items-center gap-1 text-xs font-semibold text-primary"
        >
          <span class="size-1.5 rounded-full bg-primary" /> {@row.unread} new
        </span>
      </div>

      <ul :if={@row.recent != []} class="flex flex-col gap-1 border-l-2 border-base-300 pl-3">
        <li :for={reply <- @row.recent} class="flex min-w-0 items-center gap-2 text-sm">
          <.mini_avatar participant={%{agent: reply.agent}} user_name={@user_name} />
          <span class="shrink-0 font-medium">{sender(reply, @user_name)}:</span>
          <span class="min-w-0 truncate text-base-content/70">{excerpt(reply.body)}</span>
          <time
            class="ml-auto shrink-0 text-[11px] text-base-content/50"
            title={DateTime.to_iso8601(reply.inserted_at)}
          >
            {short_time(reply.inserted_at)}
          </time>
        </li>
      </ul>

      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span :if={@participants != []} class="flex -space-x-1">
          <.mini_avatar :for={p <- @participants} participant={p} user_name={@user_name} />
        </span>
        <span class="font-semibold text-primary">
          {ngettext("1 reply", "%{count} replies", reply_count(@row.summary))}
        </span>
        <span :if={@row.summary} class="text-base-content/55">
          last {Format.relative_time(@row.summary.last_reply_at)}
        </span>
        <span
          :if={@working_names != []}
          id={"thread-row-#{@row.id}-working"}
          class="flex items-center gap-1.5 text-success"
        >
          <Layouts.status_dot status={:busy} />
          {Enum.map_join(@working_names, ", ", &("@" <> &1))} {if length(@working_names) == 1,
            do: "is",
            else: "are"} replying…
        </span>
        <span
          :if={@row.following?}
          class="flex items-center gap-1 text-base-content/50"
          title="You follow this thread"
        >
          <.icon name="hero-bell-alert-micro" class="size-3.5" /> following
        </span>
        <.link
          navigate={@href}
          id={"thread-row-#{@row.id}-open"}
          class="btn btn-xs btn-ghost ml-auto gap-0.5"
        >
          Open thread <.icon name="hero-chevron-right-mini" class="size-3.5" />
        </.link>
      </div>
    </div>
    """
  end

  defp working_names(working, root_id, names) do
    for %{thread_id: ^root_id, agent_id: agent_id} <- working,
        do: Map.get(names, agent_id, "agent")
  end

  defp participants(nil), do: []
  defp participants(%{participants: list}), do: Enum.take(list, 4)

  defp reply_count(nil), do: 0
  defp reply_count(%{count: count}), do: count

  defp channel_label(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp channel_label(channel), do: "#" <> channel.name

  defp sender(%{agent: %{name: name}}, _user_name) when is_binary(name), do: "@" <> name
  defp sender(%{user: %{display_name: name}}, _user_name) when is_binary(name), do: name
  defp sender(_message, user_name), do: user_name

  defp excerpt(body) do
    case CanopyWeb.Markdown.plain(body) do
      "" -> "(files)"
      text -> Format.truncate(text, 140)
    end
  end

  defp empty_title("following"), do: "No threads followed"
  defp empty_title("active"), do: "No active threads"
  defp empty_title("working"), do: "No agent is working in a thread"

  defp empty_hint("following"),
    do:
      "You follow a thread when you reply in it, start it, or are mentioned in it; the bell in a thread follows it by hand."

  defp empty_hint("active"), do: "Threads with a reply in the last week show here."

  defp empty_hint("working"),
    do: "When an agent answers inside a thread, its thread shows here while it works."
end
