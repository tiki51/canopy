defmodule Canopy.MCP.Tools.PassTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Mox

  alias Canopy.MCP.Tools.Pass
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
end
