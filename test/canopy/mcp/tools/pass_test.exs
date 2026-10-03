defmodule Canopy.MCP.Tools.PassTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.Engine.Event
  alias Canopy.MCP.Tools.{Pass, React}
  alias Canopy.Messages
  alias Canopy.OpenCode.EventStream
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Runtime

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ctx = scenario()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    ctx
  end

  test "without a turn in flight it is a no-op with a clear answer", ctx do
    assert {:ok, text} = call(Pass, %{reason: "nothing to add"}, ctx)
    assert text =~ "no Canopy turn is in flight"
  end

  test "during a turn it marks the turn passed", ctx do
    test_pid = self()

    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, _} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "ok")
    assert_receive :prompted, 2_000

    assert {:ok, text} = call(Pass, %{reason: "acknowledgement only"}, ctx)
    assert text =~ "nothing will be posted"
  end

  describe "with canopy_react" do
    setup ctx do
      other = agent_fixture()
      {:ok, _} = Canopy.Channels.add_agent(ctx.channel, other)
      {:ok, theirs} = Messages.post_agent_message(ctx.channel.id, other.id, "Merged the fix.")
      test_pid = self()

      stub(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
        send(test_pid, :prompted)
        {:ok, ""}
      end)

      # started after the post above, so that post woke nobody
      {:ok, _} = Runtime.ensure_channel(ctx.channel.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
      Canopy.Timeline.subscribe(ctx.channel.id)
      Map.put(ctx, :theirs, theirs)
    end

    defp turn(ctx, fun) do
      sid = ctx.session.engine_session_id
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.agent.name} did it merge?")
      assert_receive :prompted, 2_000

      fun.()
      emit(sid, :text_done, %{message_id: "m", part_id: "p1", text: "Yes, merged and green."})
      emit(sid, :agent_completed, %{})
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
    end

    defp emit(sid, type, data) do
      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        EventStream.session_topic(sid),
        {:engine_event, %Event{type: type, session_id: sid, data: data, raw_type: "test"}}
      )
    end

    test "a reaction during a turn leaves its final text to be posted", ctx do
      turn(ctx, fn ->
        assert {:ok, _} = call(React, %{message: ctx.theirs.id, emoji: "eyes"}, ctx)
      end)

      # the turn names its reply before posting it
      assert_receive {:timeline, %{event_type: "message", message: %{kind: "reply", body: body}}},
                     2_000

      assert body == "Yes, merged and green."
    end

    test "react then pass posts nothing", ctx do
      turn(ctx, fn ->
        assert {:ok, _} = call(React, %{message: ctx.theirs.id, emoji: "check"}, ctx)
        assert {:ok, text} = call(Pass, %{reason: "acknowledged"}, ctx)
        assert text =~ "nothing will be posted"
      end)

      refute_receive {:timeline, %{event_type: "message", message: %{kind: "reply"}}}, 300
      assert [%{emoji: "check"}] = Messages.get!(ctx.theirs.id).reactions
    end
  end
end
