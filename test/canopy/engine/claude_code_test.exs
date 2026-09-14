defmodule Canopy.Engine.ClaudeCodeTest do
  @moduledoc "A Claude Code agent driven through the channel runtime, with the fake binary."
  use Canopy.DataCase, async: false

  alias Canopy.{AgentSessions, Fixtures, Runtime, Timeline}

  @fake Path.expand("../../support/fake_claude.sh", __DIR__)

  setup do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "tmp",
        "claude-engine-" <> Fixtures.unique_suffix()
      ])

    File.mkdir_p!(dir)
    log = Path.join(dir, "calls.log")
    script = Path.join(dir, "script.jsonl")

    File.write!(
      script,
      Enum.map_join(
        [
          %{
            type: "system",
            subtype: "init",
            session_id: "SESSION_ID",
            model: "claude-haiku-4-5",
            mcp_servers: []
          },
          %{
            type: "stream_event",
            session_id: "SESSION_ID",
            event: %{
              type: "message_start",
              message: %{
                id: "msg_1",
                usage: %{
                  input_tokens: 12,
                  cache_read_input_tokens: 3000,
                  cache_creation_input_tokens: 0
                }
              }
            }
          },
          %{
            type: "assistant",
            session_id: "SESSION_ID",
            message: %{
              id: "msg_1",
              content: [
                %{
                  type: "tool_use",
                  id: "toolu_1",
                  name: "Edit",
                  input: %{file_path: "/repo/lib/a.ex", old_string: "a", new_string: "b"}
                }
              ]
            }
          },
          %{
            type: "stream_event",
            session_id: "SESSION_ID",
            event: %{
              type: "message_delta",
              delta: %{stop_reason: "tool_use"},
              usage: %{output_tokens: 40}
            }
          },
          %{
            type: "user",
            session_id: "SESSION_ID",
            message: %{
              content: [
                %{type: "tool_result", tool_use_id: "toolu_1", content: "edited", is_error: false}
              ]
            }
          },
          %{
            type: "assistant",
            session_id: "SESSION_ID",
            message: %{id: "msg_2", content: [%{type: "text", text: "Renamed a to b."}]}
          },
          %{
            type: "result",
            subtype: "success",
            is_error: false,
            num_turns: 2,
            result: "Renamed a to b.",
            session_id: "SESSION_ID",
            total_cost_usd: 0.0123,
            usage: %{input_tokens: 12, output_tokens: 40, cache_read_input_tokens: 3000}
          }
        ],
        "\n",
        &JSON.encode!/1
      ) <> "\n"
    )

    previous = Application.get_env(:canopy, :claude_code)

    Application.put_env(:canopy, :claude_code,
      binary: @fake,
      env: [{"FAKE_CLAUDE_SCRIPT", script}, {"FAKE_CLAUDE_LOG", log}]
    )

    on_exit(fn ->
      Application.put_env(:canopy, :claude_code, previous)
      File.rm_rf!(dir)
    end)

    coder =
      Fixtures.agent_fixture(%{
        name: "coder" <> Fixtures.unique_suffix(),
        engine: "claude_code",
        model_id: "haiku"
      })

    scenario = Fixtures.scenario(members: [coder])
    Timeline.subscribe(scenario.channel.id)
    {:ok, _pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    {:ok, Map.merge(scenario, %{coder: coder, log: log})}
  end

  test "a mention wakes the Claude Code agent: a session, a turn with cost and model, a reply",
       ctx do
    {:ok, _} =
      Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} please rename a to b")

    assert_receive {:timeline, %{event_type: "agent_started", agent_id: agent_id}}, 5_000
    assert agent_id == ctx.coder.id

    assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000
    assert payload["cost"] == 0.0123
    assert payload["model"] == "haiku"
    assert payload["tools"] == 1
    assert payload["files"] == ["/repo/lib/a.ex"]
    assert payload["steps"] == 1
    assert payload["context"] == 3012
    assert payload["tokens"]["output"] == 40
    assert payload["outcome"] == "ok"

    assert_receive {:timeline,
                    %{
                      event_type: "message",
                      message: %{body: "Renamed a to b.", agent_id: ^agent_id}
                    }},
                   5_000

    session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)
    assert session.engine == "claude_code"
    assert session.status == "idle"
    assert session.last_seen_at

    log = File.read!(ctx.log)
    assert log =~ "--session-id #{session.engine_session_id}"
    assert log =~ "--model haiku"
    assert log =~ "--permission-mode default"
    assert log =~ "--strict-mcp-config"
    assert log =~ "--permission-prompt-tool mcp__canopy__permission"
    assert log =~ "mcp__canopy__*"
    assert [_, mcp_file] = Regex.run(~r/--mcp-config (\S+)/, log)

    assert %{
             "mcpServers" => %{
               "canopy" => %{
                 "type" => "http",
                 "url" => url,
                 "headers" => %{"Authorization" => "Bearer " <> token}
               }
             }
           } = mcp_file |> File.read!() |> JSON.decode!()

    assert url == Canopy.MCP.url()
    assert token == session.mcp_token
    assert is_binary(session.mcp_token)
    assert log =~ ~s("content":[{"type":"text","text":"You have a new Canopy message)
  end

  test "the next wake resumes the same session", ctx do
    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} first")
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} second")
    assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

    session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)

    argv =
      ctx.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "ARGV "))

    assert [first, second] = argv
    assert first =~ "--session-id #{session.engine_session_id}"
    assert second =~ "--resume #{session.engine_session_id}"
  end
end
