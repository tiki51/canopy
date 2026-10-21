defmodule Canopy.MCP.Tools.FallbackMarkerTest do
  # messages an agent writes from its fallback session carry the fallback
  # marker (the UI's "· fallback" chip); from its own session they don't
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Agents, Messages}
  alias Canopy.MCP.Tools.{ChannelCreate, MessageSend, ThreadReply}
  alias Canopy.Messages.Message

  @marker %{"engine" => "codex", "model" => "gpt-5-codex", "from_engine" => "opencode"}

  setup do
    ctx = scenario()
    {:ok, agent} = Agents.update(ctx.agent, %{fallback: "codex:gpt-5-codex"})

    fallback =
      session_fixture(%{
        channel: ctx.channel,
        agent_id: agent.id,
        engine: "codex",
        fallback_of: "opencode"
      })

    Map.merge(ctx, %{agent: agent, fallback: fallback})
  end

  defp last_message(channel_id),
    do:
      Repo.one(
        from m in Message,
          where: m.channel_id == ^channel_id,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: 1
      )

  test "message_send from the fallback session is marked; from the primary it isn't", ctx do
    {:ok, _} = call_as_session(MessageSend, %{text: "on the fallback"}, ctx.fallback)
    assert %{body: "on the fallback", fallback: @marker} = last_message(ctx.channel.id)

    {:ok, _} = call(MessageSend, %{text: "on my own model"}, ctx.session)
    assert %{body: "on my own model", fallback: nil} = last_message(ctx.channel.id)
  end

  test "thread_reply from the fallback session is marked", ctx do
    {:ok, root} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "root")

    {:ok, _} =
      call_as_session(ThreadReply, %{message_id: root.id, text: "in the thread"}, ctx.fallback)

    assert %{fallback: @marker} =
             Repo.one(from m in Message, where: m.body == "in the thread")
  end

  test "channel_create's opening post from the fallback session is marked", ctx do
    {:ok, _} =
      call_as_session(
        ChannelCreate,
        %{name: "fb-" <> unique_suffix(), text: "kick-off"},
        ctx.fallback
      )

    assert %{fallback: @marker} = Repo.one(from m in Message, where: m.body == "kick-off")
  end
end
