defmodule CanopyWeb.PageController do
  use CanopyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
