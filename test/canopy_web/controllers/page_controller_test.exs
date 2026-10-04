defmodule CanopyWeb.PageControllerTest do
  use CanopyWeb.ConnCase, async: false

  alias Canopy.Repo
  alias Canopy.Settings.Setting

  test "GET / redirects to repositories when there are no channels", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/repositories"
  end

  test "GET / redirects to the first channel when one exists", %{conn: conn} do
    %{channel: channel} = Canopy.Fixtures.scenario()
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/channels/#{channel.id}"
  end

  test "GET / lands a fresh install on the normal home too: setup opens over it",
       %{conn: conn} do
    Repo.update_all(Setting, set: [onboarded_at: nil])
    %{channel: channel} = Canopy.Fixtures.scenario()
    assert redirected_to(get(conn, ~p"/")) == ~p"/channels/#{channel.id}"
  end

  test "GET / passes ?setup= on, as a step, and drops one that isn't", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/?setup=pace")) == ~p"/repositories?setup=pace"
    assert redirected_to(get(build_conn(), ~p"/?setup=team")) == ~p"/repositories?setup=pace"
    assert redirected_to(get(build_conn(), ~p"/?setup=nope")) == ~p"/repositories"
  end

  test "GET /welcome opens setup over home, at an old link's step", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/welcome")) == ~p"/?setup=you"
    assert redirected_to(get(build_conn(), ~p"/welcome?step=team")) == ~p"/?setup=pace"
    assert redirected_to(get(build_conn(), ~p"/welcome?step=done")) == ~p"/?setup=project"
    assert redirected_to(get(build_conn(), ~p"/welcome?step=nope")) == ~p"/?setup=you"
  end
end
