defmodule CanopyWeb.HealthControllerTest do
  use CanopyWeb.ConnCase, async: true

  test "GET /health reports the running version", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "version" => Application.spec(:canopy, :vsn) |> to_string()
           }
  end
end
