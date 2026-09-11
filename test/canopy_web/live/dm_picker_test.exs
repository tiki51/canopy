defmodule CanopyWeb.DmPickerTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.{Channels, Fixtures}

  test "the + opens a modal on any page; picking agents opens (or creates) the DM", %{conn: conn} do
    repository = Fixtures.repository_fixture()
    a = Fixtures.agent_fixture(%{name: "alpha" <> Fixtures.unique_suffix()})
    b = Fixtures.agent_fixture(%{name: "beta" <> Fixtures.unique_suffix()})

    {:ok, view, _html} = live(conn, ~p"/agents")
    refute has_element?(view, "#dm-picker")

    view |> element("#sidebar-new-dm") |> render_click()
    assert has_element?(view, "#dm-picker")
    assert has_element?(view, "#open-dm[disabled]")

    view |> form("#dm-form", %{"agent_ids" => []}) |> render_submit()
    assert has_element?(view, "#dm-error", "Pick at least one agent")

    view |> form("#dm-form", %{"agent_ids" => [a.id, b.id]}) |> render_change()
    assert has_element?(view, "#open-dm", "Open DM with @#{a.name}, @#{b.name}")

    view |> form("#dm-form", %{"agent_ids" => [a.id, b.id]}) |> render_submit()
    [dm] = Channels.list_dms(repository.id)
    assert Enum.map(dm.agents, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    assert_redirect(view, ~p"/channels/#{dm.id}")

    # the same set again, from another page, lands in the same DM
    {:ok, view, _html} = live(conn, ~p"/settings")
    view |> element("#sidebar-new-dm") |> render_click()
    view |> form("#dm-form", %{"agent_ids" => [b.id, a.id]}) |> render_submit()
    assert_redirect(view, ~p"/channels/#{dm.id}")
    assert [_] = Channels.list_dms(repository.id)
  end

  test "closes with the button, and explains when nothing can be picked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents")
    view |> element("#sidebar-new-dm") |> render_click()
    assert has_element?(view, "#dm-picker-no-repository a[href='/repositories']")
    view |> element("#close-dm-picker") |> render_click()
    refute has_element?(view, "#dm-picker")

    Fixtures.repository_fixture()
    {:ok, view, _html} = live(conn, ~p"/agents")
    view |> element("#sidebar-new-dm") |> render_click()
    assert has_element?(view, "#dm-picker-no-agents a[href='/agents/new']")
  end
end
