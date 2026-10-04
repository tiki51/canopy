defmodule CanopyWeb.SearchLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.{Channels, Documents, Fixtures, Messages, Timeline}
  alias CanopyWeb.SearchLive

  setup do
    Fixtures.scenario()
  end

  defp turn(ctx, payload) do
    {:ok, event} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "agent_turn_completed",
        ref_id: ctx.session.id,
        payload: Map.merge(%{"tools" => 2, "outcome" => "ok"}, payload)
      })

    event
  end

  defp href(view, selector) do
    [href] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")

    href
  end

  test "the empty page explains what is searched; the rail link is active", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    assert has_element?(view, "#search-form")
    assert has_element?(view, "#search-empty")
    refute has_element?(view, "#search-count-all")
    assert has_element?(view, "#rail-search.bg-neutral-content\\/15")
  end

  test "typing patches the URL and shows highlighted results", %{conn: conn} = ctx do
    {:ok, message} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "the enqueue_charge retry path")

    {:ok, view, _html} = live(conn, ~p"/search")

    view |> form("#search-form", %{q: "enqueue_charge ret"}) |> render_change()

    assert_patch(view, ~p"/search?#{[q: "enqueue_charge ret"]}")
    assert has_element?(view, "#result-#{message.id} mark", "enqueue_charge")
    assert has_element?(view, "#result-#{message.id} mark", "retry")
    assert has_element?(view, "#search-count-all", "1")
    assert has_element?(view, "#search-count-message", "1")

    assert href(view, "#result-#{message.id}") ==
             ~p"/channels/#{ctx.channel.id}?#{[msg: message.id]}"
  end

  test "each kind of result links to its exact place", %{conn: conn} = ctx do
    {:ok, root} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "kestrel root")
    {:ok, reply} = Messages.thread_reply(root.id, {:agent, ctx.agent.id}, "kestrel reply")
    event = turn(ctx, %{"files" => ["lib/kestrel.ex"]})

    {:ok, document} =
      Documents.create(%{
        filename: "kestrel.md",
        source: {:binary, "notes"},
        user_id: ctx.user.id
      })

    {:ok, _} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "file", attachments: [document.id])

    {:ok, view, _html} = live(conn, ~p"/search?q=kestrel")

    assert href(view, "#result-#{root.id}") == ~p"/channels/#{ctx.channel.id}?#{[msg: root.id]}"

    assert href(view, "#result-#{reply.id}") ==
             ~p"/channels/#{ctx.channel.id}?#{[thread: root.id, reply: reply.id]}"

    assert href(view, "#result-#{event.id}") ==
             ~p"/channels/#{ctx.channel.id}?#{[activity: event.id]}"

    assert has_element?(view, "#result-#{event.id}", "finished")
    assert href(view, "#result-#{document.id}") == Documents.url_path(document)
    assert has_element?(view, "#result-#{document.id}-posted")
    assert has_element?(view, "#search-count-turn", "1")
    assert has_element?(view, "#search-count-document", "1")
  end

  test "tabs and filters update the URL and the results", %{conn: conn} = ctx do
    other = Fixtures.channel_fixture(%{repository_id: ctx.repository.id})
    {:ok, mine} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "heron here")
    {:ok, theirs} = Messages.post_agent_message(other.id, other.owner_agent_id, "heron there")
    event = turn(ctx, %{"final_text" => "heron counted"})

    {:ok, view, _html} = live(conn, ~p"/search?q=heron")
    assert has_element?(view, "#result-#{event.id}")

    view |> element("#search-tab-message") |> render_click()
    assert_patch(view, ~p"/search?#{[q: "heron", kind: "message"]}")
    refute has_element?(view, "#result-#{event.id}")
    assert has_element?(view, "#result-#{mine.id}")
    # counts stay for every kind
    assert has_element?(view, "#search-count-turn", "1")

    view
    |> form("#search-filters", filters: %{channel: ctx.channel.id})
    |> render_change()

    assert_patch(view, ~p"/search?#{[q: "heron", kind: "message", channel: ctx.channel.id]}")
    assert has_element?(view, "#result-#{mine.id}")
    refute has_element?(view, "#result-#{theirs.id}")

    view
    |> form("#search-filters",
      filters: %{channel: "", agent: other.owner_agent_id, sort: "newest"}
    )
    |> render_change()

    assert_patch(
      view,
      ~p"/search?#{[q: "heron", kind: "message", agent: other.owner_agent_id, sort: "newest"]}"
    )

    assert has_element?(view, "#result-#{theirs.id}")
    refute has_element?(view, "#result-#{mine.id}")

    view |> form("#search-filters", filters: %{agent: "me"}) |> render_change()
    assert has_element?(view, "#result-#{mine.id}")
    refute has_element?(view, "#result-#{theirs.id}")
  end

  test "mounting with params restores the form; unknown params are ignored",
       %{conn: conn} = ctx do
    {:ok, message} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "osprey nest")

    {:ok, view, _html} =
      live(
        conn,
        ~p"/search?#{[q: "osprey", channel: ctx.channel.id, date: "custom", from: "2020-01-01", to: "2999-01-01", sort: "newest"]}"
      )

    assert has_element?(view, "#search-input[value=osprey]")
    assert has_element?(view, "#search-filters_channel option[selected][value=#{ctx.channel.id}]")
    assert has_element?(view, "#search-filters_date option[selected][value=custom]")
    assert has_element?(view, "#search-filters_from[value='2020-01-01']")
    assert has_element?(view, "#search-filters_sort option[selected][value=newest]")
    assert has_element?(view, "#result-#{message.id}")

    {:ok, view, _html} =
      live(
        conn,
        "/search?q=osprey&kind=bogus&channel=ch_nope&agent=nobody&date=yesterday&sort=up"
      )

    assert has_element?(view, "#result-#{message.id}")
    assert has_element?(view, "#search-tab-all[aria-current=page]")
    refute has_element?(view, "#search-filters_channel option[selected]")
  end

  test "Show more appends the next page", %{conn: conn} = ctx do
    for i <- 1..35, do: Messages.post_user_message(ctx.channel.id, ctx.user.id, "puffin #{i}")

    {:ok, view, _html} = live(conn, ~p"/search?q=puffin")

    assert has_element?(view, "#search-shown", "30 of 35")
    view |> element("#search-more") |> render_click()
    assert has_element?(view, "#search-shown", "35 of 35")
    refute has_element?(view, "#search-more")

    rows = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#search-results > li")
    assert Enum.count(rows) == 35
  end

  test "nothing found offers a wider search", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/search?#{[q: "zzyzx", channel: ctx.channel.id]}")

    assert has_element?(view, "#search-none", "in ##{ctx.channel.name}")
    assert href(view, "#search-everywhere") == ~p"/search?q=zzyzx"
    assert has_element?(view, "#search-include-archived")
  end

  test "archived channels need the toggle", %{conn: conn} = ctx do
    {:ok, message} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "ibis archived")
    {:ok, _} = Channels.archive(Channels.get!(ctx.channel.id))

    {:ok, view, _html} = live(conn, ~p"/search?q=ibis")
    refute has_element?(view, "#result-#{message.id}")

    view |> element("#search-include-archived") |> render_click()
    assert_patch(view, ~p"/search?#{[q: "ibis", archived: "1"]}")
    assert has_element?(view, "#result-#{message.id}")
  end

  test "snippets are escaped; only the match markers become marks" do
    {open, close} = Canopy.Search.marks()

    html =
      "<script>alert(1)</script>  a  #{open}hit#{close}"
      |> SearchLive.snippet()
      |> Phoenix.HTML.safe_to_string()

    assert html == "&lt;script&gt;alert(1)&lt;/script&gt; a <mark>hit</mark>"
  end

  test "a snippet drops Markdown but keeps inline code, safely" do
    {open, close} = Canopy.Search.marks()

    html =
      "- **Root cause.** the `#{open}claim#{close}` step <b>x</b>"
      |> SearchLive.snippet()
      |> Phoenix.HTML.safe_to_string()

    assert html ==
             "Root cause. the <code><mark>claim</mark></code> step &lt;b&gt;x&lt;/b&gt;"

    # a turn's output or a source file keeps its text as written
    raw =
      "def __init__(self): **kwargs #{open}hit#{close}"
      |> SearchLive.snippet(false)
      |> Phoenix.HTML.safe_to_string()

    assert raw == "def __init__(self): **kwargs <mark>hit</mark>"
  end

  test "the search box has one clear button: the browser's own is hidden", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?#{[q: "ibis"]}")

    input = view |> element("#search-input") |> render()
    assert input =~ "[&amp;::-webkit-search-cancel-button]:appearance-none"
    assert has_element?(view, "#search-clear")
    # the magnifier paints above the input's background
    assert has_element?(view, "#search-form > .hero-magnifying-glass.z-10")
  end
end
