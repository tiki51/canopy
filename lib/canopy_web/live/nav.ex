defmodule CanopyWeb.Nav do
  @moduledoc """
  `on_mount` hook for every LiveView: loads what the sidebar needs and tracks the
  current path so the layout can highlight the active item.

  Assigns: `:repositories` (each with `:channels`), `:dms`, `:agents`, `:unread`,
  `:threads_unread` (followed threads with unread replies, for the rail's Threads badge) and
  `:thread_unread_summary` (`Canopy.Unread.thread_summary/1`), `:attention`
  (question and permission cards and playbook sign-offs waiting on the user, and runs
  in progress, per channel), `:palette` (teams and enabled playbooks, for the command
  palette), `:current_path`,
  `:current_channel_id` and `:current_repository_id` (nil outside a channel). Screens that create or
  change repositories, channels, or agents should call `refresh_nav/1` after
  writing so the sidebar updates without a reload.

  Every page also pushes desktop notification notes to the browser as
  `"canopy:notify"` (`CanopyWeb.Notify`): for cards, mentions, sign-offs and
  completed tasks from `"timeline:all"`, and for channels that went quiet
  (`Canopy.Runtime.subscribe_activity/0`). On connecting it pushes the cards
  still waiting from the last half hour as `"canopy:pending"`, so a page that
  was asleep or offline can catch up.

  It also answers the command palette's server questions on every page:
  `cmdk:files` (a filename search), `cmdk:stop` (`/stop` in a channel you are
  not in) and `cmdk:notify` (the desktop notifications switch was flipped: a
  flash says so); see `CanopyWeb.CommandPalette`.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias CanopyWeb.Notify

  alias Canopy.{
    Agents,
    Attention,
    Channels,
    Documents,
    Hold,
    Playbooks,
    Repositories,
    Runtime,
    Schedules,
    Teams,
    Threads,
    Timeline,
    Unread,
    Users
  }

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Channels.subscribe()
      Timeline.subscribe_all()
      Threads.subscribe_reads()
      Schedules.subscribe()
      Hold.subscribe()
      Canopy.Playbooks.Runs.subscribe()
      Teams.subscribe()
      Playbooks.subscribe()
      Runtime.subscribe_activity()
    end

    socket =
      socket
      |> refresh_nav()
      |> attach_hook(:canopy_nav_refresh, :handle_info, &handle_info/2)
      |> attach_hook(:canopy_nav_events, :handle_event, &handle_event/3)
      |> assign_new(:current_channel_id, fn -> nil end)
      |> assign_new(:current_repository_id, fn -> nil end)
      |> attach_hook(:canopy_nav_path, :handle_params, &handle_params/3)
      |> push_pending()

    {:cont, socket}
  end

  # A page that (re)connects hears of the cards still waiting from the last
  # half hour, in case it missed their notes (asleep, offline). The browser
  # shows only those it never showed or saw (assets/js/notify.js).
  @catch_up_minutes 30

  defp push_pending(socket) do
    if connected?(socket) do
      since = DateTime.add(DateTime.utc_now(), -@catch_up_minutes, :minute)

      case since
           |> Attention.pending_card_events()
           |> Enum.map(&note(socket, &1))
           |> Enum.reject(&is_nil/1) do
        [] -> socket
        notes -> push_event(socket, "canopy:pending", %{notes: notes})
      end
    else
      socket
    end
  end

  @doc "Reloads repositories, channels, and agents for the sidebar."
  def refresh_nav(socket) do
    socket
    |> assign(:repositories, Repositories.list_with_channels())
    |> assign(:dms, Channels.list_dms())
    |> assign(:agents, Agents.list_active())
    |> assign(:schedule_counts, Schedules.active_counts_by_agent())
    |> assign(:hold, Hold.reason())
    |> refresh_palette()
    |> refresh_unread()
    |> refresh_attention()
  end

  # What the command palette lists beyond the sidebar: teams (as `@` rows) and
  # the enabled playbooks (as "Start playbook" commands). Names and ids only.
  defp refresh_palette(socket) do
    assign(socket, :palette, %{
      teams: Enum.map(Teams.list(), &%{id: &1.id, name: &1.name}),
      playbooks: Enum.map(Playbooks.list(enabled: true), &%{id: &1.id, name: &1.name})
    })
  end

  # The hold banner's Release button lives in the shell, so every page handles it.
  defp handle_event("release_hold", _params, socket) do
    :ok = Hold.release()

    {:halt,
     socket
     |> assign(:hold, nil)
     |> Phoenix.LiveView.put_flash(:info, "Hold released. Reply in a channel to wake its agents.")}
  end

  # The command palette's file search: filenames only, newest first. Fewer
  # than two characters asks for nothing. `seq` comes back so the palette can
  # drop a reply that a later keystroke overtook.
  defp handle_event("cmdk:files", params, socket) do
    q = String.trim(to_string(params["q"]))

    files =
      if String.length(q) < 2 do
        []
      else
        [search: q, limit: 6]
        |> Documents.list()
        |> Enum.map(fn document ->
          %{
            id: document.id,
            filename: document.filename,
            kind: document.kind,
            size_label: Documents.size_label(document.byte_size),
            url: Documents.url_path(document)
          }
        end)
      end

    {:halt, %{files: files, seq: params["seq"]}, socket}
  end

  # `/stop` chosen in the palette for a channel you are not in: the channel
  # step was the confirmation, so it stops at once and says so here.
  defp handle_event("cmdk:stop", %{"channel_id" => id}, socket) when is_binary(id) do
    case Channels.get(id) do
      %{} = channel ->
        if Channels.archived?(channel) do
          {:halt, %{ok: false}, put_flash(socket, :error, "That channel is archived.")}
        else
          {:ok, %{aborted: aborted}} = Runtime.stop_all(channel.id)

          {:halt, %{ok: true},
           put_flash(
             socket,
             :info,
             "Stopped #{stop_label(channel)}: #{aborted} #{if aborted == 1, do: "turn", else: "turns"} aborted. Reply there or press Continue to resume."
           )}
        end

      nil ->
        {:halt, %{ok: false}, put_flash(socket, :error, "That channel no longer exists.")}
    end
  end

  defp handle_event("cmdk:stop", _params, socket),
    do: {:halt, %{ok: false}, put_flash(socket, :error, "That channel no longer exists.")}

  # The palette flipped this browser's desktop notifications switch; the
  # switch itself lives in the browser (assets/js/notify.js).
  defp handle_event("cmdk:notify", %{"on" => on}, socket) do
    message =
      if on == true,
        do: "Desktop notifications are on in this browser.",
        else: "Desktop notifications are off in this browser."

    {:halt, %{}, put_flash(socket, :info, message)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp stop_label(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp stop_label(channel), do: "#" <> channel.name

  @doc """
  Reloads the per-channel unread and mention counts for the sidebar, and the
  number of followed threads with unread replies for the rail.
  """
  def refresh_unread(socket) do
    user = Users.local()
    threads = Unread.thread_summary(user)

    socket
    |> assign(:unread, Unread.summary(user))
    |> assign(:threads_unread, map_size(threads))
    # the whole map, so a view that shows per-thread dots needs no query of its own
    |> assign(:thread_unread_summary, threads)
  end

  @doc "Reloads the per-channel cards waiting on the user, for the sidebar."
  def refresh_attention(socket), do: assign(socket, :attention, Attention.summary())

  # Channels created, archived, or reopened anywhere (including DMs agents
  # open) show up in every sidebar without a reload.
  defp handle_info({:channels, :changed}, socket), do: {:halt, refresh_nav(socket)}

  # A message anywhere may change the unread marks. The channel view sees its
  # own copy of the event first and marks the channel read, so this refresh
  # already reflects that.
  defp handle_info({:timeline_any, %{event_type: "message"} = event}, socket),
    do: {:halt, socket |> refresh_unread() |> notify(event)}

  # A thread read, followed, or unfollowed elsewhere (another tab): the badge
  # follows, and the page may want it too (dots, the inbox).
  defp handle_info({:thread_reads, _root_id}, socket), do: {:cont, refresh_unread(socket)}

  # A question or permission card raised, answered, or detached anywhere: the
  # "needs you" badges follow, so a card in a channel nobody is looking at is seen.
  defp handle_info({:timeline_any, %{event_type: "question_" <> _} = event}, socket),
    do: {:halt, socket |> refresh_attention() |> notify(event)}

  defp handle_info({:timeline_any, %{event_type: "permission_" <> _} = event}, socket),
    do: {:halt, socket |> refresh_attention() |> notify(event)}

  # A sign-off requested or a task completed: a desktop notification may say
  # so. The page may want the event too.
  defp handle_info({:timeline_any, %{event_type: type} = event}, socket)
       when type in ~w(playbook_approval_requested task_updated),
       do: {:cont, notify(socket, event)}

  # A channel's run of turns is over: "Work finished", when the browser wants it.
  defp handle_info({:channel_quiet, _channel_id, _info} = signal, socket),
    do: {:halt, notify(socket, signal)}

  # Schedule changes update the sidebar counts; the page may also want the event.
  defp handle_info({:hold, _what}, socket), do: {:halt, assign(socket, :hold, Hold.reason())}

  # A run started, finished, or held for a sign-off: the glyph and the badge
  # follow; the channel view may want it too.
  defp handle_info({:playbook_runs, :changed, _channel_id}, socket),
    do: {:cont, refresh_attention(socket)}

  # A team or a playbook changed: the palette's lists follow. Pages that list
  # them subscribe themselves and want the event too.
  defp handle_info({:teams, :changed}, socket), do: {:cont, refresh_palette(socket)}
  defp handle_info({:playbooks, :changed}, socket), do: {:cont, refresh_palette(socket)}

  defp handle_info({:schedules, :changed, _channel_id}, socket),
    do: {:cont, assign(socket, :schedule_counts, Schedules.active_counts_by_agent())}

  defp handle_info(_message, socket), do: {:cont, socket}

  # The page decides whether to show it (`assets/js/notify.js`); the channel
  # comes from what the sidebar already holds.
  defp notify(socket, signal) do
    case note(socket, signal) do
      nil -> socket
      note -> push_event(socket, "canopy:notify", note)
    end
  end

  defp note(socket, signal) do
    channel_id =
      case signal do
        {:channel_quiet, channel_id, _info} -> channel_id
        %{channel_id: channel_id} -> channel_id
      end

    Notify.classify(signal, %{
      channel: known_channel(socket.assigns, channel_id) || Channels.get(channel_id),
      names: Map.new(socket.assigns.agents, &{&1.id, &1.name})
    })
  end

  defp known_channel(assigns, channel_id) do
    Enum.find(assigns.dms, &(&1.id == channel_id)) ||
      Enum.find_value(assigns.repositories, fn repository ->
        Enum.find(repository.channels, &(&1.id == channel_id))
      end)
  end

  defp handle_params(params, uri, socket) do
    path = URI.parse(uri).path || "/"

    channel_id = channel_id_from(path, params)
    channel = channel_id && Channels.get(channel_id)

    socket =
      socket
      |> assign(:current_path, path)
      |> assign(:current_channel_id, channel_id)
      |> assign(:current_repository_id, channel && channel.repository_id)

    {:cont, socket}
  end

  defp channel_id_from("/channels/" <> _, %{"id" => id}), do: id
  defp channel_id_from(_, _), do: nil
end
