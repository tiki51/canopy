defmodule Canopy.MCP.Tools.ChannelsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.{Channels, Handoffs, Messages}
  alias Canopy.MCP.Tools.{AgentsList, ChannelGet, ChannelsList}

  setup do
    other = agent_fixture(name: "reviewer-" <> unique_suffix())
    ctx = scenario(members: [other])

    outsider_channel =
      channel_fixture(%{
        repository_id: ctx.repository.id,
        owner_agent_id: other.id,
        name: "private-" <> unique_suffix()
      })

    Map.merge(ctx, %{other: other, outsider_channel: outsider_channel})
  end

  describe "channels_list" do
    test "lists only channels the caller belongs to and marks the current one", ctx do
      assert {:ok, text} = call(ChannelsList, %{}, ctx)
      assert text =~ "##{ctx.channel.name} [#{ctx.channel.id}] (current)"
      assert text =~ "owner @#{ctx.agent.name}"
      assert text =~ "task open — #{ctx.task.title}"
      refute text =~ ctx.outsider_channel.name
    end
  end

  describe "channel_get" do
    test "returns the state of the caller's channel by default", ctx do
      {:ok, m1} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "first finding")
      {:ok, m2} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "thanks")

      assert {:ok, text} = call(ChannelGet, %{}, ctx)
      assert text =~ "##{ctx.channel.name} [#{ctx.channel.id}] open in #{ctx.repository.name}"
      assert text =~ "branch main"
      assert text =~ "Owner: @#{ctx.agent.name}"
      assert text =~ "Task: [#{ctx.task.id}] open — #{ctx.task.title} (owner @#{ctx.agent.name})"
      assert text =~ "Members: @#{ctx.agent.name}, @#{ctx.other.name}"
      assert text =~ "Last handoff: none"
      assert text =~ "[#{m1.id}] @#{ctx.agent.name}"
      assert text =~ "[#{m2.id}] #{ctx.user.display_name}"
    end

    test "accepts a channel name or id the caller is a member of", ctx do
      assert {:ok, by_name} = call(ChannelGet, %{channel: "#" <> ctx.channel.name}, ctx)
      assert {:ok, by_id} = call(ChannelGet, %{channel: ctx.channel.id}, ctx)
      assert by_name == by_id
    end

    test "refuses channels the caller is not a member of", ctx do
      assert {:error, message} = call(ChannelGet, %{channel: ctx.outsider_channel.name}, ctx)
      assert message == "not a member of ##{ctx.outsider_channel.name}"

      assert {:error, message} = call(ChannelGet, %{channel: ctx.outsider_channel.id}, ctx)
      assert message == "not a member of ##{ctx.outsider_channel.name}"

      assert {:error, "unknown channel #nope"} = call(ChannelGet, %{channel: "nope"}, ctx)
    end

    test "shows the pending handoff", ctx do
      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: ctx.channel.id,
          task_id: ctx.task.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: ctx.other.id,
          summary: "Retry logic isolated",
          packet: %{}
        })

      assert {:ok, text} = call(ChannelGet, %{}, ctx)

      assert text =~
               "Pending handoff: [#{handoff.id}] @#{ctx.agent.name} → @#{ctx.other.name}: Retry logic isolated"

      {:ok, _} = Handoffs.accept(handoff)
      assert {:ok, text} = call(ChannelGet, %{}, ctx)
      assert text =~ "Owner: @#{ctx.other.name}"
      assert text =~ "Last handoff: [#{handoff.id}] accepted"
    end
  end

  describe "agents_list" do
    test "lists agents with roles and marks channel members", ctx do
      stranger = agent_fixture(name: "stranger-" <> unique_suffix(), role: "Watches from afar")
      {:ok, _} = Canopy.Agents.deactivate(stranger)
      assert Channels.member?(ctx.channel, ctx.other)

      assert {:ok, text} = call(AgentsList, %{}, ctx)
      assert text =~ "@#{ctx.agent.name} (you, in ##{ctx.channel.name}): Test agent"
      assert text =~ "@#{ctx.other.name} (in ##{ctx.channel.name}): Test agent"
      assert text =~ "@#{stranger.name} (inactive): Watches from afar"
    end
  end
end
