defmodule Canopy.MCP.Tools.MessagesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Messages, Reactions, Timeline}
  alias Canopy.MCP.Format
  alias Canopy.MCP.Tools.{MessageGet, MessageSend, MessagesRead, MessagesSearch, ThreadReply}

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

    test "without text or attachments is refused", ctx do
      assert {:error, "text is empty"} = call(MessageSend, %{}, ctx)
    end
  end

  describe "messages_read" do
    test "the first read returns the latest messages; later reads return only what is new", ctx do
      messages = for n <- 1..5, do: post(ctx, "message #{n}")

      {:ok, user_message} =
        Messages.post_user_message(ctx.channel.id, ctx.user.id, "from the user")

      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "##{ctx.channel.name}: latest 6 message(s), oldest first (first read here)"

      lines = text |> String.split("\n") |> tl()
      assert length(lines) == 6
      assert List.first(lines) =~ "[#{hd(messages).id}] @#{ctx.agent.name} (just now): message 1"

      assert List.last(lines) =~
               "[#{user_message.id}] #{ctx.user.display_name} (just now): from the user"

      # nothing new: no bodies come back, and the context stays small
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "nothing new since your last read"
      refute text =~ "message 1"

      # two more posts: only those
      m7 = post(ctx, "message 7")
      m8 = post(ctx, "message 8")
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "2 new message(s) since your last read"
      assert text =~ m7.id and text =~ m8.id
      refute text =~ user_message.id

      # the marker is per agent: another member starts from its own first read
      other_session = session_fixture(%{channel: ctx.channel, agent_id: ctx.other.id})
      assert {:ok, text} = call(MessagesRead, %{}, other_session)
      assert text =~ "(first read here)"
    end

    test "long bodies are shortened and message_get returns them in full", ctx do
      long = String.duplicate("word ", 200)
      m = post(ctx, long)

      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "… (+"
      assert text =~ "canopy_message_get for the full text"
      refute text =~ String.duplicate("word ", 150)

      assert {:ok, full} = call(MessageGet, %{id: m.id}, ctx)
      assert full =~ String.duplicate("word ", 200) |> String.trim()
      refute full =~ "canopy_message_get"

      assert {:error, reason} = call(MessageGet, %{id: "msg_nope"}, ctx)
      assert reason =~ "unknown message"
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
      assert text =~ "thread [#{m4.id}] in ##{ctx.channel.name}: 1 reply, oldest first"
      assert text =~ "(in thread #{m4.id}): in the thread"

      # anchored reads move the marker too (the around read saw up to m6); a
      # thread read does not, so what came after m6 is still new
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "3 new message(s) since your last read"
      assert text =~ "[#{m7.id}]" and text =~ "[#{m8.id}]" and text =~ "[#{reply.id}]"
      m9 = post(ctx, "message 9")
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "1 new message(s) since your last read"
      assert text =~ m9.id
      refute text =~ "[#{m8.id}]" and text =~ "[#{m7.id}]"

      for n <- 9..60, do: post(ctx, "filler #{n}")
      assert {:ok, text} = call(MessagesRead, %{before: m1.id, limit: 500}, ctx)
      assert text =~ "0 message(s)"
      assert {:ok, text} = call(MessagesRead, %{limit: 500}, ctx)
      assert text =~ "50 new message(s)"
    end

    test "reports an empty channel and enforces membership", ctx do
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "0 message(s)"
      assert text =~ "(no messages)"

      assert {:error, message} = call(MessagesRead, %{channel: ctx.outsider_channel.id}, ctx)
      assert message == "not a member of ##{ctx.outsider_channel.name}"
    end
  end

  describe "reactions" do
    defp react(message, reactor, key), do: {:ok, :added} = Reactions.add(message.id, reactor, key)

    test "show inline after the body in messages_read and message_get", ctx do
      m = post(ctx, "Ship the retry fix after CI?")
      plain = post(ctx, "no reactions here")
      react(m, {:user, ctx.user.id}, "check")
      react(m, {:agent, ctx.other.id}, "check")
      react(m, {:agent, ctx.other.id}, "eyes")

      suffix =
        "[reactions: ✅ check: #{ctx.user.display_name}, @#{ctx.other.name}; 👀 eyes: @#{ctx.other.name}]"

      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "Ship the retry fix after CI? " <> suffix

      assert String.ends_with?(
               text,
               "[#{plain.id}] @#{ctx.agent.name} (just now): no reactions here"
             )

      assert {:ok, full} = call(MessageGet, %{id: m.id}, ctx)
      assert String.ends_with?(full, suffix)

      assert Format.reactions_suffix(Messages.get!(plain.id)) == ""
      assert Format.reactions_suffix(%Messages.Message{}) == ""
    end

    test "the no-anchor read lists reactions on older messages since the reader's cursor", ctx do
      mine = post(ctx, "Ship the retry fix after CI?")

      {:ok, theirs} =
        Messages.post_agent_message(ctx.channel.id, ctx.other.id, "Repro steps for the 502")

      react(mine, {:user, ctx.user.id}, "check")

      # the first read sets the cursor; the reaction already shows inline
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "(first read here)"
      assert text =~ "[reactions: ✅ check"
      refute text =~ "Reactions since your last read"

      react(mine, {:agent, ctx.other.id}, "eyes")
      react(theirs, {:user, ctx.user.id}, "thumbs_up")
      # the reader's own reaction is not news to it
      react(theirs, {:agent, ctx.agent.id}, "heart")

      {:ok, fresh} = Messages.post_agent_message(ctx.channel.id, ctx.other.id, "Fixed the 502")
      # on a message the read lists anyway: inline only
      react(fresh, {:user, ctx.user.id}, "tada")

      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      [listing, trailer] = String.split(text, "\n\n", parts: 2)
      assert listing =~ "1 new message(s) since your last read"
      assert listing =~ "Fixed the 502 [reactions: 🎉 tada: #{ctx.user.display_name}]"

      assert [
               "Reactions since your last read:",
               own,
               other
             ] = String.split(trailer, "\n")

      # reactions to the reader's own messages come first
      assert own ==
               ~s|- @#{ctx.other.name} 👀 eyes on your [#{mine.id}] "Ship the retry fix after CI?" (just now)|

      assert other ==
               ~s|- #{ctx.user.display_name} 👍 thumbs_up on [#{theirs.id}] from @#{ctx.other.name} "Repro steps for the 502" (just now)|

      # nothing new after that
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "nothing new since your last read"
      refute text =~ "Reactions since"

      # reactions only
      react(theirs, {:user, ctx.user.id}, "heart")
      assert {:ok, text} = call(MessagesRead, %{}, ctx)

      assert text =~
               "##{ctx.channel.name}: no new messages since your last read; 1 new reaction(s) below."

      assert text =~ "❤️ heart on [#{theirs.id}]"
    end

    test "anchored and thread reads neither list reactions nor move the cursor", ctx do
      m = post(ctx, "root")
      {:ok, _} = call(MessagesRead, %{}, ctx)
      cursor = Messages.last_reaction_read(ctx.agent.id, ctx.channel.id)

      react(m, {:user, ctx.user.id}, "check")

      for params <- [%{around: m.id}, %{before: "msg_~"}, %{thread: m.id}] do
        assert {:ok, text} = call(MessagesRead, params, ctx)
        refute text =~ "Reactions since"
        assert Messages.last_reaction_read(ctx.agent.id, ctx.channel.id) == cursor
      end

      # the next catch-up still has it: on a message already read, so in the trailer
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "no new messages since your last read; 1 new reaction(s) below."
    end

    test "a long excerpt is cut to 60 characters", ctx do
      m = post(ctx, String.duplicate("long words ", 20))
      {:ok, _} = call(MessagesRead, %{}, ctx)
      react(m, {:user, ctx.user.id}, "check")

      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      [_, excerpt] = Regex.run(~r/your \[msg_[^\]]+\] "([^"]+)"/, text)
      assert String.length(excerpt) == 60
      assert String.ends_with?(excerpt, "…")
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

    test "also_send_to_channel shows the reply in the channel feed too", ctx do
      root = post(ctx, "root")

      assert {:ok, text} =
               call(
                 ThreadReply,
                 %{message_id: root.id, text: "conclusion", also_send_to_channel: true},
                 ctx
               )

      assert text =~
               "in thread [#{root.id}] in ##{ctx.channel.name} (also in ##{ctx.channel.name})"

      [_, id] = Regex.run(~r/replied \[(msg_[^\]]+)\]/, text)
      assert %{sent_to_channel: true, thread_id: thread_id} = Messages.get!(id)
      assert thread_id == root.id
      assert %{in_channel: true} = Canopy.Timeline.for_message(id)

      assert {:ok, text} = call(ThreadReply, %{message_id: root.id, text: "detail"}, ctx)
      refute text =~ "also in"

      assert {:ok, read} = call(MessagesRead, %{thread: root.id}, ctx)

      assert read =~
               "[#{id}] @#{ctx.agent.name} (just now) (in thread #{root.id}, also sent to channel)"
    end

    test "a thread read leaves the channel's read marker alone", ctx do
      root = post(ctx, "root")
      assert {:ok, _} = call(MessagesRead, %{}, ctx)

      # a channel message arrives, then a newer reply in the thread
      channel_news = post(ctx, "news in the channel")

      {:ok, reply} =
        Messages.thread_reply(root.id, {:agent, ctx.other.id}, "newer, in the thread")

      assert {:ok, text} = call(MessagesRead, %{thread: root.id}, ctx)
      assert text =~ reply.id

      # the plain read still returns the channel message the thread read skipped
      assert {:ok, text} = call(MessagesRead, %{}, ctx)
      assert text =~ "[#{channel_news.id}]"
    end

    test "messages_read thread: takes any id in the thread and shows its latest replies", ctx do
      root = post(ctx, "root")

      replies =
        for n <- 1..12 do
          {:ok, reply} = Messages.thread_reply(root.id, {:agent, ctx.other.id}, "reply #{n}")
          reply
        end

      assert {:ok, text} = call(MessagesRead, %{thread: hd(replies).id, limit: 3}, ctx)
      assert text =~ "thread [#{root.id}] in ##{ctx.channel.name}: 12 replies, showing the last 3"
      ids = Regex.scan(~r/^\[(msg_[^\]]+)\]/m, text) |> Enum.map(&List.last/1)
      assert ids == [root.id | replies |> Enum.take(-3) |> Enum.map(& &1.id)]

      assert {:ok, text} = call(MessagesRead, %{thread: "msg_nothing"}, ctx)
      assert text =~ "no thread with message msg_nothing here"
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
