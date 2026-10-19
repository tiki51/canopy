defmodule Canopy.Codex.RPCTest do
  use ExUnit.Case, async: true

  alias Canopy.Codex.RPC

  defp decoded(line) do
    assert String.ends_with?(line, "\n")
    refute String.contains?(String.trim_trailing(line, "\n"), "\n")
    JSON.decode!(line)
  end

  describe "encoding" do
    test "a request carries jsonrpc 2.0, the id, the method and the params" do
      assert decoded(RPC.request(3, "thread/start", %{"cwd" => "/repo"})) == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "thread/start",
               "params" => %{"cwd" => "/repo"}
             }
    end

    test "a request without params has no params key" do
      assert decoded(RPC.request(1, "account/read")) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "account/read"
             }
    end

    test "a notification has no id" do
      assert decoded(RPC.notification("initialized")) == %{
               "jsonrpc" => "2.0",
               "method" => "initialized"
             }

      assert decoded(RPC.notification("x", %{"a" => 1})) == %{
               "jsonrpc" => "2.0",
               "method" => "x",
               "params" => %{"a" => 1}
             }
    end

    test "a response to a server request carries the result" do
      assert decoded(RPC.response(0, %{"decision" => "accept"})) == %{
               "jsonrpc" => "2.0",
               "id" => 0,
               "result" => %{"decision" => "accept"}
             }
    end

    test "an error response carries code and message" do
      assert decoded(RPC.error(7, -32601, "not supported by Canopy")) == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{"code" => -32601, "message" => "not supported by Canopy"}
             }
    end

    test "text with newlines is escaped onto one line" do
      line = RPC.request(1, "turn/start", %{"text" => "a\nb"})
      assert decoded(line)["params"]["text"] == "a\nb"
    end
  end

  describe "decoding" do
    test "a response (Codex omits jsonrpc)" do
      assert RPC.decode(~s({"id":2,"result":{"thread":{"id":"t"}}})) ==
               {:response, 2, %{"thread" => %{"id" => "t"}}}

      assert RPC.decode(~s({"id":2,"result":null})) == {:response, 2, nil}
    end

    test "an error" do
      assert RPC.decode(~s({"id":4,"error":{"code":-32600,"message":"no active turn"}})) ==
               {:error, 4, %{"code" => -32600, "message" => "no active turn"}}
    end

    test "a server request" do
      line = ~s({"method":"item/commandExecution/requestApproval","id":0,"params":{"itemId":"i"}})

      assert RPC.decode(line) ==
               {:request, 0, "item/commandExecution/requestApproval", %{"itemId" => "i"}}
    end

    test "a notification" do
      assert RPC.decode(~s({"method":"turn/started","params":{"turn":{"id":"t"}}})) ==
               {:notification, "turn/started", %{"turn" => %{"id" => "t"}}}
    end

    test "missing or non-map params decode as an empty map" do
      assert RPC.decode(~s({"method":"initialized"})) == {:notification, "initialized", %{}}
      assert RPC.decode(~s({"method":"x","params":[1]})) == {:notification, "x", %{}}
      assert RPC.decode(~s({"method":"x","id":1})) == {:request, 1, "x", %{}}
    end

    test "with a trailing newline, and round-tripping our own lines" do
      assert RPC.decode(RPC.request(5, "m", %{"a" => 1})) == {:request, 5, "m", %{"a" => 1}}
      assert RPC.decode(RPC.notification("n")) == {:notification, "n", %{}}
      assert RPC.decode(RPC.response(5, %{})) == {:response, 5, %{}}

      assert RPC.decode(RPC.error(5, -1, "no")) ==
               {:error, 5, %{"code" => -1, "message" => "no"}}
    end

    test "anything else is invalid" do
      for line <- [
            "not json",
            "",
            "[1,2]",
            "42",
            ~s("string"),
            ~s({"id":1}),
            ~s({"foo":"bar"}),
            ~s({"method":3}),
            ~s({"id":1,"error":"boom"})
          ] do
        assert RPC.decode(line) == :invalid, "expected #{inspect(line)} to be invalid"
      end
    end
  end
end
