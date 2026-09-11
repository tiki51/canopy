defmodule Canopy.Costs.AuditorTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Mox

  alias Canopy.{Channels, Messages, Runtime, Settings}
  alias Canopy.Costs.Auditor
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ctx = scenario()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _n, _c, _o -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> unique_suffix()}}
    end)

    on_exit(fn -> Enum.each(Channels.list(), &Runtime.stop_channel(&1.id)) end)
    ctx
  end

  test "picking, clearing, and asking for an audit in a DM", ctx do
    assert Auditor.agent() == nil
    assert {:error, :no_auditor} = Auditor.request(ctx.repository.id)
    assert {:error, :unknown_agent} = Auditor.assign("ag_nope")

    assert {:ok, _} = Auditor.assign(ctx.agent.id)
    assert Auditor.agent().id == ctx.agent.id
    assert Settings.get().auditor_agent_id == ctx.agent.id

    test_pid = self()

    expect(OC, :prompt_async, fn _dir, _sid, body, _opts ->
      send(test_pid, {:prompted, body})
      {:ok, ""}
    end)

    assert {:ok, dm} = Auditor.request(ctx.repository.id, "the todo channel")
    assert dm.kind == "dm"
    assert Enum.map(dm.agents, & &1.id) == [ctx.agent.id]

    [message] = Messages.list(dm.id)
    assert message.agent_id == nil
    assert message.body =~ "@#{ctx.agent.name} please audit"
    assert message.body =~ "canopy_costs_report"
    assert message.body =~ "Focus on: the todo channel"
    assert ctx.agent.id in message.mentions

    assert_receive {:prompted, _body}, 2_000

    assert {:ok, _} = Auditor.assign("")
    assert Auditor.agent() == nil
  end
end
