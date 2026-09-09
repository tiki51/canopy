defmodule Canopy.MCP.Tools.MessagesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Messages, Timeline}
  alias Canopy.MCP.Tools.{MessageSend, MessagesRead, MessagesSearch, ThreadReply}

  setup do
    other = agent_fixture(name: "reviewer-" <> unique_suffix())
    ctx = scenario(members: [other])

    outsider_channel =
      channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: other.id,
        name: "private-" <> unique_suffix()
      })

    Map.merge(ctx, %{other: other, outsider_channel: outsider_channel})
  end

  defp post(ctx, body),
    do: Messages.post_agent_message(ctx.channel.id, ctx.agent.id, body) |> elem(1)

  describe "message_send" do
    test "posts as the caller, extracts mentions, and records a timeline event", ctx do
      Timeline.subscribe(ctx.channel.id)

      assert {:ok, text} =
               call(MessageSend, %{text: "Found it, @#{ctx.other.name} please review"}, ctx)

      assert [_, id] = Regex.run(~r/posted \[(msg_[^\]]+)\] to ##{ctx.channel.name}/, text)
      assert text =~ "mentioned @#{ctx.other.name}"

      message = Messages.get!(id)
      assert message.agent_id == ctx.agent.id
      assert message.kind == "post"
      assert message.mentions == [ctx.other.id]

      assert_receive {:timeline,
                      %Timeline.Event{event_type: "message", ref_id: ^id, agent_id: agent_id}}

      assert agent_id == ctx.agent.id
    end

    test "rejects blank text and channels the caller is not a member of", ctx do
      assert {:error, "text is empty"} = call(MessageSend, %{text: "   "}, ctx)

      assert {:error, message} =
               call(MessageSend, %{channel: ctx.outsider_channel.name, text: "hi"}, ctx)

      assert message == "not a member of ##{ctx.outsider_channel.name}"
      assert Messages.list(ctx.outsider_channel.id) == []
    end

    test "requires text at the schema level", ctx do
      assert {:invalid, _} = call(MessageSend, %{}, ctx)
    end
  end

  describe "messages_read" do
    test "returns the latest messages oldest first with ids and senders", ctx do
      messages = for n <- 1..5, do: post(ctx, "message #{n}")

      {:ok, user_message} =
        Messages.post_user_message(ctx.channel.id, ctx.user.id, "from the user")

      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "##{ctx.channel.name}: 6 message(s), oldest first"

      lines = text |> String.split("\n") |> tl()
      assert length(lines) == 6
      assert List.first(lines) =~ "[#{hd(messages).id}] @#{ctx.agent.name} (just now): message 1"

      assert List.last(lines) =~
               "[#{user_message.id}] #{ctx.user.display_name} (just now): from the user"
    end

    test "supports before, around, thread, and a clamped limit", ctx do
      messages = for n <- 1..8, do: post(ctx, "message #{n}")
      [m1, m2, m3, m4, m5, m6, m7, m8] = messages
      {:ok, reply} = Messages.thread_reply(m4.id, {:agent, ctx.other.id}, "in the thread")

      assert {:ok, text} = call(MessagesRead, %{before: m3.id}, ctx)
      assert text =~ "2 message(s)"
      assert text =~ m1.id and text =~ m2.id
      refute text =~ m3.id

      assert {:ok, text} = call(MessagesRead, %{around: m5.id, limit: 4}, ctx)
      ids = Regex.scan(~r/\[(msg_[^\]]+)\]/, text) |> Enum.map(&List.last/1)
      assert ids == [m3.id, m4.id, m5.id, m6.id]

      assert {:ok, text} = call(MessagesRead, %{thread: m4.id}, ctx)
      ids = Regex.scan(~r/^\[(msg_[^\]]+)\]/m, text) |> Enum.map(&List.last/1)
      assert ids == [m4.id, reply.id]
      assert text =~ "(in thread #{m4.id}): in the thread"

      assert {:ok, text} = call(MessagesRead, %{limit: 2}, ctx)
      assert text =~ "2 message(s)"
      assert text =~ m8.id and text =~ reply.id
      refute text =~ m7.id

      for n <- 9..60, do: post(ctx, "filler #{n}")
      assert {:ok, text} = call(MessagesRead, %{limit: 500}, ctx)
      assert text =~ "50 message(s)"
    end

    test "reports an empty channel and enforces membership", ctx do
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "0 message(s)"
      assert text =~ "(no messages)"

      assert {:error, message} = call(MessagesRead, %{channel: ctx.outsider_channel.id}, ctx)
      assert message == "not a member of ##{ctx.outsider_channel.name}"
    end
  end

  describe "messages_search" do
    test "returns matching messages with snippets", ctx do
      hit = post(ctx, "The payment retries are duplicated in the worker")
      _miss = post(ctx, "Unrelated chatter about lunch")

      assert {:ok, text} = call(MessagesSearch, %{query: "payment retr*"}, ctx)
      assert text =~ "1 match(es) in ##{ctx.channel.name}"
      assert text =~ "[#{hit.id}] @#{ctx.agent.name} (just now): "
      assert text =~ "**payment**"
      refute text =~ "lunch"

      assert {:ok, text} = call(MessagesSearch, %{query: "nothing-here"}, ctx)
      assert text =~ "No messages in ##{ctx.channel.name} match"

      assert {:error, "query is empty"} = call(MessagesSearch, %{query: "  "}, ctx)
    end
  end

  describe "thread_reply" do
    test "replies in the parent's thread as the caller", ctx do
      root = post(ctx, "root")
      {:ok, first_reply} = Messages.thread_reply(root.id, {:user, ctx.user.id}, "user reply")

      assert {:ok, text} =
               call(ThreadReply, %{message_id: first_reply.id, text: "agent reply"}, ctx)

      assert [_, id] =
               Regex.run(
                 ~r/replied \[(msg_[^\]]+)\] in thread \[#{root.id}\] in ##{ctx.channel.name}/,
                 text
               )

      reply = Messages.get!(id)
      assert reply.thread_id == root.id
      assert reply.agent_id == ctx.agent.id
      assert reply.kind == "thread_reply"
    end

    test "refuses unknown messages and threads in channels the caller cannot see", ctx do
      assert {:error, "unknown message msg_missing"} =
               call(ThreadReply, %{message_id: "msg_missing", text: "x"}, ctx)

      {:ok, hidden} = Messages.post_agent_message(ctx.outsider_channel.id, ctx.other.id, "secret")
      assert {:error, message} = call(ThreadReply, %{message_id: hidden.id, text: "x"}, ctx)
      assert message == "not a member of ##{ctx.outsider_channel.name}"
    end
  end
end
