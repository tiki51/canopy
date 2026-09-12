defmodule Canopy.MCP.Tools.DocumentShareTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Documents, Messages}
  alias Canopy.MCP.Tools.{DocumentShare, MessageSend, ThreadReply}

  setup do
    ctx = scenario()
    out = Path.join(ctx.repository.path, ".canopy/out")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "report.md"), "# Findings\n\nRetries double-charge.\n")
    File.write!(Path.join(ctx.repository.path, "notes.txt"), "plain")
    ctx
  end

  test "shares a file from the repository and inline content", ctx do
    assert {:ok, text} =
             call(DocumentShare, %{path: ".canopy/out/report.md", caption: "the findings"}, ctx)

    assert text =~
             ~r/^shared \[(doc_\w+)\] report\.md \(text, 35 B\); attach it with attachments: "doc_/

    [_, id] = Regex.run(~r/\[(doc_\w+)\]/, text)
    doc = Documents.get(id)
    assert doc.agent_id == ctx.agent.id
    assert doc.origin_channel_id == ctx.channel.id
    assert doc.caption == "the findings"
    assert {:ok, "# Findings" <> _} = Documents.read(doc)

    assert {:ok, text} =
             call(DocumentShare, %{content: "# Plan\n1. fix", filename: "plan.md"}, ctx)

    assert text =~ "plan.md (text, 13 B)"

    assert {:ok, text} =
             call(DocumentShare, %{path: Path.join(ctx.repository.path, "notes.txt")}, ctx)

    assert text =~ "notes.txt (text, 5 B)"
  end

  test "refuses paths outside the repository, directories, and missing files", ctx do
    assert {:error, "../secrets is outside the repository"} =
             call(DocumentShare, %{path: "../secrets"}, ctx)

    assert {:error, "/etc/passwd is outside the repository"} =
             call(DocumentShare, %{path: "/etc/passwd"}, ctx)

    assert {:error, ".canopy is a directory"} = call(DocumentShare, %{path: ".canopy"}, ctx)
    assert {:error, "nope.md does not exist"} = call(DocumentShare, %{path: "nope.md"}, ctx)

    link = Path.join(ctx.repository.path, "escape.txt")
    File.ln_s!("/etc/hosts", link)

    assert {:error, "escape.txt is outside the repository"} =
             call(DocumentShare, %{path: "escape.txt"}, ctx)

    assert {:error, "filename is required when sharing content"} =
             call(DocumentShare, %{content: "x"}, ctx)

    assert {:error, "give path (a file in the repository) or content with filename"} =
             call(DocumentShare, %{}, ctx)

    assert {:error, "give either path or content, not both"} =
             call(DocumentShare, %{path: "notes.txt", content: "x", filename: "y"}, ctx)
  end

  test "message_send attaches by id and by path, and may be attachments only", ctx do
    {:ok, shot} =
      Documents.create(%{
        filename: "shot.png",
        mime: "image/png",
        source: {:binary, "png"},
        user_id: ctx.user.id
      })

    assert {:ok, text} =
             call(
               MessageSend,
               %{
                 text: "Report attached, @#{ctx.agent.name}",
                 attachments: "#{shot.id}, .canopy/out/report.md"
               },
               ctx
             )

    assert text =~
             ~r/^posted \[msg_\w+\] to #.* with 2 attachment\(s\): #{shot.id}, doc_\w+; mentioned @#{ctx.agent.name}$/

    [message] = Messages.list(ctx.channel.id)
    assert Enum.map(message.documents, & &1.filename) == ["shot.png", "report.md"]
    assert message.mentions == [ctx.agent.id]

    assert {:ok, text} = call(MessageSend, %{attachments: shot.id}, ctx)
    assert text =~ "with 1 attachment(s)"
    [_, only_files] = Messages.list(ctx.channel.id)
    assert only_files.body == ""

    assert {:error, "text is empty"} = call(MessageSend, %{}, ctx)

    assert {:error, "unknown document doc_nope"} =
             call(MessageSend, %{text: "x", attachments: "doc_nope"}, ctx)

    assert {:error, "missing.md does not exist"} =
             call(MessageSend, %{text: "x", attachments: "missing.md"}, ctx)
  end

  test "thread_reply carries attachments too", ctx do
    {:ok, root} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "root")

    assert {:ok, text} =
             call(ThreadReply, %{message_id: root.id, attachments: ".canopy/out/report.md"}, ctx)

    assert text =~
             ~r/^replied \[msg_\w+\] in thread \[#{root.id}\] in #.* with 1 attachment\(s\): doc_\w+$/

    [reply] = Messages.list(ctx.channel.id, thread: root.id) |> Enum.reject(&(&1.id == root.id))
    assert [%{filename: "report.md"}] = reply.documents
    assert {:error, "text is empty"} = call(ThreadReply, %{message_id: root.id}, ctx)
  end
end
