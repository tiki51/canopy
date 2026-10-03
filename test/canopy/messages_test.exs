defmodule Canopy.MessagesTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Messages
  alias Canopy.Messages.Message
  alias Canopy.Timeline

  setup do
    scenario()
  end

  test "the database rejects zero or two senders", %{channel: channel, agent: agent, user: user} do
    assert_raise Ecto.ConstraintError, ~r/messages_sender_check/, fn ->
      Repo.insert(%Message{channel_id: channel.id, body: "nobody"})
    end

    assert_raise Ecto.ConstraintError, ~r/messages_sender_check/, fn ->
      Repo.insert(%Message{
        channel_id: channel.id,
        body: "both",
        agent_id: agent.id,
        user_id: user.id
      })
    end

    changeset =
      Message.changeset(%Message{}, %{
        channel_id: channel.id,
        body: "both",
        agent_id: agent.id,
        user_id: user.id
      })

    assert %{user_id: ["exactly one of agent_id or user_id must be set"]} = errors_on(changeset)
  end

  test "posting writes the message and its timeline event and broadcasts", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    Timeline.subscribe(channel.id)

    assert {:ok, message} =
             Messages.post_user_message(channel.id, user.id, "hello @#{agent.name}")

    assert message.kind == "post"
    assert message.user.id == user.id
    assert message.mentions == [agent.id]

    assert_receive {:timeline, %Timeline.Event{event_type: "message", ref_id: ref_id} = event}
    assert ref_id == message.id
    assert event.message.id == message.id
    assert event.message.user.id == user.id

    assert {:ok, reply} = Messages.post_agent_reply(channel.id, agent.id, "on it", [])
    assert reply.kind == "reply"
    assert reply.agent.id == agent.id

    assert {:ok, post} =
             Messages.post_agent_message(channel.id, agent.id, "done", opencode_message_id: "m1")

    assert post.opencode_message_id == "m1"

    events = Timeline.list(channel.id)
    assert Enum.map(events, & &1.ref_id) == [message.id, reply.id, post.id]
  end

  test "a user's message interrupts as the setting says, unless told; agents' never do",
       %{channel: channel, agent: agent, user: user} do
    {:ok, off} = Messages.post_user_message(channel.id, user.id, "hi")
    refute off.interrupt

    {:ok, _} = Canopy.Settings.update(%{interrupt_on_mention: true})
    {:ok, on} = Messages.post_user_message(channel.id, user.id, "hi again")
    assert on.interrupt
    assert Timeline.for_message(on.id).payload["interrupt"] == true

    {:ok, opted_out} = Messages.post_user_message(channel.id, user.id, "later", interrupt: false)
    refute opted_out.interrupt

    {:ok, reply} = Messages.thread_reply(on.id, {:user, user.id}, "in the thread")
    assert reply.interrupt

    {:ok, from_agent} = Messages.post_agent_message(channel.id, agent.id, "hi", interrupt: true)
    refute from_agent.interrupt

    {:ok, note} = Messages.post_user_note(channel.id, user.id, "a note")
    refute note.interrupt
  end

  test "an invalid message writes no timeline row", %{channel: channel, user: user} do
    assert {:error, changeset} = Messages.post_user_message(channel.id, user.id, "   ")
    assert %{body: [_ | _]} = errors_on(changeset)
    assert Timeline.list(channel.id) == []
  end

  test "thread_reply/4 attaches to the thread root", %{channel: channel, agent: agent, user: user} do
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")
    {:ok, r1} = Messages.thread_reply(root.id, {:agent, agent.id}, "first")
    {:ok, r2} = Messages.thread_reply(r1.id, {:user, user.id}, "second")

    assert r1.thread_id == root.id
    assert r2.thread_id == root.id
    assert r2.kind == "thread_reply"

    assert Enum.map(Messages.list(channel.id, thread: root.id), & &1.id) == [
             root.id,
             r1.id,
             r2.id
           ]
  end

  test "list_thread/2 returns the root and the latest replies, from any id in the thread",
       %{channel: channel, agent: agent, user: user} do
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")

    replies =
      for n <- 1..12 do
        {:ok, reply} = Messages.thread_reply(root.id, {:agent, agent.id}, "reply #{n}")
        reply
      end

    # the newest replies survive the limit, oldest first, after the root
    expected = [root.id | replies |> Enum.take(-5) |> Enum.map(& &1.id)]
    assert Enum.map(Messages.list_thread(root.id, limit: 5), & &1.id) == expected
    assert Enum.map(Messages.list_thread(hd(replies).id, limit: 5), & &1.id) == expected

    assert Enum.map(Messages.list(channel.id, thread: hd(replies).id, limit: 5), & &1.id) ==
             expected

    assert Messages.list_thread("msg_missing") == []
    other = channel_fixture(%{repository_id: channel.repository_id})
    assert Messages.list(other.id, thread: root.id) == []
  end

  test "thread_summaries/1 counts replies and lists participants, newest first, capped",
       %{channel: channel, agent: agent, user: user} do
    a2 = agent_fixture()
    a3 = agent_fixture()
    a4 = agent_fixture()
    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
    {:ok, lonely} = Messages.post_agent_message(channel.id, agent.id, "no replies")

    {:ok, _} = Messages.thread_reply(root.id, {:agent, a2.id}, "one")
    {:ok, _} = Messages.thread_reply(root.id, {:user, user.id}, "two")
    {:ok, _} = Messages.thread_reply(root.id, {:agent, a3.id}, "three")
    {:ok, _} = Messages.thread_reply(root.id, {:agent, a2.id}, "four")
    {:ok, last} = Messages.thread_reply(root.id, {:agent, a4.id}, "five")

    root_id = root.id
    assert %{^root_id => summary} = summaries = Messages.thread_summaries([root.id, lonely.id])
    refute Map.has_key?(summaries, lonely.id)
    assert summary.count == 5
    assert summary.last.id == last.id
    assert summary.last_reply_at == last.inserted_at

    # distinct senders, newest first, then the root's author; four at most
    assert Enum.map(summary.participants, &(&1.agent_id || {:user, &1.user_id})) ==
             [a4.id, a2.id, a3.id, {:user, user.id}]

    assert hd(summary.participants).agent.name == a4.name
    assert Messages.thread_summaries([]) == %{}
  end

  test "thread_last_agent/2 names the newest agent in a thread, before a message, among some",
       %{channel: channel, agent: agent, user: user} do
    other = agent_fixture()
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")
    assert Messages.thread_last_agent(root.id) == nil

    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "first")
    {:ok, mine} = Messages.thread_reply(root.id, {:user, user.id}, "mine")
    {:ok, _} = Messages.thread_reply(root.id, {:agent, other.id}, "second")

    assert Messages.thread_last_agent(root.id) == other.id
    assert Messages.thread_last_agent(root.id, except: other.id) == agent.id
    # replies after the routed message do not count
    assert Messages.thread_last_agent(root.id, before: mine.id) == agent.id
    assert Messages.thread_last_agent(root.id, among: [agent.id]) == agent.id
    assert Messages.thread_last_agent(root.id, among: []) == nil
  end

  test "a thread reply stays out of the channel feed unless it is also sent to the channel",
       %{channel: channel, agent: agent, user: user} do
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")
    {:ok, quiet} = Messages.thread_reply(root.id, {:agent, agent.id}, "in the thread")
    {:ok, loud} = Messages.thread_reply(root.id, {:agent, agent.id}, "for all", to_channel: true)
    {:ok, closing} = Messages.thread_reply(root.id, {:agent, agent.id}, "done", kind: "reply")

    refute quiet.sent_to_channel
    assert loud.sent_to_channel
    assert closing.kind == "reply"

    assert %{thread_id: nil, in_channel: true} = Timeline.for_message(root.id)
    assert %{thread_id: thread_id, in_channel: false} = Timeline.for_message(quiet.id)
    assert thread_id == root.id
    assert %{thread_id: ^thread_id, in_channel: true} = Timeline.for_message(loud.id)
    assert %{in_channel: false} = Timeline.for_message(closing.id)
  end

  test "list/2 supports limit, before, and around", %{channel: channel, user: user} do
    messages =
      for i <- 1..12 do
        {:ok, m} = Messages.post_user_message(channel.id, user.id, "message #{i}")
        m
      end

    ids = Enum.map(messages, & &1.id)

    assert Enum.map(Messages.list(channel.id), & &1.id) == ids
    assert Enum.map(Messages.list(channel.id, limit: 3), & &1.id) == Enum.slice(ids, 9, 3)

    anchor = Enum.at(ids, 6)

    assert Enum.map(Messages.list(channel.id, before: anchor, limit: 4), & &1.id) ==
             Enum.slice(ids, 2, 4)

    around = Messages.list(channel.id, around: anchor, limit: 5)
    assert Enum.map(around, & &1.id) == Enum.slice(ids, 4, 5)
    assert anchor in Enum.map(around, & &1.id)

    assert Enum.map(Messages.list(channel.id, around: List.first(ids), limit: 4), & &1.id) ==
             Enum.slice(ids, 0, 2)
  end

  test "search/3 matches quoted phrases and prefixes with snippets", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    other = channel_fixture()

    {:ok, m1} =
      Messages.post_agent_message(
        channel.id,
        agent.id,
        "Duplicate invoices come from two independent retry paths in PaymentWorker"
      )

    {:ok, m2} =
      Messages.post_user_message(
        channel.id,
        user.id,
        "Should the uniqueness guarantee live in the database layer?"
      )

    {:ok, _elsewhere} =
      Messages.post_agent_message(other.id, other.owner_agent_id, "retry paths elsewhere")

    assert [%{message: hit, snippet: snippet, rank: rank}] =
             Messages.search(channel.id, ~s("retry paths"))

    assert hit.id == m1.id
    assert hit.agent.id == agent.id
    assert snippet =~ "**retry paths**"
    assert is_float(rank)

    assert [] = Messages.search(channel.id, ~s("paths retry"))

    assert [%{message: %{id: id}, snippet: snippet}] = Messages.search(channel.id, "uniq*")
    assert id == m2.id
    assert snippet =~ "**uniqueness**"

    # Operators and punctuation are literal terms or dropped, never syntax.
    assert [] = Messages.search(channel.id, "database AND OR NOT")
    assert [%{message: %{id: id}}] = Messages.search(channel.id, "database ( \" ) -- ;")
    assert id == m2.id

    assert [] = Messages.search(channel.id, "nothing-here")
    assert [] = Messages.search(channel.id, "   ")

    {:ok, _} = Repo.delete(m1)
    assert [] = Messages.search(channel.id, "PaymentWorker")
  end

  test "to_fts_query/1 quotes every term" do
    assert Messages.to_fts_query(~s(retr* "database layer" uniq)) ==
             ~s("retr"* "database layer" "uniq")

    assert Messages.to_fts_query(~s("quoted prefix"*)) == ~s("quoted prefix"*)
    assert Messages.to_fts_query(~s(a"b)) == ~s("ab")
    assert Messages.to_fts_query(~s|( ) " -- *|) == ""
    assert Messages.to_fts_query("") == ""
  end

  test "extract_mentions/1 resolves known names in order", %{agent: agent} do
    second = agent_fixture(%{name: "reviewer"})

    assert Messages.extract_mentions("@reviewer then @#{agent.name} and @nobody, @reviewer") ==
             [second.id, agent.id]

    assert Messages.extract_mentions("mail me at me@example.com") == []
    assert Messages.extract_mentions("no mentions") == []
  end

  test "extract_mentions/1 skips names inside inline code and fenced blocks", ctx do
    %{agent: agent, channel: channel, user: user} = ctx
    reviewer = agent_fixture(%{name: "reviewer"})

    assert Messages.extract_mentions("run `@reviewer` past @#{agent.name}") == [agent.id]
    assert Messages.extract_mentions("```\n@reviewer\n```\n@#{agent.name}") == [agent.id]
    assert Messages.extract_mentions("~~~ sh\necho @reviewer\n") == []
    # an unmatched backtick is literal, so the mention still wakes
    assert Messages.extract_mentions("a ` stray @reviewer") == [reviewer.id]

    {:ok, message} = Messages.post_user_message(channel.id, user.id, "see `@reviewer`")
    assert message.mentions == []
  end

  describe "team mentions" do
    setup do
      backend = agent_fixture(%{name: "backend-" <> unique_suffix()})
      frontend = agent_fixture(%{name: "frontend-" <> unique_suffix()})
      tester = agent_fixture(%{name: "tester-" <> unique_suffix()})
      team = team_fixture([tester, frontend, backend], name: "crew-" <> unique_suffix())
      %{backend: backend, frontend: frontend, tester: tester, team: team}
    end

    test "a team expands in place to its active members, by name", ctx do
      %{backend: b, frontend: f, tester: t, team: team, agent: agent} = ctx
      sorted = [b, f, t] |> Enum.sort_by(& &1.name) |> Enum.map(& &1.id)

      assert Messages.extract_mentions("@#{agent.name} then @#{team.name}") == [agent.id | sorted]

      # de-duplicated against a member also named directly, who is charged on its own
      {ids, [entry]} = Messages.resolve_mentions("@#{team.name} and @#{b.name}")
      assert ids == sorted

      assert entry == %{
               "team_id" => team.id,
               "name" => team.name,
               "agent_ids" => sorted -- [b.id]
             }

      {:ok, _} = Canopy.Agents.deactivate(t)
      assert Messages.extract_mentions("@#{team.name}") == sorted -- [t.id]
    end

    test "an agent wins a name collision", ctx do
      # a collision cannot be created through the changesets; force one in the table
      Repo.update_all(Canopy.Teams.Team, set: [name: ctx.backend.name])

      assert Messages.resolve_mentions("@#{ctx.backend.name}") == {[ctx.backend.id], []}
    end

    test "stored mentions keep the team's members at the time of posting", ctx do
      %{channel: channel, user: user, team: team} = ctx

      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@#{team.name} look")
      before = message.mentions
      assert length(before) == 3
      assert [%{"team_id" => team_id}] = message.team_mentions
      assert team_id == team.id

      {:ok, _} =
        Canopy.Teams.update(team, %{agent_ids: [ctx.backend.id], lead_agent_id: ctx.backend.id})

      reloaded = Messages.get!(message.id)
      assert reloaded.mentions == before
      assert [%{"agent_ids" => ids}] = reloaded.team_mentions
      assert length(ids) == 3
    end
  end
end
