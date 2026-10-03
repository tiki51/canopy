defmodule CanopyWeb.Nav do
  @moduledoc """
  `on_mount` hook for every LiveView: loads what the sidebar needs and tracks the
  current path so the layout can highlight the active item.

  Assigns: `:repositories` (each with `:channels`), `:dms`, `:agents`, `:unread`,
  `:threads_unread` (followed threads with unread replies, for the rail's Threads badge) and
  `:thread_unread_summary` (`Canopy.Unread.thread_summary/1`), `:attention`
  (question and permission cards and playbook sign-offs waiting on the user, and runs
  in progress, per channel), `:current_path`,
  `:current_channel_id` and `:current_repository_id` (nil outside a channel). Screens that create or
  change repositories, channels, or agents should call `refresh_nav/1` after
  writing so the sidebar updates without a reload.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Canopy.{
    Agents,
    Attention,
    Channels,
    Hold,
    Repositories,
    Schedules,
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
    end

    socket =
      socket
      |> refresh_nav()
      |> attach_hook(:canopy_nav_refresh, :handle_info, &handle_info/2)
      |> attach_hook(:canopy_nav_events, :handle_event, &handle_event/3)
      |> assign_new(:current_channel_id, fn -> nil end)
      |> assign_new(:current_repository_id, fn -> nil end)
      |> attach_hook(:canopy_nav_path, :handle_params, &handle_params/3)

    {:cont, socket}
  end

  @doc "Reloads repositories, channels, and agents for the sidebar."
  def refresh_nav(socket) do
    socket
    |> assign(:repositories, Repositories.list_with_channels())
    |> assign(:dms, Channels.list_dms())
    |> assign(:agents, Agents.list_active())
    |> assign(:schedule_counts, Schedules.active_counts_by_agent())
    |> assign(:hold, Hold.reason())
    |> refresh_unread()
    |> refresh_attention()
  end

  # The hold banner's Release button lives in the shell, so every page handles it.
  defp handle_event("release_hold", _params, socket) do
    :ok = Hold.release()

    {:halt,
     socket
     |> assign(:hold, nil)
     |> Phoenix.LiveView.put_flash(:info, "Hold released. Reply in a channel to wake its agents.")}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

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
  defp handle_info({:timeline_any, %{event_type: "message"}}, socket),
    do: {:halt, refresh_unread(socket)}

  # A thread read, followed, or unfollowed elsewhere (another tab): the badge
  # follows, and the page may want it too (dots, the inbox).
  defp handle_info({:thread_reads, _root_id}, socket), do: {:cont, refresh_unread(socket)}

  # A question or permission card raised, answered, or detached anywhere: the
  # "needs you" badges follow, so a card in a channel nobody is looking at is seen.
  defp handle_info({:timeline_any, %{event_type: "question_" <> _}}, socket),
    do: {:halt, refresh_attention(socket)}

  defp handle_info({:timeline_any, %{event_type: "permission_" <> _}}, socket),
    do: {:halt, refresh_attention(socket)}

  # Schedule changes update the sidebar counts; the page may also want the event.
  defp handle_info({:hold, _what}, socket), do: {:halt, assign(socket, :hold, Hold.reason())}

  # A run started, finished, or held for a sign-off: the glyph and the badge
  # follow; the channel view may want it too.
  defp handle_info({:playbook_runs, :changed, _channel_id}, socket),
    do: {:cont, refresh_attention(socket)}

  defp handle_info({:schedules, :changed, _channel_id}, socket),
    do: {:cont, assign(socket, :schedule_counts, Schedules.active_counts_by_agent())}

  defp handle_info(_message, socket), do: {:cont, socket}

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
