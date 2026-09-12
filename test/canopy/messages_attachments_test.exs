defmodule Canopy.MessagesAttachmentsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Documents, Messages, Timeline}
  alias Canopy.MCP.Format

  setup do
    ctx = scenario()

    {:ok, a} =
      Documents.create(%{
        filename: "shot.png",
        mime: "image/png",
        source: {:binary, "png"},
        user_id: ctx.user.id
      })

    {:ok, b} =
      Documents.create(%{filename: "report.md", source: {:binary, "# hi"}, user_id: ctx.user.id})

    Map.merge(ctx, %{doc_a: a, doc_b: b})
  end

  test "attaches documents in order and records them on the event", ctx do
    {:ok, message} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "see these",
        attachments: [ctx.doc_b.id, ctx.doc_a.id]
      )

    assert Enum.map(message.documents, & &1.id) == [ctx.doc_b.id, ctx.doc_a.id]

    [event] = Timeline.list(ctx.channel.id) |> Enum.filter(&(&1.event_type == "message"))
    assert event.payload["attachments"] == [ctx.doc_b.id, ctx.doc_a.id]
    assert Enum.map(event.message.documents, & &1.id) == [ctx.doc_b.id, ctx.doc_a.id]

    [listed] = Messages.list(ctx.channel.id)
    assert length(listed.documents) == 2
  end

  test "a message may be attachment-only, but never empty", ctx do
    {:ok, message} =
      Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "", attachments: [ctx.doc_a.id])

    assert message.body == ""
    assert {:error, changeset} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "")
    assert %{body: _} = errors_on(changeset)
  end

  test "unknown or too many documents are rejected as strings", ctx do
    assert {:error, "unknown document doc_nope"} =
             Messages.post_user_message(ctx.channel.id, ctx.user.id, "x",
               attachments: ["doc_nope"]
             )

    too_many = Enum.map(1..11, fn _ -> ctx.doc_a.id end) ++ ["doc_x"]

    assert {:error, "at most 10 attachments per message"} =
             Messages.post_user_message(ctx.channel.id, ctx.user.id, "x",
               attachments: too_many ++ Enum.map(1..10, &"doc_#{&1}")
             )
  end

  test "duplicates collapse and thread replies carry attachments too", ctx do
    {:ok, root} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "root")

    {:ok, reply} =
      Messages.thread_reply(root.id, {:agent, ctx.agent.id}, "",
        attachments: [ctx.doc_a.id, ctx.doc_a.id]
      )

    assert Enum.map(reply.documents, & &1.id) == [ctx.doc_a.id]
    assert reply.thread_id == root.id
  end

  test "deleting a document removes it from the message", ctx do
    {:ok, message} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "x", attachments: [ctx.doc_a.id])

    {:ok, _} = Documents.delete(ctx.doc_a)
    assert Messages.get!(message.id).documents == []
    assert Documents.usages(ctx.doc_b) == []

    {:ok, _} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "y", attachments: [ctx.doc_b.id])

    assert [%{channel: %{id: cid}}] = Documents.usages(ctx.doc_b)
    assert cid == ctx.channel.id
    assert [doc] = Documents.list(channel: ctx.channel.id)
    assert doc.id == ctx.doc_b.id
  end

  test "the tool line lists attachments after the body", ctx do
    {:ok, message} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "",
        attachments: [ctx.doc_a.id, ctx.doc_b.id]
      )

    line = Format.message_line(message)

    assert line =~
             ": (no text) [attachments: #{ctx.doc_a.id} shot.png (image, 3 B); #{ctx.doc_b.id} report.md (text, 4 B)]"

    assert Format.message_line(message, bodies: false) ==
             "[#{message.id}] #{ctx.user.display_name} (just now)"
  end

  test "commands cannot carry attachments", ctx do
    assert {:error, "commands cannot carry attachments"} =
             Canopy.Runtime.post_user_message(ctx.channel.id, "/handoff @x reason",
               attachments: [ctx.doc_a.id]
             )
  end
end
