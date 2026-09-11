defmodule Canopy.MCP.Tools.DmTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.{Channels, Messages, Runtime}
  alias Canopy.MCP.Tools.{DmStart, DmSwitchRepository}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = agent_fixture(name: "reviewer-" <> unique_suffix())
    inactive = agent_fixture(name: "retired-" <> unique_suffix(), active: false)
    ctx = scenario()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    on_exit(fn -> Enum.each(Channels.list_dms(), &Runtime.stop_channel(&1.id)) end)
    Map.merge(ctx, %{reviewer: reviewer, inactive: inactive})
  end

  test "opens a one-to-one DM with the user and posts the first message", ctx do
    assert {:ok, text} = call(DmStart, %{text: "Quick question about the retry limit."}, ctx)

    assert [_, id, msg_id] =
             Regex.run(
               ~r/dm \[(ch_[^\]]+)\] #dm-#{ctx.agent.name} .*posted \[(msg_[^\]]+)\]/,
               text
             )

    dm = Channels.get!(id)
    assert dm.kind == "dm"
    assert dm.repository_id == ctx.repository.id
    assert Enum.map(dm.agents, & &1.id) == [ctx.agent.id]

    assert %{body: "Quick question about the retry limit.", channel_id: ^id} =
             Messages.get!(msg_id)

    assert Runtime.Supervisor.whereis(id)

    # calling again lands in the same DM
    assert {:ok, again} = call(DmStart, %{}, ctx)
    assert again =~ "dm [#{id}]"
    refute again =~ "posted"
  end

  test "includes other agents, always with the caller, deduplicated", ctx do
    assert {:ok, text} =
             call(
               DmStart,
               %{agents: "@#{ctx.reviewer.name}, #{ctx.agent.name}, @#{ctx.reviewer.name}"},
               ctx
             )

    [_, id] = Regex.run(~r/dm \[(ch_[^\]]+)\]/, text)
    dm = Channels.get!(id)
    assert dm.owner_agent_id == ctx.agent.id

    assert Enum.map(dm.agents, & &1.id) |> Enum.sort() ==
             Enum.sort([ctx.agent.id, ctx.reviewer.id])

    assert text =~ "with the user and " <> Channels.dm_label(dm)
  end

  test "opens the DM in another repository when asked", ctx do
    other = repository_fixture(%{name: "calculator_app"})
    assert {:ok, text} = call(DmStart, %{repository: "calculator_app"}, ctx)
    [_, id] = Regex.run(~r/dm \[(ch_[^\]]+)\]/, text)
    assert Channels.get!(id).repository_id == other.id
  end

  test "switching a DM's repository moves it; channels are refused", ctx do
    other = repository_fixture(%{name: "calculator_app"})
    {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
    dm_session = session_fixture(%{channel: dm, agent_id: ctx.agent.id})

    assert {:ok, text} = call(DmSwitchRepository, %{repository: "calculator_app"}, dm_session)
    assert text =~ "now works in calculator_app"
    assert text =~ "next turn"
    assert Channels.get!(dm.id).repository_id == other.id

    # with no runtime for the DM, the switch dropped its sessions at once; a new
    # turn would create one, so the next call comes from a fresh session
    dm_session = session_fixture(%{channel: Channels.get!(dm.id), agent_id: ctx.agent.id})
    assert {:ok, text} = call(DmSwitchRepository, %{repository: "calculator_app"}, dm_session)
    assert text =~ "already works in calculator_app"

    assert {:error, reason} = call(DmSwitchRepository, %{repository: "calculator_app"}, ctx)
    assert reason =~ "is a channel"
    assert {:error, reason} = call(DmSwitchRepository, %{repository: "nope"}, dm_session)
    assert reason =~ "unknown repository"
  end

  test "refuses unknown or deactivated agents", ctx do
    assert {:error, reason} = call(DmStart, %{agents: "@nobody-here"}, ctx)
    assert reason =~ "unknown agent"
    assert {:error, reason} = call(DmStart, %{agents: "@" <> ctx.inactive.name}, ctx)
    assert reason =~ "deactivated"
    assert Channels.list_dms() == []
  end
end
