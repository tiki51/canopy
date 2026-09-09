defmodule CanopyWeb.PageController do
  use CanopyWeb, :controller

  alias Canopy.Channels

  @doc "Home: the first open channel, or the repositories screen when there is none."
  def home(conn, _params) do
    case Channels.list() do
      [channel | _] -> redirect(conn, to: ~p"/channels/#{channel.id}")
      [] -> redirect(conn, to: ~p"/repositories")
    end
  end
end
