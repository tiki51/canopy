defmodule CanopyWeb.ChannelLiveFileViewerTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import CanopyWeb.LiveHelpers

  alias Canopy.{Documents, Fixtures, Messages, Runtime}
  alias CanopyWeb.ChannelLive
  alias Canopy.OpenCode.ClientMock, as: OC

  @png File.read!(Path.expand("../../support/files/red.png", __DIR__))

  setup :set_mox_global

  setup do
    scenario = Fixtures.scenario()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    scenario
  end

  defp doc(filename, content, mime \\ nil) do
    {:ok, doc} =
      Documents.create(%{
        filename: filename,
        mime: mime,
        source: {:binary, content},
        user_id: Fixtures.user_fixture().id
      })

    doc
  end

  defp share(%{channel: channel, agent: agent}, docs) do
    {:ok, message} =
      Messages.post_agent_message(channel.id, agent.id, "files",
        attachments: Enum.map(docs, & &1.id)
      )

    message
  end

  defp viewer_url(channel, doc, message, extra \\ []),
    do: ~p"/channels/#{channel.id}?#{extra ++ [file: doc.id, in: message.id]}"

  test "a tile opens the viewer; the arrows and strip move through the message", ctx do
    %{conn: conn, channel: channel} = ctx
    png = doc("chart.png", @png, "image/png")
    md = doc("notes.md", "# Notes\n\nhello\n")
    py = doc("retry.py", "x = 1\n")
    message = share(ctx, [md, png, py])

    {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}")
    refute has_element?(view, "#file-viewer")

    # tiles: images first; each opens the viewer and has its own Download
    assert has_element?(view, "#attachment-#{message.id}-#{png.id}[data-viewer-link]")

    assert has_element?(
             view,
             "a[href='#{Documents.url_path(md)}?download=1'][download]"
           )

    view |> element("#attachment-#{message.id}-#{png.id}") |> render_click()
    assert_patch(view, viewer_url(channel, png, message))

    assert has_element?(view, "#file-viewer[open][data-doc='#{png.id}']")
    assert has_element?(view, "#file-viewer-name", "chart.png")
    assert has_element?(view, "#file-viewer-image[src='#{Documents.url_path(png)}']")
    assert has_element?(view, "#file-viewer-open")
    assert has_element?(view, "#file-viewer-prev[aria-disabled=true]")
    assert has_element?(view, "#file-viewer-position", "1 of 3")

    assert has_element?(
             view,
             "#file-viewer-download[href='#{Documents.url_path(png)}?download=1']"
           )

    view |> element("#file-viewer-next") |> render_click()
    assert_patch(view, viewer_url(channel, md, message))
    assert has_element?(view, "#file-viewer[data-doc='#{md.id}']")
    assert has_element?(view, "#file-viewer-mode-preview")
    assert has_element?(view, "#file-viewer-preview h1", "Notes")
    assert has_element?(view, "#file-viewer-source .l-line")
    refute has_element?(view, "#file-viewer-open")

    view |> element("#file-viewer-thumb-#{py.id}") |> render_click()
    assert has_element?(view, "#file-viewer-language", "Python")
    assert has_element?(view, "#file-viewer-next[aria-disabled=true]")

    view |> element("#file-viewer-close") |> render_click()
    assert_patch(view, ~p"/channels/#{channel.id}")
    refute has_element?(view, "#file-viewer")
  end

  test "a single file has no arrows or strip", ctx do
    png = doc("only.png", @png, "image/png")
    message = share(ctx, [png])
    {:ok, view, _html} = live(ctx.conn, viewer_url(ctx.channel, png, message))

    assert has_element?(view, "#file-viewer")
    refute has_element?(view, "#file-viewer-prev")
    refute has_element?(view, "#file-viewer-strip")
  end

  test "HTML shows as escaped source and a zip as no preview", ctx do
    html = doc("page.html", "<h1 id=\"boom\">hi</h1>\n")
    zip = doc("fixtures.zip", <<80, 75, 3, 4, 0, 255>>, "application/zip")
    message = share(ctx, [html, zip])

    {:ok, view, _html} = live(ctx.conn, viewer_url(ctx.channel, html, message))
    assert has_element?(view, "#file-viewer-source")
    refute has_element?(view, "#file-viewer #boom")

    {:ok, view, _html} = live(ctx.conn, viewer_url(ctx.channel, zip, message))
    assert has_element?(view, "#file-viewer-none-#{zip.id}", "can't show a preview")
    assert has_element?(view, "#file-viewer-none-download[href$='?download=1']")
  end

  test "the viewer opens over an open thread and closing keeps it", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")
    log = doc("run.log", "ok\n")

    {:ok, reply} =
      Messages.thread_reply(root.id, {:agent, agent.id}, "log", attachments: [log.id])

    {:ok, view, _html} =
      live(ctx.conn, viewer_url(channel, log, reply, thread: root.id))

    assert has_element?(view, "#thread-panel")
    assert has_element?(view, "#file-viewer-meta", "in a thread")

    view |> element("#file-viewer-close") |> render_click()
    assert_patch(view, ~p"/channels/#{channel.id}?#{[thread: root.id]}")
    assert has_element?(view, "#thread-panel")
  end

  test "a tile opened over an open thread lays the viewer over it, and closing keeps it", ctx do
    %{channel: channel, user: user} = ctx
    png = doc("chart.png", @png, "image/png")
    message = share(ctx, [png])
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{channel.id}?#{[thread: root.id]}")
    assert has_element?(view, "#thread-panel")

    # the tile's own link carries only the viewer's params…
    view |> element("#attachment-#{message.id}-#{png.id}") |> render_click()
    assert_patch(view, viewer_url(channel, png, message))

    # …and the server puts the rest of the URL back
    path = assert_patch(view)

    assert path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() ==
             %{"thread" => root.id, "file" => png.id, "in" => message.id}

    assert has_element?(view, "#file-viewer[data-doc='#{png.id}']")
    assert has_element?(view, "#thread-panel")

    view |> element("#file-viewer-close") |> render_click()
    assert_patch(view, ~p"/channels/#{channel.id}?#{[thread: root.id]}")
    refute has_element?(view, "#file-viewer")
    assert has_element?(view, "#thread-panel")
  end

  test "patching to the URL already shown still has its say", ctx do
    %{channel: channel, agent: agent} = ctx
    live_url = ChannelLive.activity_path(channel.id, "live:" <> agent.id)

    # the agent isn't working yet: no panel
    {:ok, view, _html} = live(ctx.conn, live_url)
    refute has_element?(view, "#activity-panel")

    # it starts, and its card's live link points at the same URL
    broadcast_telemetry(channel.id, agent.id, :tool_started, %{
      call_id: "c1",
      tool: "read",
      status: :running,
      input: %{"filePath" => "lib/a.ex"},
      title: nil,
      message_id: "m",
      part_id: "p1"
    })

    view |> element("#telemetry-#{agent.id}-panel") |> render_click()
    assert_patch(view, live_url)
    assert has_element?(view, "#activity-panel")
  end

  test "a file from another conversation is refused", ctx do
    other = Fixtures.scenario()
    png = doc("theirs.png", @png, "image/png")
    message = share(other, [png])

    {:ok, view, _html} = live(ctx.conn, viewer_url(ctx.channel, png, message))
    refute has_element?(view, "#file-viewer")
    assert has_element?(view, "#flash-error", "That file isn't in this conversation.")
  end

  test "deleting the open file closes the viewer", ctx do
    png = doc("gone.png", @png, "image/png")
    message = share(ctx, [png])
    {:ok, view, _html} = live(ctx.conn, viewer_url(ctx.channel, png, message))
    assert has_element?(view, "#file-viewer")

    {:ok, _} = Documents.delete(png)

    assert_patch(view, ~p"/channels/#{ctx.channel.id}")
    refute has_element?(view, "#file-viewer")
    assert has_element?(view, "#flash-error", "That file was deleted.")
  end

  test "deleting another file of the message keeps the viewer open without it", ctx do
    png = doc("kept.png", @png, "image/png")
    log = doc("dropped.log", "x\n")
    message = share(ctx, [png, log])
    {:ok, view, _html} = live(ctx.conn, viewer_url(ctx.channel, png, message))
    assert has_element?(view, "#file-viewer-thumb-#{log.id}")

    {:ok, _} = Documents.delete(log)

    _ = render(view)
    assert has_element?(view, "#file-viewer[data-doc='#{png.id}']")
    refute has_element?(view, "#file-viewer-strip")
  end
end
