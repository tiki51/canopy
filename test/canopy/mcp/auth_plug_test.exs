defmodule Canopy.MCP.AuthPlugTest do
  use Canopy.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Canopy.MCP.AuthPlug
  alias Canopy.Settings

  defp request(headers) do
    conn = conn(:post, "/mcp", "{}")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    AuthPlug.call(conn, AuthPlug.init([]))
  end

  test "passes with the configured bearer token" do
    conn = request([{"authorization", "Bearer " <> Settings.mcp_token()}])
    refute conn.halted
    assert conn.assigns.mcp_authenticated
  end

  test "accepts a case-insensitive scheme" do
    conn = request([{"authorization", "bearer " <> Settings.mcp_token()}])
    refute conn.halted
  end

  test "halts with 401 on a wrong, malformed, or missing token" do
    for headers <- [
          [{"authorization", "Bearer nope"}],
          [{"authorization", "Basic " <> Settings.mcp_token()}],
          [{"authorization", "Bearer"}],
          []
        ] do
      conn = request(headers)
      assert conn.halted
      assert conn.status == 401
      assert JSON.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end
  end

  test "a rotated token invalidates the old one" do
    old = Settings.mcp_token()
    {:ok, _} = Settings.rotate_mcp_token()
    assert request([{"authorization", "Bearer " <> old}]).status == 401
    refute request([{"authorization", "Bearer " <> Settings.mcp_token()}]).halted
  end
end
