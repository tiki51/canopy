defmodule CanopyWeb.Nav do
  @moduledoc """
  `on_mount` hook for every LiveView: loads what the sidebar needs and tracks the
  current path so the layout can highlight the active item.

  Assigns: `:repositories` (each with `:channels`), `:dms`, `:agents`, `:unread`, `:current_path`,
  `:current_channel_id` and `:current_repository_id` (nil outside a channel). Screens that create or
  change repositories, channels, or agents should call `refresh_nav/1` after
  writing so the sidebar updates without a reload.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Canopy.{Agents, Channels, Hold, Repositories, Schedules, Timeline, Unread, Users}

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Channels.subscribe()
      Timeline.subscribe_all()
      Schedules.subscribe()
      Hold.subscribe()
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

  @doc "Reloads the per-channel unread and mention counts for the sidebar."
  def refresh_unread(socket), do: assign(socket, :unread, Unread.summary(Users.local()))

  # Channels created, archived, or reopened anywhere (including DMs agents
  # open) show up in every sidebar without a reload.
  defp handle_info({:channels, :changed}, socket), do: {:halt, refresh_nav(socket)}

  # A message anywhere may change the unread marks. The channel view sees its
  # own copy of the event first and marks the channel read, so this refresh
  # already reflects that.
  defp handle_info({:timeline_any, %{event_type: "message"}}, socket),
    do: {:halt, refresh_unread(socket)}

  # Schedule changes update the sidebar counts; the page may also want the event.
  defp handle_info({:hold, _what}, socket), do: {:halt, assign(socket, :hold, Hold.reason())}

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
