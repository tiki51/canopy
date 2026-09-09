defmodule Canopy.OpenCode.ClientTest do
  use ExUnit.Case, async: true

  alias Canopy.OpenCode.Client

  @dir "/tmp/some/repo"

  setup do
    Req.Test.set_req_test_to_private()
    :ok
  end

  test "create_session posts JSON scoped to the directory" do
    Req.Test.stub(Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/session"
      assert conn.query_params["directory"] == @dir
      assert conn.body_params == %{"title" => "t", "parentID" => "ses_parent"}
      Req.Test.json(conn, %{"id" => "ses_new", "parentID" => "ses_parent"})
    end)

    assert {:ok, %{"id" => "ses_new"}} =
             Client.create_session(@dir, %{title: "t", parentID: "ses_parent"})
  end

  test "prompt_async sends parts, agent, system, tools and treats 204 as success" do
    Req.Test.stub(Client, fn conn ->
      assert conn.request_path == "/session/ses_1/prompt_async"

      assert %{"parts" => [%{"type" => "text", "text" => "hi"}], "tools" => %{"canopy_*" => true}} =
               conn.body_params

      assert conn.body_params["system"] == "role prompt"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    body = %{
      parts: [%{type: "text", text: "hi"}],
      agent: "build",
      system: "role prompt",
      tools: %{"canopy_*" => true}
    }

    assert {:ok, ""} = Client.prompt_async(@dir, "ses_1", body)
  end

  test "reply_permission encodes the reply atom" do
    Req.Test.stub(Client, fn conn ->
      assert conn.request_path == "/permission/per_9/reply"
      assert conn.body_params == %{"reply" => "reject"}
      Req.Test.json(conn, true)
    end)

    assert {:ok, true} = Client.reply_permission(@dir, "per_9", :reject)
  end

  test "add_mcp wraps name and config" do
    Req.Test.stub(Client, fn conn ->
      assert conn.request_path == "/mcp"
      assert conn.body_params["name"] == "canopy"
      assert conn.body_params["config"]["headers"]["Authorization"] == "Bearer tok"
      Req.Test.json(conn, %{"canopy" => %{"status" => "connected"}})
    end)

    config = %{
      type: "remote",
      url: "http://127.0.0.1:4000/mcp",
      headers: %{"Authorization" => "Bearer tok"},
      enabled: true
    }

    assert {:ok, %{"canopy" => %{"status" => "connected"}}} =
             Client.add_mcp(@dir, "canopy", config)
  end

  test "messages passes limit and before as query params" do
    Req.Test.stub(Client, fn conn ->
      assert conn.query_params == %{"directory" => @dir, "limit" => "5", "before" => "msg_x"}
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Client.messages(@dir, "ses_1", limit: 5, before: "msg_x")
  end

  test "non-2xx responses become {:error, {:http, status, body}}" do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"name" => "BadRequest"})
    end)

    assert {:error, {:http, 400, %{"name" => "BadRequest"}}} = Client.pending_permissions(@dir)
  end

  test "transport failures become {:error, {:transport, reason}}" do
    Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, {:transport, %Req.TransportError{reason: :econnrefused}}} = Client.health()
  end

  test "base_url can be overridden per call" do
    Req.Test.stub(Client, fn conn ->
      assert conn.host == "override.test"
      Req.Test.json(conn, %{"healthy" => true})
    end)

    assert {:ok, %{"healthy" => true}} = Client.health(base_url: "http://override.test")
  end

  test "impl/0 returns the configured module" do
    assert Client.impl() == Canopy.OpenCode.ClientMock
  end
end
