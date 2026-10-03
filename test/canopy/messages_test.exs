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
