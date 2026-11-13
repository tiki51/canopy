defmodule Canopy.MCP.Tools.ChannelInviteWakeTest do
  @moduledoc "Agents brought into a channel by another agent are woken there."
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.Channels
  alias Canopy.MCP.Tools.{ChannelAddMembers, ChannelCreate}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    invitee = agent_fixture(name: "invitee-" <> unique_suffix())
    ctx = scenario()
    test_pid = self()

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(ctx.repository.id)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_inv_" <> unique_suffix()}}
    end)

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    Map.put(ctx, :invitee, invitee)
  end

  defp prompt_text(%{parts: [%{text: text} | _]}), do: text

  test "channel_create wakes an invited agent the first message mentions, with that message",
       ctx do
    assert {:ok, _} =
             call(
               ChannelCreate,
               %{
                 name: "kickoff",
                 agents: "@#{ctx.invitee.name}",
                 text: "@#{ctx.invitee.name} please check the retry backoff."
               },
               ctx
             )

    assert_receive {:prompted, sid, body}, 2_000
    channel = Channels.get_by_name(ctx.repository.id, "kickoff")
    assert Canopy.AgentSessions.get_root(channel.id, ctx.invitee.id).engine_session_id == sid
    assert prompt_text(body) =~ "please check the retry backoff."
  end

  describe "on Claude Code" do
    @fake Path.expand("../../../support/fake_claude.sh", __DIR__)

    setup ctx do
      dir = Path.join([File.cwd!(), "_build", "test", "tmp", "invite-" <> unique_suffix()])
      File.mkdir_p!(dir)
      script = Path.join(dir, "script.jsonl")
      log = Path.join(dir, "claude.log")

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
        default_config_dir: previous[:default_config_dir],
        binary: @fake,
        env: [{"FAKE_CLAUDE_SCRIPT", script}, {"FAKE_CLAUDE_LOG", log}]
      )

      on_exit(fn ->
        Application.put_env(:canopy, :claude_code, previous)
        File.rm_rf!(dir)
      end)

      # call_as_session doesn't register the shared teardown; this runs first
      on_exit(&Canopy.PlaybookHelpers.stop_channels/0)

      creator = agent_fixture(name: "creator-" <> unique_suffix(), engine: "claude_code")
      invitee = agent_fixture(name: "invitee-" <> unique_suffix(), engine: "claude_code")
      home = channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: creator.id})
      session = session_fixture(%{channel: home, agent_id: creator.id, engine: "claude_code"})
      %{session: session, invitee: invitee, log: log}
    end

    test "channel_create wakes the mentioned invitee with the first message", ctx do
      assert {:ok, text} =
               call_as_session(
                 ChannelCreate,
                 %{
                   name: "kickoff-cc",
                   agents: "@#{ctx.invitee.name}",
                   text: "@#{ctx.invitee.name} please check the retry backoff."
                 },
                 ctx.session
               )

      [_, id] = Regex.run(~r/\[(ch_[^\]]+)\]/, text)
      Canopy.Timeline.subscribe(id)
      invitee_id = ctx.invitee.id

      assert_receive {:timeline, %{event_type: "agent_turn_completed", agent_id: ^invitee_id}},
                     10_000

      assert File.read!(ctx.log) =~ "please check the retry backoff."
    end
  end

  test "channel_add_members wakes the added agent, first telling it to read the channel", ctx do
    assert {:ok, _} = call(ChannelAddMembers, %{agents: "@#{ctx.invitee.name}"}, ctx)

    assert_receive {:prompted, _sid, body}, 2_000
    text = prompt_text(body)
    assert text =~ "##{ctx.channel.name}"
    assert text =~ "canopy_messages_read"
  end

  test "an inactive invitee is not woken, as @here skips it", ctx do
    # no tool call here to register the shared teardown
    on_exit(&Canopy.PlaybookHelpers.stop_channels/0)
    retired = agent_fixture(name: "retired-" <> unique_suffix(), active: false)
    {:ok, _} = Channels.add_agent(ctx.channel, ctx.invitee)
    {:ok, _} = Channels.add_agent(ctx.channel, retired)
    Canopy.Runtime.wake_invited(ctx.channel.id, [retired, ctx.invitee], ctx.agent)

    assert_receive {:prompted, sid, _body}, 2_000
    assert Canopy.AgentSessions.get_root(ctx.channel.id, ctx.invitee.id).engine_session_id == sid
    refute Canopy.AgentSessions.get_root(ctx.channel.id, retired.id)
    refute_receive {:prompted, _, _}, 200
  end

  test "channel_create wakes each invited agent, first telling it to read the channel", ctx do
    assert {:ok, _} =
             call(ChannelCreate, %{name: "quiet-start", agents: "@#{ctx.invitee.name}"}, ctx)

    assert_receive {:prompted, _sid, body}, 2_000
    text = prompt_text(body)
    assert text =~ "#quiet-start"
    assert text =~ "canopy_messages_read"
  end
end
