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

  test "list/2, get/1 and the timeline preload reactions with their reactors", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    {:ok, message} = Messages.post_agent_message(channel.id, agent.id, "Ship it?")
    {:ok, :added} = Canopy.Reactions.add(message.id, {:user, user.id}, "check")

    assert [%{reactions: [%{emoji: "check", user: %{display_name: name}, agent: nil}]}] =
             Messages.list(channel.id)

    assert name == user.display_name
    assert [%{emoji: "check"}] = Messages.get(message.id).reactions

    assert %{message: %{reactions: [%{emoji: "check"}]}} = Timeline.for_message(message.id)
  end

  test "mark_reactions_read/3 rides on the read marker and never moves backwards", ctx do
    %{channel: channel, agent: agent} = ctx
    {:ok, message} = Messages.post_agent_message(channel.id, agent.id, "hello")

    # no read marker yet: nothing to ride on
    :ok = Messages.mark_reactions_read(agent.id, channel.id, "rx_2")
    assert Messages.last_reaction_read(agent.id, channel.id) == nil

    :ok = Messages.mark_read(agent.id, channel.id, message.id)
    :ok = Messages.mark_reactions_read(agent.id, channel.id, "rx_2")
    :ok = Messages.mark_reactions_read(agent.id, channel.id, "rx_1")
    :ok = Messages.mark_reactions_read(agent.id, channel.id, nil)
    assert Messages.last_reaction_read(agent.id, channel.id) == "rx_2"

    :ok = Messages.mark_reactions_read(agent.id, channel.id, "rx_3")
    assert Messages.last_reaction_read(agent.id, channel.id) == "rx_3"
    assert Messages.last_read(agent.id, channel.id) == message.id
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

  describe "post_multi/4 and post_event_multi/3" do
    defp doc!(user, name) do
      {:ok, doc} =
        Canopy.Documents.create(%{filename: name, source: {:binary, name}, user_id: user.id})

      doc
    end

    defp commit_post(channel, attrs, ids, extra) do
      Ecto.Multi.new()
      |> Messages.post_multi(:post, Map.put(attrs, :channel_id, channel.id), ids)
      |> Messages.post_event_multi(:post, extra)
      |> Repo.transaction()
    end

    test "write the message, its attachments in order and its event in one commit",
         %{channel: channel, user: user} do
      a = doc!(user, "a.md")
      b = doc!(user, "b.md")

      assert {:ok, %{{:post, :message} => message, {:post, :event} => event}} =
               commit_post(
                 channel,
                 %{user_id: user.id, body: "", kind: "post"},
                 [b.id, a.id],
                 %{}
               )

      # a blank body is fine with attachments
      assert message.body == ""
      assert Enum.map(Messages.get!(message.id).documents, & &1.id) == [b.id, a.id]
      assert event.ref_id == message.id
      assert event.payload["attachments"] == [b.id, a.id]

      # the extra payload may be built from the changes so far
      assert {:ok, %{{:post, :event} => event}} =
               commit_post(channel, %{user_id: user.id, body: "x", kind: "post"}, [a.id], fn
                 %{{:post, :message} => m} -> %{"seen" => m.id}
               end)

      assert event.payload["seen"] == event.ref_id
    end

    test "the event matches a composer post's, apart from ids and the extra key",
         %{channel: channel, user: user, agent: agent} do
      a = doc!(user, "a.md")
      b = doc!(user, "b.md")
      body = "Fix the login for @#{agent.name}"

      {:ok, posted} =
        Messages.post_user_message(channel.id, user.id, body,
          attachments: [a.id, b.id],
          interrupt: false
        )

      composer = Repo.get_by!(Timeline.Event, ref_id: posted.id)

      {:ok, %{{:post, :event} => built, {:post, :message} => message}} =
        commit_post(
          channel,
          %{user_id: user.id, body: body, kind: "post", interrupt: false},
          [a.id, b.id],
          %{
            "kickoff_run_id" => "pbr_x"
          }
        )

      for field <- [:channel_id, :agent_id, :thread_id, :in_channel, :event_type] do
        assert Map.get(built, field) == Map.get(composer, field), "#{field} differs"
      end

      assert Map.delete(built.payload, "kickoff_run_id") == composer.payload
      assert built.payload["kickoff_run_id"] == "pbr_x"

      # the message itself is built the same way: mentions from the body
      for field <- [:kind, :body, :mentions, :team_mentions, :mentions_user, :interrupt] do
        assert Map.get(message, field) == Map.get(posted, field), "#{field} differs"
      end

      # mentions can be overridden, as for any poster
      {:ok, %{{:post, :message} => quiet}} =
        commit_post(
          channel,
          %{user_id: user.id, body: body, kind: "post", mentions: [], team_mentions: []},
          [a.id],
          %{}
        )

      assert quiet.mentions == []
    end
  end

  describe "@here" do
    setup ctx do
      zed = agent_fixture(%{name: "zed-" <> unique_suffix()})
      amy = agent_fixture(%{name: "amy-" <> unique_suffix()})
      gone = agent_fixture(%{name: "gone-" <> unique_suffix()})

      for agent <- [zed, amy, gone], do: {:ok, _} = Canopy.Channels.add_agent(ctx.channel, agent)
      {:ok, gone} = Canopy.Agents.deactivate(gone)

      %{zed: zed, amy: amy, gone: gone}
    end

    defp ids_by_name(agents), do: agents |> Enum.sort_by(& &1.name) |> Enum.map(& &1.id)

    test "a user's @here reaches every active member, in roster order", ctx do
      %{channel: channel, user: user, agent: owner, zed: zed, amy: amy, gone: gone} = ctx
      reach = ids_by_name([owner, zed, amy])

      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@here standup")

      assert message.mentions == reach

      assert message.team_mentions == [
               %{
                 "name" => "here",
                 "team_id" => nil,
                 "agent_ids" => reach,
                 "reach" => reach,
                 "skipped" => [gone.id]
               }
             ]

      assert Messages.here_mention(message) == List.last(message.team_mentions)
      assert Messages.here_mention(Messages.get!(message.id)) == List.last(message.team_mentions)
    end

    test "an agent's @here leaves out the sender", ctx do
      %{channel: channel, agent: owner, zed: zed, amy: amy} = ctx

      {:ok, message} = Messages.post_agent_message(channel.id, zed.id, "@HERE look")

      assert %{"reach" => reach, "agent_ids" => reach} = Messages.here_mention(message)
      assert reach == ids_by_name([owner, amy])
      assert message.mentions == reach
    end

    test "a direct name or a team claims its agents; @here only reaches them", ctx do
      %{channel: channel, user: user, agent: owner, zed: zed, amy: amy} = ctx
      team = team_fixture([amy], name: "crew-" <> unique_suffix())

      {:ok, message} =
        Messages.post_user_message(channel.id, user.id, "@#{zed.name} @#{team.name} and @Here")

      assert [%{"team_id" => team_id}, here] = message.team_mentions
      assert team_id == team.id
      assert here["reach"] == ids_by_name([owner, zed, amy])
      assert here["agent_ids"] == [owner.id]
      assert message.mentions == [zed.id, amy.id, owner.id]
    end

    test "inside code, or in a turn's final text, @here resolves to nothing", ctx do
      %{channel: channel, user: user, zed: zed} = ctx

      for body <- ["see `@here`", "```\n@here\n```"] do
        {:ok, message} = Messages.post_user_message(channel.id, user.id, body)
        assert message.mentions == []
        assert Messages.here_mention(message) == nil
      end

      {:ok, reply} = Messages.post_agent_reply(channel.id, zed.id, "I told them with @here")
      assert reply.team_mentions == []
      assert reply.mentions == []
    end

    test "a thread reply resolves @here against the whole channel", ctx do
      %{channel: channel, user: user, agent: owner, zed: zed, amy: amy} = ctx
      {:ok, root} = Messages.post_user_message(channel.id, user.id, "root")

      {:ok, reply} = Messages.thread_reply(root.id, {:agent, amy.id}, "@here thoughts?")

      assert Messages.here_mention(reply)["agent_ids"] == ids_by_name([owner, zed])
    end

    test "with no other agents, @here reaches nobody", ctx do
      %{channel: channel, agent: owner} = ctx
      {:ok, _} = Canopy.Channels.remove_agent(channel, ctx.zed)
      {:ok, _} = Canopy.Channels.remove_agent(channel, ctx.amy)

      {:ok, message} = Messages.post_agent_message(channel.id, owner.id, "@here anyone?")

      assert %{"reach" => [], "agent_ids" => []} = Messages.here_mention(message)
      assert message.mentions == []
    end

    test "an agent or team called here never wins", ctx do
      %{channel: channel, user: user, agent: owner, zed: zed, amy: amy} = ctx
      # the changesets reject the name; force one in the table
      Repo.update_all(from(a in Canopy.Agents.Agent, where: a.id == ^zed.id), set: [name: "here"])

      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@here hi")

      assert Messages.here_mention(message)["reach"] ==
               ids_by_name([owner, %{zed | name: "here"}, amy])

      assert Messages.extract_mentions("@here") == []
    end

    test "in a DM, @here reaches the DM's other agents", ctx do
      %{repository: repository, user: user, zed: zed, amy: amy} = ctx
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, [zed, amy])

      {:ok, message} = Messages.post_user_message(dm.id, user.id, "@here")
      assert Messages.here_mention(message)["reach"] == ids_by_name([zed, amy])
    end

    test "resolve_mentions/1 has no channel, so @here is nothing", ctx do
      assert Messages.resolve_mentions("@here @#{ctx.zed.name}") == {[ctx.zed.id], []}
    end

    test "here?/1 finds a live @here only" do
      assert Messages.here?("@here")
      assert Messages.here?("ping @Here now")
      assert Messages.here?("(@HERE)")
      refute Messages.here?("`@here`")
      refute Messages.here?("```\n@here\n```")
      refute Messages.here?("@hereafter")
      refute Messages.here?("me@here")
      refute Messages.here?(nil)
    end

    test "here_audience/1 splits members into active and skipped, by name", ctx do
      %{channel: channel, agent: owner, zed: zed, amy: amy, gone: gone} = ctx

      {active, skipped} = Messages.here_audience(channel.id)
      assert Enum.map(active, & &1.id) == ids_by_name([owner, zed, amy])
      assert Enum.map(skipped, & &1.id) == [gone.id]
    end

    test "here_mention/1 is nil without an entry", ctx do
      {:ok, message} =
        Messages.post_user_message(ctx.channel.id, ctx.user.id, "@#{ctx.zed.name}")

      assert Messages.here_mention(message) == nil
    end
  end
end
