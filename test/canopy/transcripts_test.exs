defmodule Canopy.TranscriptsTest do
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{Delegations, Fixtures, Timeline, Transcripts}
  alias Canopy.AgentSessions
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Runtime.Prompts
  alias Canopy.Timeline.Event

  setup :verify_on_exit!

  @dir Path.expand("../support/claude_code_fixtures/transcripts", __DIR__)
  @basic "aaaaaaaa-0000-4000-8000-000000000001"
  @compacted "aaaaaaaa-0000-4000-8000-000000000002"
  @planted "PlantedMcpToken0123456789abcdefXYZ"

  # A stand-in engine with no transcript callback.
  defmodule PlainEngine do
    def name, do: "plain"
  end

  defp claude_fixtures(_ctx) do
    previous = Application.get_env(:canopy, :claude_code, [])
    Application.put_env(:canopy, :claude_code, Keyword.put(previous, :config_dir, @dir))
    on_exit(fn -> Application.put_env(:canopy, :claude_code, previous) end)
    :ok
  end

  defp turn(channel, agent_id, ref_id, at, payload) do
    Repo.insert!(%Event{
      channel_id: channel.id,
      agent_id: agent_id,
      event_type: "agent_turn_completed",
      ref_id: ref_id,
      payload: Map.merge(%{"tools" => 1, "cost" => 0.01, "outcome" => "ok"}, payload),
      inserted_at: at,
      updated_at: at
    })
  end

  describe "list_sessions/2" do
    test "the current session, then reset, earlier and delegated ones, newest first" do
      %{channel: channel, agent: agent, session: current} = Fixtures.scenario()
      helper = Fixtures.agent_fixture()

      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "session_reset",
          ref_id: "as_gone",
          payload: %{"by" => "user", "engine_session_id" => "ses_reset", "engine" => "opencode"}
        })

      # an older line without engine or directory, naming a session nothing else does
      Repo.insert!(%Event{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_started",
        ref_id: "as_older",
        payload: %{"engine_session_id" => "ses_older"},
        inserted_at: ~U[2026-01-01 00:00:00.000000Z],
        updated_at: ~U[2026-01-01 00:00:00.000000Z]
      })

      # a turn in the current session names it too; it stays current
      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_started",
          ref_id: current.id,
          payload: %{"engine_session_id" => current.engine_session_id}
        })

      child =
        Fixtures.session_fixture(%{
          channel: channel,
          agent_id: agent.id,
          parent_session_id: current.id,
          engine_session_id: "ses_child"
        })

      {:ok, delegation} =
        Delegations.create(%{
          channel_id: channel.id,
          task_id: channel.task.id,
          from_agent_id: helper.id,
          to_agent_id: agent.id,
          description: "look into it",
          child_session_id: child.id
        })

      sessions = Transcripts.list_sessions(channel.id, agent.id)

      assert [
               %{kind: :current, engine_session_id: sid, ref_id: ref},
               second,
               third,
               %{kind: :earlier, engine_session_id: "ses_older", ref_id: "as_older"} = older
             ] = sessions

      assert sid == current.engine_session_id
      assert ref == current.id
      assert Enum.sort([second.kind, third.kind]) == [:delegated, :reset]

      delegated = Enum.find(sessions, &(&1.kind == :delegated))
      assert delegated.engine_session_id == "ses_child"
      assert delegated.delegation_id == delegation.id

      reset = Enum.find(sessions, &(&1.kind == :reset))
      assert reset.engine_session_id == "ses_reset"
      assert reset.ref_id == "as_gone"

      # no engine or directory recorded: the agent's engine, the channel's repository
      assert older.engine == agent.engine
      assert older.directory == Canopy.Channels.get!(channel.id).repository.path
    end

    test "nothing yet" do
      %{channel: channel} = Fixtures.scenario()
      other = Fixtures.agent_fixture()
      assert Transcripts.list_sessions(channel.id, other.id) == []
    end
  end

  describe "page/2" do
    setup :claude_fixtures

    setup do
      agent = Fixtures.agent_fixture(%{engine: "claude_code"})
      %{channel: channel} = Fixtures.scenario(members: [agent])

      session =
        Fixtures.session_fixture(%{
          channel: channel,
          agent_id: agent.id,
          engine: "claude_code",
          engine_session_id: @basic,
          mcp_token: @planted
        })

      %{channel: channel, agent: agent, session: session}
    end

    test "redacts Canopy's tokens and key shapes, and drops the user's email", ctx do
      [current] = Transcripts.list_sessions(ctx.channel.id, ctx.agent.id)
      {:ok, page} = Transcripts.page(current)

      text = inspect(page)
      refute text =~ @planted
      refute text =~ "sk-ant-api03"
      refute text =~ "priya.fixture@example.com"

      bash = Enum.find(page.entries, &(&1.kind == :tool and &1.tool.name == "Bash"))
      assert bash.redacted?
      assert bash.tool.output =~ "[canopy session token]"
      refute Enum.find(page.entries, &(&1.kind == :prompt)).redacted?
    end

    test "the settings token is redacted too", ctx do
      {:ok, _} = AgentSessions.delete(ctx.session)
      _ = Canopy.Settings.get()
      Repo.update_all(Canopy.Settings.Setting, set: [mcp_token: @planted])

      session = %{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        engine_session_id: @basic,
        engine: "claude_code",
        directory: nil,
        kind: :reset,
        at: nil,
        ref_id: nil,
        delegation_id: nil
      }

      {:ok, page} = Transcripts.page(session)
      refute inspect(page) =~ @planted
    end

    test "places turn dividers by message id, and older turns by time", ctx do
      new_turn =
        turn(ctx.channel, ctx.agent.id, ctx.session.id, ~U[2026-10-01 10:00:06.000000Z], %{
          "duration_ms" => 5_500,
          "engine_session_id" => @basic,
          "engine_message_ids" => %{"first" => "msg_01A", "last" => "msg_01C"},
          "trigger" => "mention"
        })

      # no ids: placed by its span
      old_turn =
        turn(ctx.channel, ctx.agent.id, ctx.session.id, ~U[2026-10-01 10:05:02.000000Z], %{
          "duration_ms" => 2_500
        })

      [current] = Transcripts.list_sessions(ctx.channel.id, ctx.agent.id)
      {:ok, page} = Transcripts.page(current)

      ids = Enum.map(page.entries, & &1.id)
      assert Enum.at(ids, 0) == "turn-" <> new_turn.id
      assert Enum.at(ids, 1) == "b-prompt-1"

      i = Enum.find_index(ids, &(&1 == "turn-" <> old_turn.id))
      assert Enum.at(ids, i + 1) == "b-prompt-2"

      divider = hd(page.entries)
      assert divider.kind == :turn
      assert divider.turn.trigger == "mention"
      assert DateTime.compare(divider.at, ~U[2026-10-01 10:00:00.500Z]) == :eq

      assert {^current, opts} = Transcripts.locate_turn([current], new_turn)
      assert opts[:around] == {:message_id, "msg_01A"}
      assert {^current, old_opts} = Transcripts.locate_turn([current], old_turn)
      assert {:at, at} = old_opts[:around]
      assert DateTime.compare(at, ~U[2026-10-01 10:04:57.500Z]) == :eq
    end

    test "marks where the system text changed", ctx do
      {:ok, _} = AgentSessions.delete(ctx.session)

      session = %{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        engine_session_id: @compacted,
        engine: "claude_code",
        directory: "/tmp/canopy-repo",
        kind: :reset,
        at: nil,
        ref_id: "as_x",
        delegation_id: nil
      }

      {:ok, page} = Transcripts.page(session)
      i = Enum.find_index(page.entries, &(&1.kind == :system_changed))
      assert Enum.at(page.entries, i - 1).text == "Now add a test."
      assert Enum.at(page.entries, i).text =~ "logged"
    end

    test "an engine that can't read history is unsupported", ctx do
      previous = Application.get_env(:canopy, :engines)

      Application.put_env(:canopy, :engines, Map.put(previous, "plain", PlainEngine))
      on_exit(fn -> Application.put_env(:canopy, :engines, previous) end)

      [current] = Transcripts.list_sessions(ctx.channel.id, ctx.agent.id)
      assert Transcripts.page(%{current | engine: "plain"}) == {:error, :unsupported}
      assert Transcripts.page(%{current | engine: "nope"}) == {:error, :unsupported}
    end
  end

  describe "page/2 on OpenCode" do
    test "marks a message steered into a running turn" do
      %{channel: channel, agent: agent, session: session} = Fixtures.scenario()

      steered = Prompts.steer_preface() <> "You have a new Canopy message in #x from you."

      expect(OC, :messages, fn _dir, sid, [], _opts ->
        assert sid == session.engine_session_id

        {:ok,
         [
           %{
             "info" => %{"id" => "msg_1", "role" => "user", "time" => %{"created" => 1}},
             "parts" => [%{"id" => "p1", "type" => "text", "text" => "First wake"}]
           },
           %{
             "info" => %{"id" => "msg_2", "role" => "user", "time" => %{"created" => 2}},
             "parts" => [%{"id" => "p2", "type" => "text", "text" => steered}]
           }
         ]}
      end)

      [current] = Transcripts.list_sessions(channel.id, agent.id)
      {:ok, page} = Transcripts.page(current)
      assert [%{steered?: false}, %{steered?: true}] = page.entries
    end
  end
end
