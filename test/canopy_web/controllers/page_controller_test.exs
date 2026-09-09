defmodule CanopyWeb.PageControllerTest do
  use CanopyWeb.ConnCase, async: false

  test "GET / redirects to repositories when there are no channels", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/repositories"
  end

  test "GET / redirects to the first channel when one exists", %{conn: conn} do
    %{channel: channel} = Canopy.Fixtures.scenario()
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/channels/#{channel.id}"
  end
end
