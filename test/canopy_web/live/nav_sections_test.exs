defmodule CanopyWeb.NavSectionsTest do
  @moduledoc "The sidebar's section and archive events, answered by `CanopyWeb.Nav` on every page."
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Channels, Fixtures, Repo, Unread, Users}
  alias Canopy.Channels.{Channel, Sections}

  setup :set_mox_global

  setup do
    ctx = Fixtures.scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    ctx
  end

  # A page with no channel of its own: the events must work there too.
  defp page(conn), do: live(conn, ~p"/agents")

  defp hook(view, event, params) do
    render_hook(view, event, params)
    view
  end

  test "create_section replies with the id; a duplicate replies inline, no flash",
       %{conn: conn} = ctx do
    {:ok, view, _} = page(conn)

    hook(view, "create_section", %{"repository_id" => ctx.repository.id, "name" => "Releases"})
    [section] = Sections.list(ctx.repository.id)
    assert_reply(view, %{ok: true, id: id})
    assert id == section.id

    html =
      render_hook(view, "create_section", %{
        "repository_id" => ctx.repository.id,
        "name" => "releases"
      })

    assert_reply(view, %{ok: false, error: "Name is already a section in this project"})
    refute html =~ "Name is already a section"
  end

  test "rename, move, toggle (booleans and strings) and delete", %{conn: conn} = ctx do
    {:ok, a} = Sections.create(ctx.repository.id, "A")
    {:ok, b} = Sections.create(ctx.repository.id, "B")
    {:ok, view, _} = page(conn)

    hook(view, "rename_section", %{"id" => a.id, "name" => "Alpha"})
    assert_reply(view, %{ok: true})
    assert Sections.get(a.id).name == "Alpha"

    hook(view, "rename_section", %{"id" => a.id, "name" => "b"})
    assert_reply(view, %{ok: false, error: "Name is already a section in this project"})

    hook(view, "move_section", %{"id" => b.id, "index" => "1"})
    assert_reply(view, %{ok: true})
    assert ctx.repository.id |> Sections.list() |> Enum.map(& &1.id) == [a.id, b.id]

    hook(view, "move_section", %{"id" => b.id, "index" => 0})
    assert_reply(view, %{ok: true})
    assert ctx.repository.id |> Sections.list() |> Enum.map(& &1.id) == [b.id, a.id]

    for {value, expected} <- [{true, true}, {false, false}, {"true", true}, {"false", false}] do
      hook(view, "toggle_section", %{"id" => a.id, "collapsed" => value})
      assert_reply(view, %{ok: true})
      assert Sections.get(a.id).collapsed == expected
    end

    hook(view, "toggle_section", %{"id" => a.id, "collapsed" => "maybe"})
    assert_reply(view, %{ok: false})

    hook(view, "delete_section", %{"id" => a.id})
    assert_reply(view, %{ok: true})
    assert Sections.get(a.id) == nil

    html = render_hook(view, "delete_section", %{"id" => a.id})
    assert_reply(view, %{ok: false, error: "That section no longer exists."})
    assert html =~ "That section no longer exists."
  end

  test "move_channel files a channel and takes it back with nil or \"\"", %{conn: conn} = ctx do
    {:ok, section} = Sections.create(ctx.repository.id, "S")
    {:ok, view, _} = page(conn)

    hook(view, "move_channel", %{"id" => ctx.channel.id, "section_id" => section.id})
    assert_reply(view, %{ok: true})
    assert Repo.get!(Channel, ctx.channel.id).section_id == section.id

    for top <- [nil, ""] do
      {:ok, _} = Sections.move_channel(Channels.get!(ctx.channel.id), section)
      hook(view, "move_channel", %{"id" => ctx.channel.id, "section_id" => top})
      assert_reply(view, %{ok: true})
      assert Repo.get!(Channel, ctx.channel.id).section_id == nil
    end

    hook(view, "move_channel", %{"id" => "ch_gone", "section_id" => section.id})
    assert_reply(view, %{ok: false, error: "That channel no longer exists."})
  end

  test "archive pushes the Undo toast; unarchive brings it back", %{conn: conn} = ctx do
    {:ok, view, _} = page(conn)

    hook(view, "archive_channel", %{"id" => ctx.channel.id})
    assert_reply(view, %{ok: true})
    assert_push_event(view, "canopy:channel_archived", %{id: id, name: name})
    assert {id, name} == {ctx.channel.id, ctx.channel.name}
    assert Channels.get!(ctx.channel.id).status == "archived"

    hook(view, "unarchive_channel", %{"id" => ctx.channel.id})
    assert_reply(view, %{ok: true})
    channel = Channels.get!(ctx.channel.id)
    assert channel.status == "open"
    assert channel.archive_offer_dismissed_at == nil
  end

  test "archiving another channel from a channel page pushes the toast and keeps the page",
       %{conn: conn} = ctx do
    other =
      Fixtures.channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: ctx.agent.id})

    {:ok, view, _} = live(conn, ~p"/channels/#{ctx.channel.id}")

    hook(view, "archive_channel", %{"id" => other.id})
    assert_reply(view, %{ok: true})
    assert_push_event(view, "canopy:channel_archived", %{id: id})
    assert id == other.id
    assert Channels.get!(other.id).status == "archived"
    assert Channels.get!(ctx.channel.id).status == "open"

    # still this channel's page, not archived; the other channel moved to the archived list
    assert has_element?(view, "#channel-name", ctx.channel.name)
    refute has_element?(view, "#archived-badge")

    assert has_element?(
             view,
             "#sidebar-archived-#{ctx.repository.id} #sidebar-channel-#{other.id}"
           )
  end

  test "archive_channel without an id is refused as incomplete", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/channels/#{ctx.channel.id}")

    html = render_hook(view, "archive_channel", %{})
    assert_reply(view, %{ok: false, error: "That request was incomplete."})
    assert html =~ "That request was incomplete."
    assert Channels.get!(ctx.channel.id).status == "open"
  end

  test "dismiss_archive_offer and mark_channel_read", %{conn: conn} = ctx do
    {:ok, view, _} = page(conn)

    hook(view, "dismiss_archive_offer", %{"id" => ctx.channel.id})
    assert_reply(view, %{ok: true})
    assert %DateTime{} = Channels.get!(ctx.channel.id).archive_offer_dismissed_at

    {:ok, _} = Canopy.Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "news")
    assert Map.has_key?(Unread.summary(Users.local()), ctx.channel.id)

    hook(view, "mark_channel_read", %{"id" => ctx.channel.id})
    assert_reply(view, %{ok: true})
    refute Map.has_key?(Unread.summary(Users.local()), ctx.channel.id)
  end

  test "a second view's sidebar follows the broadcast", %{conn: conn} = ctx do
    {:ok, view, _} = page(conn)
    {:ok, other, _} = live(conn, ~p"/teams")

    hook(view, "create_section", %{"repository_id" => ctx.repository.id, "name" => "Shared"})
    assert_reply(view, %{ok: true})

    # Nav's refresh_nav put the new section on @repositories in the other view
    repository =
      other.pid
      |> :sys.get_state()
      |> get_in([Access.key(:socket), Access.key(:assigns), :repositories])
      |> Enum.find(&(&1.id == ctx.repository.id))

    assert Enum.map(repository.sections, & &1.name) == ["Shared"]
  end

  test "every event is refused during an environment reset", %{conn: conn} = ctx do
    {:ok, section} = Sections.create(ctx.repository.id, "S")
    {:ok, view, _} = page(conn)
    Canopy.EnvironmentHelpers.raise_gate()

    for {event, params} <- [
          {"create_section", %{"repository_id" => ctx.repository.id, "name" => "New"}},
          {"rename_section", %{"id" => section.id, "name" => "T"}},
          {"move_section", %{"id" => section.id, "index" => 0}},
          {"delete_section", %{"id" => section.id}},
          {"toggle_section", %{"id" => section.id, "collapsed" => true}},
          {"move_channel", %{"id" => ctx.channel.id, "section_id" => section.id}},
          {"archive_channel", %{"id" => ctx.channel.id}},
          {"unarchive_channel", %{"id" => ctx.channel.id}},
          {"dismiss_archive_offer", %{"id" => ctx.channel.id}},
          {"mark_channel_read", %{"id" => ctx.channel.id}}
        ] do
      html = render_hook(view, event, params)
      assert_reply(view, %{ok: false})
      assert html =~ "Canopy is resetting", event
    end

    assert [%{name: "S", collapsed: false}] = Sections.list(ctx.repository.id)
    channel = Channels.get!(ctx.channel.id)
    assert {channel.status, channel.section_id} == {"open", nil}
  end
end
