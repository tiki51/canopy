defmodule Canopy.Runtime.ChannelServerBriefTest do
  @moduledoc """
  The channel brief in the system text: byte-identical while it is unchanged
  (so it caches), current after an edit (the server reloads the channel on
  `brief_updated`), and a one-time change note for sessions that had a turn
  before the edit.
  """
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.{AgentSessions, Channels, Fixtures, Runtime, Timeline}
  alias Canopy.Engine.Event
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.OpenCode.EventStream

  setup :set_mox_global
  setup :verify_on_exit!

  describe "OpenCode" do
    setup do
      reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
      scenario = Fixtures.scenario(members: [reviewer])
      Timeline.subscribe(scenario.channel.id)

      stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

      Canopy.MCP.mark_registered(scenario.repository.id)

      test_pid = self()

      stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
        send(test_pid, {:prompted, sid, body})
        {:ok, ""}
      end)

      {:ok, pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
      {:ok, Map.merge(scenario, %{reviewer: reviewer, pid: pid})}
    end

    defp turn(ctx, text) do
      sid = ctx.session.engine_session_id
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, text)
      assert_receive {:prompted, ^sid, body}, 2_000

      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        EventStream.session_topic(sid),
        {:engine_event,
         %Event{type: :agent_completed, session_id: sid, data: %{}, raw_type: "test"}}
      )

      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
      body
    end

    defp wake_text(%{parts: [%{text: text} | _]}), do: text

    test "two prompts with no edit between them send byte-identical system text", ctx do
      {:ok, _} = Channels.set_brief(ctx.channel, "Goal: stop double charges.", "user")

      first = turn(ctx, "first")
      second = turn(ctx, "second")

      assert first.system =~ "Channel brief for ##{ctx.channel.name}"
      assert first.system =~ "Goal: stop double charges."
      assert first.system == second.system
    end

    test "after an edit the next prompt carries the new brief; the edit wakes nobody", ctx do
      first = turn(ctx, "first")
      refute first.system =~ "Channel brief for"

      {:ok, _} = Channels.set_brief(ctx.channel, "Don't touch vendor/.", "user")
      assert_receive {:timeline, %{event_type: "brief_updated"}}, 1_000

      # the server has reloaded its channel; nobody was woken by the edit
      assert :sys.get_state(ctx.pid).channel.brief == "Don't touch vendor/."
      refute_receive {:prompted, _, _}, 300

      second = turn(ctx, "second")
      assert second.system =~ "Don't touch vendor/."
      refute second.system == first.system
    end

    test "a session that had a turn before the edit is told once; the next prompt is not",
         ctx do
      first = turn(ctx, "first")
      refute wake_text(first) =~ "The channel brief changed"
      assert %{brief_seen_at: %DateTime{}} = AgentSessions.get!(ctx.session.id)

      {:ok, _} = Channels.set_brief(ctx.channel, "Goal: refunds too.", ctx.agent.id)
      assert_receive {:timeline, %{event_type: "brief_updated"}}, 1_000

      second = turn(ctx, "second")

      assert wake_text(second) =~
               "The channel brief changed since your last turn (by @#{ctx.agent.name})."

      third = turn(ctx, "third")
      refute wake_text(third) =~ "The channel brief changed"
      # the system text is back to caching
      assert third.system == second.system
    end

    test "a fresh session gets the brief in its first system text and no change note", ctx do
      {:ok, _} = Channels.set_brief(ctx.channel, "Goal: stop double charges.", "user")

      expect(OC, :create_session, fn _dir, _body, _opts -> {:ok, %{"id" => "ses_fresh"}} end)
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.reviewer.name} have a look")

      assert_receive {:prompted, "ses_fresh", body}, 2_000
      assert body.system =~ "Goal: stop double charges."
      refute wake_text(body) =~ "The channel brief changed"
    end
  end

  describe "Claude Code" do
    @fake Path.expand("../../support/fake_claude.sh", __DIR__)

    setup do
      dir =
        Path.join([File.cwd!(), "_build", "test", "tmp", "brief-" <> Fixtures.unique_suffix()])

      File.mkdir_p!(dir)
      script = Path.join(dir, "script.jsonl")

      File.write!(
        script,
        Enum.map_join(
          [
            %{type: "system", subtype: "init", session_id: "SESSION_ID", mcp_servers: []},
            %{
              type: "result",
              subtype: "success",
              is_error: false,
              num_turns: 1,
              result: "Done.",
              session_id: "SESSION_ID",
              total_cost_usd: 0.001,
              usage: %{input_tokens: 5, output_tokens: 2}
            }
          ],
          "\n",
          &JSON.encode!/1
        ) <> "\n"
      )

      previous = Application.get_env(:canopy, :claude_code)

      Application.put_env(:canopy, :claude_code,
        binary: @fake,
        env: [{"FAKE_CLAUDE_SCRIPT", script}]
      )

      on_exit(fn ->
        Application.put_env(:canopy, :claude_code, previous)
        File.rm_rf!(dir)
      end)

      agent = Fixtures.agent_fixture(%{engine: "claude_code"})
      repository = Fixtures.repository_fixture()

      channel =
        Fixtures.channel_fixture(%{repository_id: repository.id, owner_agent_id: agent.id})

      Timeline.subscribe(channel.id)
      {:ok, _} = Runtime.ensure_channel(channel.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(channel.id) end)
      %{channel: channel, agent: agent}
    end

    # The system text the turn was started with: the file passed as
    # --append-system-prompt-file, read once the turn is over.
    defp claude_turn(%{channel: channel, agent: agent}, text) do
      {:ok, _} = Runtime.post_user_message(channel.id, text)
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000
      session = AgentSessions.get_root(channel.id, agent.id)

      File.read!(
        Path.join([System.tmp_dir!(), "canopy-claude", session.engine_session_id, "system.md"])
      )
    end

    test "each turn's system file is byte-identical until the brief changes", ctx do
      {:ok, _} = Channels.set_brief(ctx.channel, "Goal: stop double charges.", "user")

      first = claude_turn(ctx, "first")
      second = claude_turn(ctx, "second")
      assert first =~ "Goal: stop double charges."
      assert first == second

      {:ok, _} = Channels.set_brief(ctx.channel, "Goal: refunds too.", "user")
      assert_receive {:timeline, %{event_type: "brief_updated"}}, 1_000

      third = claude_turn(ctx, "third")
      assert third =~ "Goal: refunds too."
      refute third =~ "Goal: stop double charges."
    end
  end
end
