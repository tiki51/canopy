defmodule CanopyWeb.PageController do
  use CanopyWeb, :controller

  alias Canopy.{Channels, Settings}

  @doc """
  Home: first-run setup until it has been finished or skipped, then the first
  open channel, or the repositories screen when there is none.
  """
  def home(conn, _params) do
    if Settings.onboarded?() do
      case Enum.reject(Channels.list(), &Channels.dm?/1) do
        [channel | _] -> redirect(conn, to: ~p"/channels/#{channel.id}")
        [] -> redirect(conn, to: ~p"/repositories")
      end
    else
      redirect(conn, to: ~p"/welcome")
    end
  end
end
