defmodule CanopyWeb.HealthController do
  use CanopyWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", version: Application.spec(:canopy, :vsn) |> to_string()})
  end
end
