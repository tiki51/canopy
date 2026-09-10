defmodule CanopyWeb.Nav do
  @moduledoc """
  `on_mount` hook for every LiveView: loads what the sidebar needs and tracks the
  current path so the layout can highlight the active item.

  Assigns: `:repositories` (each with `:channels`), `:dms`, `:agents`, `:current_path`,
  `:current_channel_id`, `:current_repository_id` and `:current_dm_agent_id`
  (nil outside a channel, the last one nil outside a DM). Screens that create or
  change repositories, channels, or agents should call `refresh_nav/1` after
  writing so the sidebar updates without a reload.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Canopy.{Agents, Channels, Repositories}

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Channels.subscribe()

    socket =
      socket
      |> refresh_nav()
      |> attach_hook(:canopy_nav_refresh, :handle_info, &handle_info/2)
      |> assign_new(:current_channel_id, fn -> nil end)
      |> assign_new(:current_repository_id, fn -> nil end)
      |> assign_new(:current_dm_agent_id, fn -> nil end)
      |> attach_hook(:canopy_nav_path, :handle_params, &handle_params/3)

    {:cont, socket}
  end

  @doc "Reloads repositories, channels, and agents for the sidebar."
  def refresh_nav(socket) do
    socket
    |> assign(:repositories, Repositories.list_with_channels())
    |> assign(:dms, Channels.list_dms())
    |> assign(:agents, Agents.list_active())
  end

  # Channels created, archived, or reopened anywhere (including DMs agents
  # open) show up in every sidebar without a reload.
  defp handle_info({:channels, :changed}, socket), do: {:halt, refresh_nav(socket)}
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
      |> assign(:current_dm_agent_id, dm_agent_id(channel))

    {:cont, socket}
  end

  # The agent row in the sidebar lights up only for a one-to-one DM.
  defp dm_agent_id(%{kind: "dm", agents: [%{id: id}]}), do: id
  defp dm_agent_id(_), do: nil

  defp channel_id_from("/channels/" <> _, %{"id" => id}), do: id
  defp channel_id_from(_, _), do: nil
end
