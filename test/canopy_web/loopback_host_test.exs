defmodule CanopyWeb.LoopbackHostTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias CanopyWeb.LoopbackHost

  defp call(host, headers \\ []) do
    conn = conn(:get, "/") |> Map.put(:host, host)

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> LoopbackHost.call(LoopbackHost.init([]))
  end

  test "loopback names pass through" do
    for host <- ["127.0.0.1", "localhost", "::1"] do
      refute call(host).halted, "#{host} was refused"
    end
  end

  test "any other name is refused, as a rebinding page's request would be" do
    conn = call("evil.example")
    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "127.0.0.1 or localhost"
  end

  test "a request relayed by a tunnel or proxy is refused even when it names localhost" do
    for header <- ["x-forwarded-for", "forwarded", "x-forwarded-host", "x-forwarded-proto"] do
      assert call("localhost", [{header, "203.0.113.7"}]).halted, "#{header} was let through"
    end
  end

  test "host_check off (CANOPY_BIND) lets every name through" do
    Application.put_env(:canopy, :host_check, false)
    on_exit(fn -> Application.delete_env(:canopy, :host_check) end)

    refute call("192.168.1.20").halted
    refute call("canopy.lan", [{"x-forwarded-for", "10.0.0.2"}]).halted
  end
end
