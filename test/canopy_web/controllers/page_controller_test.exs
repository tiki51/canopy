defmodule CanopyWeb.PageControllerTest do
  use CanopyWeb.ConnCase, async: false

  alias Canopy.{Repo, Settings}
  alias Canopy.Settings.Setting

  test "GET / sends a fresh install to first-run setup", %{conn: conn} do
    # a fresh install's row, whatever the test database holds outside the sandbox
    Repo.update_all(Setting, set: [onboarded_at: nil])
    %{channel: _channel} = Canopy.Fixtures.scenario()
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/welcome"
  end

  describe "once setup is done" do
    setup do
      {:ok, _} = Settings.mark_onboarded()
      :ok
    end

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
end
