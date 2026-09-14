defmodule Canopy.ClaudeCode.CommandTest do
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.Command

  defp build(extra \\ []) do
    Command.build(
      Keyword.merge(
        [
          binary: "/opt/claude",
          cwd: "/repo",
          stderr_file: "/tmp/err.log",
          session: {:new, "sid-1"}
        ],
        extra
      )
    )
  end

  test "wraps the binary in a shell exec that redirects stderr to the file" do
    %{executable: "/bin/sh", args: ["-c", script, "/opt/claude" | _], cwd: "/repo"} = build()
    assert script == ~s(exec "$0" "$@" 2>>"/tmp/err.log")
  end

  test "always streams json both ways, verbose, with partial messages, and strict MCP config" do
    %{args: args} = build()
    assert ["-c", _, "/opt/claude", "-p" | rest] = args
    assert "--output-format" in rest and "--input-format" in rest
    assert Enum.count(rest, &(&1 == "stream-json")) == 2
    assert "--verbose" in rest and "--include-partial-messages" in rest
    assert "--strict-mcp-config" in rest
  end

  test "a new session passes --session-id, a resumed one --resume" do
    assert build() |> pair("--session-id") == "sid-1"
    assert build(session: {:resume, "sid-2"}) |> pair("--resume") == "sid-2"
    refute build(session: {:resume, "sid-2"}).args |> Enum.member?("--session-id")
  end

  test "optional flags appear only when set" do
    base = build()
    refute "--model" in base.args
    refute "--append-system-prompt-file" in base.args
    refute "--allowedTools" in base.args
    refute "--mcp-config" in base.args

    full =
      build(
        model: "haiku",
        effort: "low",
        system_file: "/tmp/sys.md",
        mcp_config_file: "/tmp/mcp.json",
        permission_prompt_tool: "mcp__canopy__permission",
        permission_mode: "acceptEdits",
        allowed_tools: ["Read", "Bash(git *)"],
        disallowed_tools: ["WebSearch"],
        max_budget_usd: 2.5,
        max_turns: 40
      )

    assert pair(full, "--model") == "haiku"
    assert pair(full, "--effort") == "low"
    assert pair(full, "--append-system-prompt-file") == "/tmp/sys.md"
    assert pair(full, "--mcp-config") == "/tmp/mcp.json"
    assert pair(full, "--permission-prompt-tool") == "mcp__canopy__permission"
    assert pair(full, "--permission-mode") == "acceptEdits"
    assert pair(full, "--max-budget-usd") == "2.5"
    assert pair(full, "--max-turns") == "40"
    assert after_flag(full, "--allowedTools") == ["Read", "Bash(git *)"]
    assert after_flag(full, "--disallowedTools") == ["WebSearch"]
  end

  test "the environment unsets the nested-run marker and adds config dir, timeout, and extras" do
    %{env: env} =
      build(
        config_dir: "/home/u/.canopy-claude",
        mcp_tool_timeout_ms: 600_000,
        extra_env: [{"FAKE", 1}]
      )

    assert {~c"CLAUDECODE", false} in env
    assert {~c"DISABLE_AUTOUPDATER", ~c"1"} in env
    assert {~c"CLAUDE_CONFIG_DIR", ~c"/home/u/.canopy-claude"} in env
    assert {~c"MCP_TOOL_TIMEOUT", ~c"600000"} in env
    assert {~c"FAKE", ~c"1"} in env

    %{env: bare} = build()
    refute Enum.any?(bare, fn {k, _} -> k == ~c"CLAUDE_CONFIG_DIR" end)
    refute Enum.any?(bare, fn {k, _} -> k == ~c"MCP_TOOL_TIMEOUT" end)
  end

  test "user_message is one stream-json line with a string or content blocks" do
    line = Command.user_message("hello")
    assert String.ends_with?(line, "\n")

    assert JSON.decode!(line) == %{
             "type" => "user",
             "message" => %{"role" => "user", "content" => "hello"}
           }

    blocks = [
      %{type: "text", text: "hi"},
      %{type: "image", source: %{type: "base64", media_type: "image/png", data: "AA=="}}
    ]

    assert %{"message" => %{"content" => [%{"type" => "text"}, %{"type" => "image"}]}} =
             JSON.decode!(Command.user_message(blocks))
  end

  defp pair(%{args: args}, flag) do
    case Enum.drop_while(args, &(&1 != flag)) do
      [^flag, value | _] -> value
      _ -> nil
    end
  end

  # the values after a list flag, up to the next flag
  defp after_flag(%{args: args}, flag) do
    args
    |> Enum.drop_while(&(&1 != flag))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "--")))
  end
end
