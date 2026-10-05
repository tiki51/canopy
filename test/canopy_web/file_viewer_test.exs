defmodule CanopyWeb.FileViewerTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Documents, Messages}
  alias CanopyWeb.{FileViewer, Highlight}

  @png File.read!(Path.expand("../support/files/red.png", __DIR__))

  defp doc(filename, content, mime \\ nil) do
    {:ok, doc} =
      Documents.create(%{
        filename: filename,
        mime: mime,
        source: {:binary, content},
        user_id: user_fixture().id
      })

    doc
  end

  defp message_with(docs) do
    %{channel: channel, agent: agent} = scenario()

    {:ok, message} =
      Messages.post_agent_message(channel.id, agent.id, "files",
        attachments: Enum.map(docs, & &1.id)
      )

    {Messages.get(message.id), channel}
  end

  describe "ordered/1 and load/3" do
    test "images come first, each group in attachment order, and the index follows" do
      md = doc("notes.md", "# hi")
      png = doc("a.png", @png, "image/png")
      py = doc("retry.py", "x = 1\n")
      png2 = doc("b.png", @png, "image/png")
      {message, channel} = message_with([md, png, py, png2])

      assert Enum.map(FileViewer.ordered(message.documents), & &1.filename) ==
               ["a.png", "b.png", "notes.md", "retry.py"]

      assert {:ok, viewer} = FileViewer.load(message, py.id, channel: channel)
      assert viewer.index == 3
      assert viewer.kind == :code
      assert FileViewer.load(message, "doc_nope") == :error
    end

    test "Markdown has a Preview and highlighted Source" do
      md = doc("RETRY.md", "# Title\n\nline one\nline two\n\n```python\nx = 1\n```\n")
      {message, channel} = message_with([md])
      {:ok, viewer} = FileViewer.load(message, md.id, channel: channel)

      assert viewer.kind == :markdown
      assert viewer.line_count == 8
      assert viewer.preview_html =~ ~s(<h1 id="doc-title">)
      refute viewer.preview_html =~ "<br"
      assert viewer.source_html =~ ~s(class="l-line")
      assert viewer.raw =~ "# Title"
    end

    test "HTML is highlighted source, never rendered" do
      html = doc("page.html", "<script>alert(1)</script>\n")
      {message, channel} = message_with([html])
      {:ok, viewer} = FileViewer.load(message, html.id, channel: channel)

      assert viewer.kind == :code
      assert viewer.language == "HTML"
      refute viewer.source_html =~ "<script>"
      assert viewer.source_html =~ "&lt;"
    end

    test "an SVG is escaped XML source, never drawn" do
      svg = doc("logo.svg", ~s{<svg onload="alert(1)"><circle r="4"/></svg>\n})
      assert svg.mime == "image/svg+xml"
      {message, channel} = message_with([svg])
      {:ok, viewer} = FileViewer.load(message, svg.id, channel: channel)

      assert viewer.kind == :code
      assert viewer.language == "SVG"
      assert viewer.source_html =~ "&lt;"
      refute viewer.source_html =~ "<svg"
    end

    test "a zip has no preview and an unknown text is plain text" do
      zip = doc("fixtures.zip", <<80, 75, 3, 4, 0, 0, 255>>, "application/zip")
      log = doc("replay.log", "one\ntwo\n")
      {message, channel} = message_with([zip, log])

      {:ok, viewer} = FileViewer.load(message, zip.id, channel: channel)
      assert viewer.kind == :none
      assert viewer.label == "ZIP archive"

      {:ok, viewer} = FileViewer.load(message, log.id, channel: channel)
      assert viewer.kind == :text
      assert viewer.language == "Plain text"
      assert viewer.label == "Text"
    end

    test "a long text shows its first 5,000 lines" do
      text = Enum.map_join(1..5_200, "\n", &"line #{&1}") <> "\n"
      log = doc("big.log", text)
      {message, channel} = message_with([log])
      {:ok, viewer} = FileViewer.load(message, log.id, channel: channel)

      assert viewer.truncated
      assert viewer.line_count == 5_200
      assert viewer.shown_lines == 5_000
      assert FileViewer.file_meta(viewer) =~ "5,200 lines"
    end

    test "a Markdown file over 1 MB turns Preview off" do
      md = doc("huge.md", String.duplicate("word ", 220_000))
      {message, channel} = message_with([md])
      {:ok, viewer} = FileViewer.load(message, md.id, channel: channel)

      assert viewer.preview_off
      assert viewer.preview_html == nil
      assert viewer.truncated
    end
  end

  describe "labels" do
    test "kinds, types and short labels" do
      assert FileViewer.type_label(%{filename: "x.png", kind: "image"}) == "PNG"
      assert FileViewer.type_label(%{filename: "x.pdf", kind: "pdf"}) == "PDF"
      assert FileViewer.type_label(%{filename: "x.md", kind: "text"}) == "Markdown"
      assert FileViewer.type_label(%{filename: "x.ex", kind: "text"}) == "Elixir"
      assert FileViewer.type_label(%{filename: "Dockerfile", kind: "text"}) == "Dockerfile"
      assert FileViewer.type_label(%{filename: "x.bin", kind: "other"}) == "BIN file"
      assert FileViewer.type_label(%{filename: "README", kind: "other"}) == "File"

      assert FileViewer.kind(%{filename: "logo.svg", kind: "other", mime: "image/svg+xml"}) ==
               :code

      assert FileViewer.kind(%{filename: "x.svgz", kind: "other", mime: "image/svg+xml"}) == :none
      assert FileViewer.short_label(%{filename: "retry.py"}) == "PY"
      assert FileViewer.lines_label(48_120) == "48,120 lines"
      assert FileViewer.lines_label(1) == "1 line"
    end

    test "origin names the author, the place and the time" do
      at = ~U[2026-10-04 14:42:00Z]
      time = CanopyWeb.TimelineComponents.short_time(at)
      channel = %{kind: "channel", name: "payment-retries"}
      agent_message = %{agent: %{name: "backend"}, user: nil, thread_id: nil, inserted_at: at}

      user_message = %{
        agent: nil,
        user: %{display_name: "Priya"},
        thread_id: nil,
        inserted_at: at
      }

      assert FileViewer.origin(agent_message, channel, "Priya") ==
               "@backend in #payment-retries, #{time}"

      assert FileViewer.origin(user_message, channel, "Priya") ==
               "Priya in #payment-retries, #{time}"

      assert FileViewer.origin(agent_message, %{kind: "dm", name: "dm"}, nil) ==
               "@backend in a DM, #{time}"

      assert FileViewer.origin(%{agent_message | thread_id: "msg_1"}, channel, nil) ==
               "@backend in a thread, #{time}"
    end
  end

  describe "Highlight" do
    test "maps extensions and fence names to languages" do
      assert Highlight.language("lib/a.ex") == {"elixir", "Elixir"}
      assert Highlight.language("Makefile") == {nil, "Makefile"}
      assert Highlight.language("Main.kt") == {nil, "Kotlin"}
      assert Highlight.language("notes.txt") == nil
      assert Highlight.fence_language("python") == "python"
      assert Highlight.fence_language("py") == "python"
      assert Highlight.fence_language("brainfuck") == nil
    end

    test "one escaped line span per line, coloured when the language is known" do
      html = Highlight.code("def f():\n    return \"<b>\"\n", "python")
      assert length(Regex.scan(~r/class="l-line"/, html)) == 2
      assert html =~ ~s(class="l-keyword)
      assert html =~ "&lt;b&gt;"

      plain = Highlight.code("a\n\nb", nil)
      assert length(Regex.scan(~r/class="l-line"/, plain)) == 3
      refute plain =~ "\n<span"
    end

    test "a big text or a very long line stays plain" do
      long_line = ~s({"k": ") <> String.duplicate("v", 6_000) <> ~s("}\n)
      refute Highlight.colourable?(long_line)
      refute Highlight.code(long_line, "json") =~ "l-string"

      big = String.duplicate("x = 1\n", 50_000)
      refute Highlight.colourable?(big)
      assert Highlight.code(big, "python") =~ ~s(class="language-plaintext")

      assert Highlight.colourable?("x = 1\n")
    end

    test "CRLF lines lose their \\r and an empty file has no lines" do
      plain = Highlight.code("a\r\nb\r\n", nil)
      assert length(Regex.scan(~r/class="l-line"/, plain)) == 2
      refute plain =~ "\r"
      refute Highlight.code("x = 1\r\n", "python") =~ "\r"

      refute Highlight.code("", nil) =~ "l-line"
      assert length(Regex.scan(~r/class="l-line"/, Highlight.code("\n", nil))) == 1
    end
  end
end
