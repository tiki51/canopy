defmodule Canopy.MCP.Tools.ChannelCreateFirstMessageTest do
  @moduledoc """
  The first message of a channel an agent creates wakes the agents it
  mentions, under the conditions of real use: the creator is mid-turn in a DM
  the user wrote in.
  """
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.{AgentSessions, Channels, Runtime}
  alias Canopy.MCP.Tools.{ChannelCreate, MessageSend}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    repository = repository_fixture()
    _user = user_fixture()
    creator = agent_fixture(name: "creator-" <> unique_suffix())
    invitee = agent_fixture(name: "invitee-" <> unique_suffix())
    test_pid = self()

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    Canopy.MCP.mark_registered(repository.id)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_new_" <> unique_suffix()}}
    end)

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    %{repository: repository, creator: creator, invitee: invitee}
  end

  defp prompt_text(%{parts: [%{text: text} | _]}), do: text

  test "from the creator's DM, mid-turn: the mentioned invitee is woken with the first message",
       ctx do
    dm_session = creator_mid_turn_in_dm(ctx)

    assert {:ok, text} =
             call(
               ChannelCreate,
               %{
                 name: "from-dm",
                 agents: "@#{ctx.invitee.name}",
                 text: "@#{ctx.invitee.name} please check the retry backoff."
               },
               dm_session
             )

    assert text =~ "posted [msg_"
    channel = Channels.get_by_name(ctx.repository.id, "from-dm")

    assert prompted_with(channel, ctx.invitee, "please check the retry backoff.")
  end

  test "from the creator's DM, mid-turn: a channel created without text, then canopy_message_send to it, wakes the mentioned invitee",
       ctx do
    dm_session = creator_mid_turn_in_dm(ctx)

    assert {:ok, _} =
             call(ChannelCreate, %{name: "then-post", agents: "@#{ctx.invitee.name}"}, dm_session)

    assert {:ok, text} =
             call(
               MessageSend,
               %{
                 channel: "then-post",
                 text: "@#{ctx.invitee.name} please check the retry backoff."
               },
               dm_session
             )

    assert text =~ "posted [msg_"
    channel = Channels.get_by_name(ctx.repository.id, "then-post")

    # the invite woke the invitee at creation, to read the channel; the
    # mention waits in line behind that turn and goes out when it ends
    assert prompted_with(channel, ctx.invitee, "canopy_messages_read")
    finish_turn(AgentSessions.get_root(channel.id, ctx.invitee.id).engine_session_id)
    assert prompted_with(channel, ctx.invitee, "please check the retry backoff.")
  end

  test "canopy_message_send into a channel whose server isn't running wakes the mentioned agent",
       ctx do
    channel =
      channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: ctx.creator.id,
        agent_ids: [ctx.invitee.id]
      })

    session = session_fixture(%{channel: channel, agent_id: ctx.creator.id})
    refute Runtime.Supervisor.whereis(channel.id)

    assert {:ok, _} =
             call(
               MessageSend,
               %{text: "@#{ctx.invitee.name} please check the retry backoff."},
               session
             )

    assert prompted_with(channel, ctx.invitee, "please check the retry backoff.")
  end

  # The user asks in the creator's DM; its turn starts and stays in flight.
  defp creator_mid_turn_in_dm(ctx) do
    {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.creator)
    {:ok, _} = Runtime.ensure_channel(dm.id, start_stream: false)
    {:ok, _} = Runtime.post_user_message(dm.id, "Start a channel with the invitee and fix it.")
    assert_receive {:prompted, dm_sid, _}, 2_000
    dm_session = AgentSessions.get_root(dm.id, ctx.creator.id)
    assert dm_session.engine_session_id == dm_sid
    dm_session
  end

  defp finish_turn(sid) do
    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      Canopy.OpenCode.EventStream.session_topic(sid),
      {:engine_event, %Canopy.Engine.Event{type: :agent_completed, session_id: sid, data: %{}}}
    )
  end

  # Whether `agent` was prompted in `channel` with `text` within 2 s; other
  # prompts (an invite wake, say) are skipped.
  defp prompted_with(channel, agent, text, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:prompted, sid, body} ->
        session = AgentSessions.get_root(channel.id, agent.id)

        if session && session.engine_session_id == sid && prompt_text(body) =~ text,
          do: true,
          else: prompted_with(channel, agent, text, deadline)
    after
      left -> false
    end
  end
end
