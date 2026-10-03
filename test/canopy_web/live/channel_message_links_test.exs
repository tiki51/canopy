defmodule CanopyWeb.ChannelMessageLinksTest do
  # `?msg=` links into the channel feed (search results use them), the
  # history window they open for an old message, and its way back.
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Messages, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    Canopy.MCP.mark_registered(scenario.repository.id)

    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    scenario
  end

  defp msg_path(channel, message), do: ~p"/channels/#{channel.id}?#{[msg: message.id]}"

  # system notes wake nobody, so the feed fills without any turn
  defp note(ctx, body) do
    {:ok, message} = Messages.post_user_note(ctx.channel.id, ctx.user.id, body)
    message
  end

  defp dom_id(message), do: "evt-" <> Timeline.for_message(message.id).id

  # `old` and then more than a page of newer events
  defp history(ctx) do
    old = note(ctx, "the old decision")
    for i <- 1..110, do: note(ctx, "filler #{i}")
    old
  end

  test "a message inside the loaded feed is scrolled to and flashed", %{conn: conn} = ctx do
    target = note(ctx, "pick me")
    note(ctx, "a later one")

    {:ok, view, _html} = live(conn, msg_path(ctx.channel, target))

    assert_push_event(view, "timeline:highlight", %{id: id})
    assert id == dom_id(target)
    assert has_element?(view, "##{id}")
    refute has_element?(view, "#jump-to-latest")
  end

  test "an older message opens history around it; new events wait on the pill",
       %{conn: conn} = ctx do
    old = history(ctx)

    {:ok, view, _html} = live(conn, msg_path(ctx.channel, old))

    assert_push_event(view, "timeline:highlight", %{id: id})
    assert id == dom_id(old)
    assert has_element?(view, "##{id}")
    assert has_element?(view, "#jump-to-latest")
    refute has_element?(view, "#jump-to-latest-count")
    assert has_element?(view, "#load-newer")
    assert has_element?(view, "#timeline", "filler 50")
    refute has_element?(view, "#timeline", "filler 110")

    later = note(ctx, "arrived while reading history")
    assert has_element?(view, "#jump-to-latest-count", "1 new")
    refute has_element?(view, "##{dom_id(later)}")

    view |> element("#jump-to-latest") |> render_click()

    assert_push_event(view, "timeline:bottom", %{})
    refute has_element?(view, "#jump-to-latest")
    refute has_element?(view, "#load-newer")
    assert has_element?(view, "##{dom_id(later)}")
    refute has_element?(view, "##{dom_id(old)}")

    # live again: the next event goes straight in
    newest = note(ctx, "and another")
    assert has_element?(view, "##{dom_id(newest)}")
  end

  test "Load newer pages forward until the feed is live again", %{conn: conn} = ctx do
    old = history(ctx)
    {:ok, view, _html} = live(conn, msg_path(ctx.channel, old))
    assert has_element?(view, "#load-newer")

    view |> element("#load-newer") |> render_click()

    assert has_element?(view, "#timeline", "filler 110")
    assert has_element?(view, "##{dom_id(old)}")
    refute has_element?(view, "#load-newer")
    refute has_element?(view, "#jump-to-latest")
  end

  test "sending a message from history returns to the live feed", %{conn: conn} = ctx do
    old = history(ctx)
    {:ok, view, _html} = live(conn, msg_path(ctx.channel, old))
    assert has_element?(view, "#jump-to-latest")

    view |> form("#composer-form", message: %{body: "back to now"}) |> render_submit()

    refute has_element?(view, "#jump-to-latest")
    assert has_element?(view, "#timeline", "filler 110")
  end

  test "a message in another channel says so", %{conn: conn} = ctx do
    other = Fixtures.channel_fixture()
    {:ok, elsewhere} = Messages.post_user_note(other.id, ctx.user.id, "not here")

    {:ok, view, _html} = live(conn, msg_path(ctx.channel, elsewhere))

    assert render(view) =~ "That message isn&#39;t in this channel."
    refute has_element?(view, "#jump-to-latest")
  end

  test "a thread reply opens in its thread, marked", %{conn: conn} = ctx do
    {:ok, root} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "root of it")
    {:ok, reply} = Messages.thread_reply(root.id, {:agent, ctx.agent.id}, "the reply")

    {:ok, view, _html} = live(conn, msg_path(ctx.channel, reply))

    assert has_element?(view, "#thread-panel")
    assert has_element?(view, "#thread-replies [data-scroll-target]", "the reply")
  end

  test "the header searches the channel", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/channels/#{ctx.channel.id}")

    assert view |> element("#search-channel") |> render() =~
             ~s(href="/search?channel=#{ctx.channel.id}")
  end
end
