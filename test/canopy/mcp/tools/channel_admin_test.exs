defmodule Canopy.MCP.Tools.ChannelAdminTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.{Channels, Messages, Runtime, Timeline}
  alias Canopy.MCP.Tools.{ChannelAddMembers, ChannelCreate, ChannelRemoveMembers}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = agent_fixture(name: "reviewer-" <> unique_suffix())
    tester = agent_fixture(name: "tester-" <> unique_suffix())
    ctx = scenario(members: [reviewer])
    reviewer_session = session_fixture(%{channel: ctx.channel, agent_id: reviewer.id})
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    on_exit(fn -> Enum.each(Channels.list(), &Runtime.stop_channel(&1.id)) end)
    Map.merge(ctx, %{reviewer: reviewer, reviewer_session: reviewer_session, tester: tester})
  end

  describe "channel_create" do
    test "an agent can set a spend limit at creation, not change it later", ctx do
      assert {:ok, text} = call(ChannelCreate, %{name: "budgeted", spend_limit: 3}, ctx)
      assert text =~ "spend limit $3.00"
      channel = Channels.get_by_name(ctx.repository.id, "budgeted")
      assert channel.spend_limit == 3.0

      assert {:ok, text} = call(ChannelCreate, %{name: "free", spend_limit: 0}, ctx)
      refute text =~ "spend limit"
      assert Channels.get_by_name(ctx.repository.id, "free").spend_limit == nil

      # no tool changes a limit; the user's panel records "user"
      refute "spend_limit_set" in Canopy.MCP.Server.tool_names()
    end

    test "creates a channel owned by the caller, with members, task, and a first message", ctx do
      Channels.subscribe()

      assert {:ok, text} =
               call(
                 ChannelCreate,
                 %{
                   name: "Retry Backoff!",
                   topic: "Cap the retry backoff",
                   task: "Add a ceiling and a test",
                   agents: "@#{ctx.reviewer.name}, #{ctx.agent.name}",
                   text: "Kicking this off. Findings to follow."
                 },
                 ctx
               )

      [_, id] = Regex.run(~r/created #retry-backoff \[(ch_[^\]]+)\]/, text)
      assert text =~ "you own it"
      assert text =~ "@#{ctx.agent.name}" and text =~ "@#{ctx.reviewer.name}"
      assert text =~ "posted [msg_"

      channel = Channels.get!(id)
      assert channel.repository_id == ctx.repository.id
      assert channel.owner_agent_id == ctx.agent.id
      assert channel.kind == "channel"
      assert channel.topic == "Cap the retry backoff"
      assert channel.task.title == "Cap the retry backoff"
      assert channel.task.description == "Add a ceiling and a test"

      assert Enum.map(channel.agents, & &1.id) |> Enum.sort() ==
               Enum.sort([ctx.agent.id, ctx.reviewer.id])

      assert [%{body: "Kicking this off. Findings to follow."}] = Messages.list(id)
      assert_receive {:channels, :changed}
    end

    test "creates a channel in another registered repository on request", ctx do
      other = repository_fixture(%{name: "calculator_app"})

      assert {:ok, text} =
               call(ChannelCreate, %{name: "calc", repository: "calculator_app"}, ctx)

      [_, id] = Regex.run(~r/created #calc \[(ch_[^\]]+)\]/, text)
      assert text =~ "in calculator_app"
      channel = Channels.get!(id)
      assert channel.repository_id == other.id
      assert channel.owner_agent_id == ctx.agent.id

      assert {:error, reason} = call(ChannelCreate, %{name: "x", repository: "nope"}, ctx)
      assert reason =~ "unknown repository"
      assert reason =~ "calculator_app"
    end

    test "rejects a taken name and unknown agents", ctx do
      assert {:error, reason} = call(ChannelCreate, %{name: ctx.channel.name}, ctx)
      assert reason =~ "could not create channel"
      assert {:error, reason} = call(ChannelCreate, %{name: "fresh", agents: "@nobody"}, ctx)
      assert reason =~ "unknown agent"
      assert {:error, "name is empty"} = call(ChannelCreate, %{name: "###"}, ctx)
    end
  end

  describe "channel_add_members" do
    test "any member adds agents; repeats are reported; DMs refused", ctx do
      Timeline.subscribe(ctx.channel.id)

      # the reviewer is a member, not the owner
      assert {:ok, text} =
               call(ChannelAddMembers, %{agents: "@#{ctx.tester.name}"}, ctx.reviewer_session)

      assert text =~ "added @#{ctx.tester.name} to ##{ctx.channel.name}"
      assert Channels.member?(ctx.channel, ctx.tester)
      assert_receive {:timeline, %{event_type: "member_added"}}

      assert {:ok, text} = call(ChannelAddMembers, %{agents: "@#{ctx.tester.name}"}, ctx)
      assert text =~ "@#{ctx.tester.name} already there"
      refute text =~ "added"

      assert {:error, "no agents to add"} =
               call(ChannelAddMembers, %{agents: ctx.agent.name}, ctx)

      {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
      dm_session = session_fixture(%{channel: dm, agent_id: ctx.agent.id})

      assert {:error, reason} =
               call(ChannelAddMembers, %{agents: "@#{ctx.tester.name}"}, dm_session)

      assert reason =~ "is a DM"
    end
  end

  describe "channel_remove_members" do
    test "only the owner removes, never itself, and DMs are fixed", ctx do
      Timeline.subscribe(ctx.channel.id)
      {:ok, _} = Channels.add_agent(ctx.channel, ctx.tester)

      assert {:error, reason} =
               call(ChannelRemoveMembers, %{agents: "@#{ctx.tester.name}"}, ctx.reviewer_session)

      assert reason =~ "only the owner"
      assert Channels.member?(ctx.channel, ctx.tester)

      assert {:ok, text} =
               call(
                 ChannelRemoveMembers,
                 %{agents: "@#{ctx.tester.name}, @#{ctx.agent.name}, @#{ctx.tester.name}"},
                 ctx
               )

      assert text =~ "removed @#{ctx.tester.name} from ##{ctx.channel.name}"
      assert text =~ "@#{ctx.agent.name} is the owner"
      refute Channels.member?(ctx.channel, ctx.tester)
      assert Channels.member?(ctx.channel, ctx.agent)
      assert_receive {:timeline, %{event_type: "member_removed"}}

      assert {:ok, text} = call(ChannelRemoveMembers, %{agents: "@#{ctx.tester.name}"}, ctx)
      assert text =~ "@#{ctx.tester.name} not a member"

      {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
      dm_session = session_fixture(%{channel: dm, agent_id: ctx.agent.id})

      assert {:error, reason} =
               call(ChannelRemoveMembers, %{agents: "@#{ctx.tester.name}"}, dm_session)

      assert reason =~ "is a DM"
    end
  end
end
