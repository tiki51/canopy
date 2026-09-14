defmodule Canopy.MCP.Tools.DocumentsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Documents, Messages}
  alias Canopy.MCP.Tools.{DocumentGet, DocumentsList}

  @png File.read!(Path.expand("../../../support/files/red.png", __DIR__))

  setup do
    ctx = scenario()

    {:ok, shot} =
      Documents.create(%{
        filename: "shot.png",
        mime: "image/png",
        source: {:binary, @png},
        user_id: ctx.user.id
      })

    {:ok, report} =
      Documents.create(%{
        filename: "report.md",
        source: {:binary, String.duplicate("line of analysis\n", 40)},
        agent_id: ctx.agent.id,
        caption: "retry analysis"
      })

    {:ok, _} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "look", attachments: [shot.id])

    Map.merge(ctx, %{shot: shot, report: report})
  end

  test "documents_list shows every file with where it was posted", ctx do
    assert {:ok, text} = call(DocumentsList, %{}, ctx)
    assert text =~ "2 file(s)"

    assert text =~
             "[#{ctx.shot.id}] shot.png (image, 75 B) by #{ctx.user.display_name}, just now, in ##{ctx.channel.name}"

    assert text =~
             "[#{ctx.report.id}] report.md (text, 680 B) by @#{ctx.agent.name}, just now, not posted anywhere"

    assert {:ok, text} = call(DocumentsList, %{search: "rep"}, ctx)
    refute text =~ "shot.png"
    assert {:ok, text} = call(DocumentsList, %{channel: ctx.channel.name}, ctx)
    refute text =~ "report.md"
    assert {:ok, text} = call(DocumentsList, %{kind: "image"}, ctx)
    refute text =~ "report.md"
    assert {:error, reason} = call(DocumentsList, %{kind: "video"}, ctx)
    assert reason =~ "kind must be"
    assert {:error, "unknown channel #nope"} = call(DocumentsList, %{channel: "nope"}, ctx)
  end

  test "document_get windows text and materialises the file in the repository", ctx do
    assert {:ok, text} = call(DocumentGet, %{document: ctx.report.id, length: 40}, ctx)

    assert text =~
             "#{ctx.report.id} report.md (text, 680 B) shared by @#{ctx.agent.name} just now"

    assert text =~ "Path in this repository: .canopy/files/#{ctx.report.id}-report.md"
    assert text =~ "Caption: retry analysis"
    assert text =~ "Content (chars 0..40 of 680):\nline of analysis\nline of analysis\nline o"
    assert text =~ "… (640 more chars; call again with offset=40)"

    assert File.read!(Path.join(ctx.repository.path, ".canopy/files/#{ctx.report.id}-report.md")) =~
             "line of analysis"

    assert {:ok, text} = call(DocumentGet, %{document: ctx.report.id, offset: 660}, ctx)
    assert text =~ "Content (chars 660..680 of 680)"
    refute text =~ "more chars"

    assert {:error, "unknown document \"doc_nope\""} =
             call(DocumentGet, %{document: "doc_nope"}, ctx)
  end

  test "document_get returns an image as image content", ctx do
    params = %{"canopy_session_id" => ctx.session.engine_session_id, "document" => ctx.shot.id}
    {:ok, validated} = DocumentGet.mcp_schema(params)
    {:reply, response, _frame} = DocumentGet.execute(validated, Anubis.Server.Frame.new())
    refute response.isError

    assert [
             %{"type" => "text", "text" => header},
             %{"type" => "image", "data" => data, "mimeType" => "image/png"}
           ] = response.content

    assert header =~ "embed with ![shot.png](/files/#{ctx.shot.id}/shot.png)"
    assert Base.decode64!(data) == @png
  end
end
