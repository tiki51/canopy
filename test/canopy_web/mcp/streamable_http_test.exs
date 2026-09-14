defmodule CanopyWeb.MCP.StreamableHTTPTest do
  @moduledoc """
  Speaks real Streamable HTTP JSON-RPC to `/mcp` through the Phoenix endpoint:
  bearer auth, initialize, tools/list, and a tools/call with a stamped
  `canopy_session_id`.
  """

  use CanopyWeb.ConnCase, async: false

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.Settings

  @protocol_version "2025-11-25"

  setup %{conn: conn} do
    start_mcp_server()
    ctx = scenario()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Settings.mcp_token())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    Map.put(ctx, :conn, conn)
  end

  # `server: false` in config/test.exs makes Anubis skip the HTTP transport
  # unless told to start; the application uses plain `transport: :streamable_http`.
  defp start_mcp_server do
    case start_supervised({Canopy.MCP.Server, transport: {:streamable_http, start: true}}) do
      {:ok, _pid} -> :ok
      {:error, {{:already_started, _pid}, _spec}} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp rpc_post(conn, body) do
    post(conn, "/mcp", JSON.encode!(body))
  end

  defp initialize(conn) do
    conn =
      rpc_post(
        conn,
        rpc(1, "initialize", %{
          "protocolVersion" => @protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "opencode-test", "version" => "1.18.11"}
        })
      )

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    {decode_body(conn.resp_body), session_id}
  end

  defp with_session(conn, session_id) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer " <> Settings.mcp_token())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", @protocol_version)
  end

  test "initialize, tools/list, and tools/call with a stamped session id", ctx do
    {init, session_id} = initialize(ctx.conn)
    assert init["id"] == 1
    assert init["result"]["serverInfo"]["name"] == "Canopy"
    assert init["result"]["capabilities"]["tools"]

    conn =
      ctx.conn |> with_session(session_id) |> rpc_post(notification("notifications/initialized"))

    assert conn.status == 202

    conn = ctx.conn |> with_session(session_id) |> rpc_post(rpc(2, "tools/list"))
    assert conn.status == 200
    %{"result" => %{"tools" => tools}} = decode_body(conn.resp_body)
    assert Enum.sort(Enum.map(tools, & &1["name"])) == Enum.sort(Canopy.MCP.Server.tool_names())
    assert length(tools) == length(Canopy.MCP.Server.tool_names())

    for tool <- tools do
      # the permission tool is Claude Code's prompt host; its identity comes
      # from the connection, not a parameter
      if tool["name"] != "permission" do
        assert tool["inputSchema"]["properties"]["canopy_session_id"]["type"] == "string"
      end

      assert is_binary(tool["description"]) and tool["description"] != ""
    end

    conn =
      ctx.conn
      |> with_session(session_id)
      |> rpc_post(
        rpc(3, "tools/call", %{
          "name" => "channels_list",
          "arguments" => %{"canopy_session_id" => ctx.session.engine_session_id}
        })
      )

    assert conn.status == 200
    %{"result" => result} = decode_body(conn.resp_body)
    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "##{ctx.channel.name} [#{ctx.channel.id}] (current)"
    assert text =~ "owner @#{ctx.agent.name}"

    conn =
      ctx.conn
      |> with_session(session_id)
      |> rpc_post(rpc(4, "tools/call", %{"name" => "channels_list", "arguments" => %{}}))

    %{"result" => result} = decode_body(conn.resp_body)
    assert result["isError"] == true
    assert [%{"text" => text}] = result["content"]
    assert text =~ "unknown Canopy session"
  end

  test "responses can be SSE-framed when the client accepts text/event-stream", ctx do
    {_init, session_id} = initialize(ctx.conn)

    conn =
      ctx.conn
      |> with_session(session_id)
      |> put_req_header("accept", "application/json, text/event-stream")
      |> rpc_post(rpc(5, "tools/list"))

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert %{"result" => %{"tools" => tools}} = decode_body(conn.resp_body)
    assert length(tools) == length(Canopy.MCP.Server.tool_names())
  end

  test "a bad or missing bearer token is rejected with 401 before reaching the server", ctx do
    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer not-the-token")
      |> rpc_post(
        rpc(1, "initialize", %{"protocolVersion" => @protocol_version, "capabilities" => %{}})
      )

    assert conn.status == 401
    assert JSON.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    assert get_resp_header(conn, "mcp-session-id") == []

    conn =
      ctx.conn
      |> delete_req_header("authorization")
      |> rpc_post(
        rpc(1, "initialize", %{"protocolVersion" => @protocol_version, "capabilities" => %{}})
      )

    assert conn.status == 401
  end
end
