defmodule CanopyWeb.PageController do
  use CanopyWeb, :controller

  alias Canopy.Channels

  @doc "Home: the first open channel, or the repositories screen when there is none."
  def home(conn, _params) do
    case Enum.reject(Channels.list(), &Channels.dm?/1) do
      [channel | _] -> redirect(conn, to: ~p"/channels/#{channel.id}")
      [] -> redirect(conn, to: ~p"/repositories")
    end
  end
end
