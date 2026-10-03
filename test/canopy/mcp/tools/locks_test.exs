defmodule Canopy.MCP.Tools.LocksTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.{AgentSessions, Locks, Runtime}
  alias Canopy.MCP.Tools.{LockAcquire, LockRelease, LocksList}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    other = agent_fixture(%{name: "fullstack" <> unique_suffix()})
    ctx = scenario(members: [other])
    other_session = session_fixture(%{channel: ctx.channel, agent_id: other.id})
    Map.merge(ctx, %{other: other, other_session: other_session})
  end

  test "acquire takes the lock for the calling session, not a name it was given", ctx do
    assert {:ok, text} = call(LockAcquire, %{name: "tests", reason: "full suite"}, ctx)
    assert text =~ "You hold `tests` now"
    assert text =~ "released when this turn ends"

    assert [%{holder: holder}] = Locks.list(ctx.repository.id)
    assert holder.session_id == ctx.session.id
    assert holder.agent_id == ctx.agent.id
    assert holder.reason == "full suite"
  end

  test "the name defaults to tests", ctx do
    assert {:ok, _} = call(LockAcquire, %{}, ctx)
    assert [%{name: "tests"}] = Locks.list(ctx.repository.id)
  end

  test "an unknown session is refused before anything is taken", ctx do
    assert {:error, text} =
             execute(LockAcquire, %{"canopy_session_id" => "ses_nope", "name" => "tests"})

    assert text =~ "unknown Canopy session"
    assert Locks.list(ctx.repository.id) == []
  end

  test "a Claude Code session's identity comes from its token, never from the params", ctx do
    coder = agent_fixture(%{engine: "claude_code"})
    {:ok, _} = Canopy.Channels.add_agent(ctx.channel, coder)

    claude =
      session_fixture(%{
        channel: ctx.channel,
        agent_id: coder.id,
        engine: "claude_code",
        engine_session_id: Ecto.UUID.generate(),
        mcp_token: AgentSessions.generate_mcp_token()
      })

    # the model stuffs another agent's session id into the params: ignored
    assert {:ok, _} =
             call_as_session(
               LockAcquire,
               %{"name" => "tests", "canopy_session_id" => ctx.session.engine_session_id},
               claude
             )

    assert [%{holder: holder}] = Locks.list(ctx.repository.id)
    assert holder.session_id == claude.id
    assert holder.agent_id == coder.id
  end

  test "queued: says who holds it, for what, the place in line, and to end the turn", ctx do
    {:ok, _} =
      call(LockAcquire, %{name: "tests", reason: "site-shots re-shoot"}, ctx.other_session)

    third = agent_fixture()
    {:ok, _} = Canopy.Channels.add_agent(ctx.channel, third)
    third_session = session_fixture(%{channel: ctx.channel, agent_id: third.id})
    {:ok, _} = call(LockAcquire, %{name: "tests"}, third_session)

    assert {:ok, text} = call(LockAcquire, %{name: "tests", reason: "precommit"}, ctx)

    assert text =~
             "`tests` is held by @#{ctx.other.name} for \"site-shots re-shoot\", <1m. You are 2nd in line after @#{third.name}."

    assert text =~ "End your turn now; Canopy will wake you when it's yours."
    assert text =~ "Don't run anything that needs the lock until then."

    # asking again changes nothing
    assert {:ok, again} = call(LockAcquire, %{name: "tests"}, ctx)
    assert again =~ "You are 2nd in line"
    assert length(hd(Locks.list(ctx.repository.id)).queue) == 2
  end

  test "queued behind a holder blocked on a card: says the holder waits on the user", ctx do
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx.other_session)

    {:ok, _} =
      Canopy.QuestionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.other_session.id,
        opencode_question_id: "que_" <> unique_suffix(),
        questions: [%{"question" => "Which port?", "options" => []}],
        status: "pending"
      })

    assert {:ok, text} = call(LockAcquire, %{name: "tests"}, ctx)
    assert text =~ "is waiting on the user's answer to a card"
  end

  test "re-acquiring a held lock is idempotent", ctx do
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx)
    assert {:ok, text} = call(LockAcquire, %{name: "tests"}, ctx)
    assert text =~ "You already hold `tests`"
    assert [%{queue: []}] = Locks.list(ctx.repository.id)
  end

  test "hold_across_turns says how it is freed", ctx do
    assert {:ok, text} = call(LockAcquire, %{name: "e2e", hold_across_turns: true}, ctx)
    assert text =~ "stays yours until you call canopy_lock_release"
    assert [%{holder: %{hold_across_turns: true}}] = Locks.list(ctx.repository.id)
  end

  test "a bad name is a tool error", ctx do
    assert {:error, text} = call(LockAcquire, %{name: "all the things"}, ctx)
    assert text =~ "lock name"
  end

  test "during a turn the claim belongs to that turn", ctx do
    test_pid = self()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(ctx.repository.id)

    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "run the tests")
    assert_receive :prompted, 2_000

    ref = Runtime.turn_ref(ctx.channel.id, ctx.session.id)
    assert "turn_" <> _ = ref

    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx)
    assert [%{holder: %{turn_ref: ^ref}}] = Locks.list(ctx.repository.id)
  end

  test "release frees a held lock and names who has it now", ctx do
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx)
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx.other_session)

    assert {:ok, text} = call(LockRelease, %{name: "tests", note: "done"}, ctx)
    assert text =~ "Released `tests`; it is @#{ctx.other.name}'s now"
    assert [%{holder: %{session_id: id}}] = Locks.list(ctx.repository.id)
    assert id == ctx.other_session.id
  end

  test "release leaves the line, and says when there is nothing to release", ctx do
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx.other_session)
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx)

    assert {:ok, "Left the line for `tests`."} = call(LockRelease, %{}, ctx)
    assert {:ok, text} = call(LockRelease, %{name: "tests"}, ctx)
    assert text =~ "nothing to release"
  end

  test "release cannot free someone else's lock", ctx do
    {:ok, _} = call(LockAcquire, %{name: "tests"}, ctx.other_session)
    assert {:ok, text} = call(LockRelease, %{name: "tests"}, ctx)
    assert text =~ "nothing to release"
    assert [%{holder: %{session_id: id}}] = Locks.list(ctx.repository.id)
    assert id == ctx.other_session.id
  end

  test "list shows holders, reasons, queues, and which one is you", ctx do
    assert {:ok, empty} = call(LocksList, %{}, ctx)
    assert empty =~ "No locks are held in #{ctx.repository.name}"

    {:ok, _} = call(LockAcquire, %{name: "tests", reason: "precommit"}, ctx.other_session)
    {:ok, _} = call(LockAcquire, %{name: "tests", reason: "e2e"}, ctx)

    assert {:ok, text} = call(LocksList, %{}, ctx)
    assert text =~ "Locks in #{ctx.repository.name}:"

    assert text =~
             "- `tests`: held by @#{ctx.other.name} for <1m (\"precommit\"). Waiting: 1. @#{ctx.agent.name} (you) (\"e2e\")"
  end
end
