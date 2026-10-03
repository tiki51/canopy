defmodule Canopy.MCP.RedactTest do
  use ExUnit.Case, async: true

  alias Canopy.MCP.Redact

  @mask Redact.mask()

  describe "value/1 and map/1" do
    test "masks header and env values, keeping a scheme word" do
      assert Redact.value("ghp_abcdef123456") == @mask
      assert Redact.value("Bearer sk_live_123") == "Bearer " <> @mask
      assert Redact.value("basic dXNlcjpwYXNz") == "basic " <> @mask
    end

    test "keeps values that only reference a secret" do
      assert Redact.value("{env:API_KEY}") == "{env:API_KEY}"
      assert Redact.value("${GITHUB_TOKEN}") == "${GITHUB_TOKEN}"
      assert Redact.value("$TOKEN") == "$TOKEN"
      assert Redact.value("{file:~/.secrets/key}") == "{file:~/.secrets/key}"
      assert Redact.value("Bearer {env:API_KEY}") == "Bearer {env:API_KEY}"
    end

    test "a map keeps its keys and lists them" do
      assert Redact.map(%{"Authorization" => "Bearer x", "X-Key" => "y"}) ==
               {%{"Authorization" => "Bearer " <> @mask, "X-Key" => @mask},
                ["Authorization", "X-Key"]}

      assert Redact.map(nil) == {%{}, []}
    end
  end

  describe "url/1" do
    test "drops userinfo and masks query values" do
      assert Redact.url("https://user:pw@mcp.example.com/mcp?api_key=sk_123&mode=fast") ==
               "https://mcp.example.com/mcp?api_key=#{@mask}&mode=#{@mask}"
    end

    test "keeps a plain URL and referenced query values" do
      assert Redact.url("http://127.0.0.1:4000/mcp") == "http://127.0.0.1:4000/mcp"
      assert Redact.url("https://h.example/x?key=${KEY}") == "https://h.example/x?key=${KEY}"
    end
  end

  describe "command/1" do
    test "masks the value after a secret flag, in both forms" do
      assert Redact.command(["srv", "--token", "abc", "--port", "8080"]) ==
               "srv --token #{@mask} --port 8080"

      assert Redact.command(["srv", "--api-key=abc", "-p", "x"]) ==
               "srv --api-key=#{@mask} -p x"

      assert Redact.command(["srv", "--password", "${DB_PASSWORD}"]) ==
               "srv --password ${DB_PASSWORD}"
    end

    test "masks KEY=value pairs with a secret-looking key" do
      assert Redact.command(["env", "GITHUB_TOKEN=ghp_1", "LOG_LEVEL=debug", "srv"]) ==
               "env GITHUB_TOKEN=#{@mask} LOG_LEVEL=debug srv"
    end

    test "masks long opaque arguments but not paths" do
      opaque = "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7"
      path = "/Users/someone/projects/a-very-long-directory-name/server.js"

      assert Redact.command(["srv", opaque, path]) == "srv #{@mask} #{path}"
    end

    test "redacts URLs and inline credentials in arguments" do
      assert Redact.command(["mcp-remote", "https://u:p@h.example/mcp?token=t"]) ==
               "mcp-remote https://h.example/mcp?token=#{@mask}"

      assert Redact.command(["--header", "Authorization: Bearer sk_123"]) ==
               "--header Authorization: Bearer #{@mask}"
    end
  end

  describe "text/1" do
    test "redacts URLs and bearer credentials inside an error" do
      error = "connect ECONNREFUSED http://user:pw@db.example.com:5432/x?key=k1 (Bearer abc123)"

      redacted = Redact.text(error)

      assert redacted ==
               "connect ECONNREFUSED http://db.example.com:5432/x?key=#{@mask} (Bearer #{@mask})"

      refute redacted =~ "user:pw"
      refute redacted =~ "abc123"
    end

    test "nil stays nil" do
      assert Redact.text(nil) == nil
    end
  end

  describe "token/1" do
    test "shows the last 4 characters only" do
      assert Redact.token("abcdefghijklmnopWXYZ") == @mask <> "WXYZ"
      assert Redact.token("abc") == @mask
      assert Redact.token(nil) == nil
    end
  end
end
