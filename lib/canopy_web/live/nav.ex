defmodule CanopyWeb.Nav do
  @moduledoc """
  `on_mount` hook for every LiveView: loads what the sidebar needs and tracks the
  current path so the layout can highlight the active item.

  Assigns: `:repositories` (each with `:channels`), `:agents`, `:current_path`,
  and `:current_channel_id` (nil outside a channel). Screens that create or
  change repositories, channels, or agents should call `refresh_nav/1` after
  writing so the sidebar updates without a reload.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Canopy.{Agents, Repositories}

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> refresh_nav()
      |> assign_new(:current_channel_id, fn -> nil end)
      |> attach_hook(:canopy_nav_path, :handle_params, &handle_params/3)

    {:cont, socket}
  end

  @doc "Reloads repositories, channels, and agents for the sidebar."
  def refresh_nav(socket) do
    socket
    |> assign(:repositories, Repositories.list_with_channels())
    |> assign(:agents, Agents.list_active())
  end

  defp handle_params(params, uri, socket) do
    path = URI.parse(uri).path || "/"

    socket =
      socket
      |> assign(:current_path, path)
      |> assign(:current_channel_id, channel_id_from(path, params))

    {:cont, socket}
  end

  defp channel_id_from("/channels/" <> _, %{"id" => id}), do: id
  defp channel_id_from(_, _), do: nil
end
