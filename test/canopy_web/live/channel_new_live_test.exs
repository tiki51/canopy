defmodule CanopyWeb.ChannelNewLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.Channels
  alias Canopy.Fixtures

  setup do
    repository = Fixtures.repository_fixture()
    builder = Fixtures.agent_fixture(%{name: "builder"})
    reviewer = Fixtures.agent_fixture(%{name: "reviewer"})
    %{repository: repository, builder: builder, reviewer: reviewer}
  end

  test "preselects all active agents as members and the first as owner", ctx do
    inactive = Fixtures.agent_fixture(%{name: "retired"})
    {:ok, _} = Canopy.Agents.deactivate(inactive)

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    assert has_element?(view, "#channel-form")
    assert has_element?(view, "#member-#{ctx.builder.id}[checked]")
    assert has_element?(view, "#member-#{ctx.reviewer.id}[checked]")
    refute has_element?(view, "#member-#{inactive.id}")

    assert has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[selected][value='#{ctx.builder.id}']"
           )

    assert has_element?(
             view,
             "#channel-form select[name='channel[repository_id]'] option[value='#{ctx.repository.id}']"
           )
  end

  test "preselects the repository given in the query string", ctx do
    other = Fixtures.repository_fixture(%{name: "zzz-other"})
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new?repository_id=#{other.id}")

    assert has_element?(
             view,
             "#channel-form select[name='channel[repository_id]'] option[selected][value='#{other.id}']"
           )
  end

  test "creates the channel with members and owner, then redirects into it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{
        repository_id: ctx.repository.id,
        name: "Retry-Logic",
        topic: "Make the client retry",
        owner_agent_id: ctx.reviewer.id,
        agent_ids: [ctx.builder.id, ctx.reviewer.id]
      }
    )
    |> render_submit()

    assert %{} = channel = Channels.get_by_name(ctx.repository.id, "retry-logic")
    assert_redirect(view, ~p"/channels/#{channel.id}")

    assert channel.topic == "Make the client retry"
    assert channel.owner_agent_id == ctx.reviewer.id
    assert channel.task.owner_agent_id == ctx.reviewer.id
    assert channel.task.title == "Make the client retry"

    assert Enum.map(channel.agents, & &1.id) |> Enum.sort() ==
             Enum.sort([ctx.builder.id, ctx.reviewer.id])
  end

  test "creates a channel with only the owner as member", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{
        repository_id: ctx.repository.id,
        name: "solo",
        owner_agent_id: ctx.builder.id,
        agent_ids: [ctx.builder.id]
      }
    )
    |> render_submit()

    assert %{} = channel = Channels.get_by_name(ctx.repository.id, "solo")
    assert_redirect(view, ~p"/channels/#{channel.id}")
    assert Enum.map(channel.agents, & &1.id) == [ctx.builder.id]
    assert channel.task.title == "solo"
  end

  test "unchecking the owner moves ownership to another member", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form",
      channel: %{owner_agent_id: ctx.builder.id, agent_ids: [ctx.reviewer.id]}
    )
    |> render_change()

    refute has_element?(view, "#member-#{ctx.builder.id}[checked]")

    refute has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[value='#{ctx.builder.id}']"
           )

    assert has_element?(
             view,
             "#channel-form select[name='channel[owner_agent_id]'] option[selected][value='#{ctx.reviewer.id}']"
           )
  end

  test "shows validation errors inline and does not create anything", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form", channel: %{name: "", topic: "x"})
    |> render_submit()

    assert has_element?(view, "#channel-form", "can't be blank")
    assert Channels.list() == []

    view
    |> form("#channel-form", channel: %{name: "Has Spaces"})
    |> render_submit()

    assert has_element?(view, "#channel-form", "must be lowercase letters")
    assert Channels.list() == []
  end

  test "rejects a duplicate name within the repository", ctx do
    Fixtures.channel_fixture(%{
      repository_id: ctx.repository.id,
      name: "taken",
      owner_agent_id: ctx.builder.id
    })

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    view
    |> form("#channel-form", channel: %{repository_id: ctx.repository.id, name: "taken"})
    |> render_submit()

    assert has_element?(view, "#channel-form", "has already been taken")
    assert length(Channels.list()) == 1
  end

  test "requires at least one member", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    render_submit(view, "save", %{
      "channel" => %{"repository_id" => ctx.repository.id, "name" => "lonely", "agent_ids" => []}
    })

    assert has_element?(view, "#channel-form", "pick at least one agent")
    assert Channels.list() == []
  end

  test "points to the repositories screen when there are none", %{conn: conn} do
    Enum.each(Canopy.Repositories.list(), &Canopy.Repositories.delete/1)

    {:ok, view, _html} = live(conn, ~p"/channels/new")

    assert has_element?(view, "#new-channel-no-repositories")
    refute has_element?(view, "#channel-form")
  end

  test "points to the agents screen when there are no active agents", ctx do
    {:ok, _} = Canopy.Agents.deactivate(ctx.builder)
    {:ok, _} = Canopy.Agents.deactivate(ctx.reviewer)

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/new")

    assert has_element?(view, "#new-channel-no-agents")
    refute has_element?(view, "#channel-form")
  end
end
