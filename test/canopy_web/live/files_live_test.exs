defmodule CanopyWeb.FilesLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Canopy.{Documents, Fixtures, Messages}

  @png File.read!(Path.expand("../../support/files/red.png", __DIR__))

  setup do
    scenario = Fixtures.scenario()

    {:ok, shot} =
      Documents.create(%{
        filename: "shot.png",
        mime: "image/png",
        source: {:binary, @png},
        user_id: scenario.user.id
      })

    {:ok, report} =
      Documents.create(%{
        filename: "report.md",
        source: {:binary, "# hi"},
        agent_id: scenario.agent.id
      })

    {:ok, _} =
      Messages.post_user_message(scenario.channel.id, scenario.user.id, "see",
        attachments: [shot.id]
      )

    Map.merge(scenario, %{shot: shot, report: report})
  end

  test "lists every document with sharer, usage, and filters", ctx do
    {:ok, view, html} = live(ctx.conn, ~p"/files")

    assert html =~ "2 file(s)"
    assert has_element?(view, "#file-#{ctx.shot.id}[data-kind=image]", "shot.png")

    assert has_element?(
             view,
             "#file-#{ctx.shot.id} a[href='/channels/#{ctx.channel.id}']",
             "#" <> ctx.channel.name
           )

    assert has_element?(view, "#file-#{ctx.report.id}", "@" <> ctx.agent.name)
    assert has_element?(view, "#file-#{ctx.report.id}", "not posted anywhere")

    view |> form("#files-filter", q: "rep", kind: "all") |> render_change()
    refute has_element?(view, "#file-#{ctx.shot.id}")
    assert has_element?(view, "#file-#{ctx.report.id}")

    view |> form("#files-filter", q: "", kind: "image") |> render_change()
    assert has_element?(view, "#file-#{ctx.shot.id}")
    refute has_element?(view, "#file-#{ctx.report.id}")
  end

  test "share to navigates into the channel with the document picked", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/files")

    view
    |> element("#file-#{ctx.report.id} form")
    |> render_submit(%{document_id: ctx.report.id, channel_id: ctx.channel.id})

    {path, _flash} = assert_redirect(view)
    assert path == "/channels/#{ctx.channel.id}?attach=#{ctx.report.id}"
  end

  test "delete removes the document everywhere", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/files")
    view |> element("#delete-file-#{ctx.shot.id}") |> render_click()
    refute has_element?(view, "#file-#{ctx.shot.id}")
    assert Documents.get(ctx.shot.id) == nil
    assert render(view) =~ "1 file(s)"
  end
end
