defmodule CanopyWeb.DmControllerTest do
  use CanopyWeb.ConnCase, async: false

  import Canopy.Fixtures

  alias Canopy.Channels

  test "GET /dm/:agent_id opens the agent's DM in the given repository, creating it once", %{
    conn: conn
  } do
    repository = repository_fixture()
    other = repository_fixture()
    agent = agent_fixture()

    conn = get(conn, ~p"/dm/#{agent.id}?repository=#{other.id}")
    "/channels/" <> id = redirected_to(conn)
    dm = Channels.get!(id)
    assert dm.kind == "dm"
    assert dm.repository_id == other.id
    assert dm.owner_agent_id == agent.id

    conn = get(build_conn(), ~p"/dm/#{agent.id}?repository=#{other.id}")
    assert redirected_to(conn) == ~p"/channels/#{dm.id}"

    # Without a repository the first one on file is used.
    conn = get(build_conn(), ~p"/dm/#{agent.id}")
    "/channels/" <> id = redirected_to(conn)
    assert Channels.get!(id).repository_id == List.first(Canopy.Repositories.list()).id
    assert repository.id in Enum.map(Canopy.Repositories.list(), & &1.id)
  end

  test "GET /dm/:agent_id without any repository sends you to add one", %{conn: conn} do
    agent = agent_fixture()
    conn = get(conn, ~p"/dm/#{agent.id}")
    assert redirected_to(conn) == ~p"/repositories"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Add a repository"
  end

  test "GET /dm/:agent_id for an unknown agent sends you to the agents page", %{conn: conn} do
    conn = get(conn, ~p"/dm/agt_nope")
    assert redirected_to(conn) == ~p"/agents"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer exists"
  end
end
