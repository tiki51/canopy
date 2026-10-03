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
            mcp_servers: [
              %{name: "canopy", status: "connected"},
              %{name: "github", status: "failed"}
            ],
            tools: ["Read", "Edit", "mcp__canopy__message_send", "mcp__canopy__pass"]
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

  test "a relative configured Claude directory rejects the turn before launch", ctx do
    config = Application.fetch_env!(:canopy, :claude_code)
    Application.put_env(:canopy, :claude_code, Keyword.put(config, :config_dir, "relative/path"))

    {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")

    assert_receive {:timeline, %{event_type: "agent_error", payload: %{"reason" => reason}}},
                   5_000

    assert reason =~ "Claude config directory must be an absolute path"
    refute File.exists?(ctx.log)
  end

  describe "steering" do
    setup do
      {:ok, _} = Canopy.Settings.update(%{interrupt_on_mention: true})
      :ok
    end

    # The turn stops at a Bash call; the fake then waits for a steered line
    # and prints `steer_lines` (STEER_UUID: that line's uuid).
    defp steer_scripts(ctx, steer_lines, version \\ "9.9.9") do
      dir = Path.dirname(ctx.log)

      write = fn name, lines ->
        path = Path.join(dir, name)
        File.write!(path, Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\n")
        path
      end

      script =
        write.("steer-turn.jsonl", [
          %{
            type: "system",
            subtype: "init",
            session_id: "SESSION_ID",
            model: "claude-haiku-4-5",
            mcp_servers: [],
            claude_code_version: version
          },
          %{
            type: "assistant",
            session_id: "SESSION_ID",
            message: %{
              id: "msg_1",
              content: [
                %{type: "tool_use", id: "toolu_1", name: "Bash", input: %{command: "mix test"}}
              ]
            }
          }
        ])

      steer = write.("steer-fold.jsonl", steer_lines)

      Application.put_env(:canopy, :claude_code,
        binary: @fake,
        env: [
          {"FAKE_CLAUDE_SCRIPT", script},
          {"FAKE_CLAUDE_STEER_SCRIPT", steer},
          {"FAKE_CLAUDE_LOG", ctx.log}
        ]
      )
    end

    defp folded(uuids),
      do: [
        %{
          type: "user",
          session_id: "SESSION_ID",
          message: %{
            content: [
              %{type: "tool_result", tool_use_id: "toolu_1", content: "ok", is_error: false}
            ]
          }
        },
        %{
          type: "assistant",
          session_id: "SESSION_ID",
          message: %{id: "msg_2", content: [%{type: "text", text: "Switched to the other file."}]}
        },
        %{
          type: "result",
          subtype: "success",
          is_error: false,
          num_turns: 2,
          result: "Switched to the other file.",
          session_id: "SESSION_ID",
          total_cost_usd: 0.02,
          user_message_uuids: uuids,
          usage: %{input_tokens: 5, output_tokens: 3}
        }
      ]

    defp stdin_lines(log),
      do:
        log
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "STDIN "))

    # The coder's turn is at its Bash call.
    defp working(ctx) do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} run the tests")
      coder_id = ctx.coder.id
      assert_receive {:timeline, %{event_type: "agent_started", agent_id: ^coder_id}}, 5_000

      assert_receive {:telemetry, ^coder_id, %Canopy.Engine.Event{type: :tool_started}}, 5_000
    end

    test "a mention mid-turn goes into the running process: one turn, read mid-turn", ctx do
      steer_scripts(ctx, folded(["STEER_UUID"]))
      working(ctx)

      {:ok, message} =
        Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} use the other file")

      assert_receive {:timeline, %{event_type: "agent_interrupted"}}, 5_000

      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000
      assert payload["outcome"] == "ok"
      assert payload["interrupted_by"] == [message.id]
      refute_receive {:timeline, %{event_type: "agent_started"}}, 300

      assert [_prompt, steered] = stdin_lines(ctx.log)
      assert steered =~ ~s("priority":"next")
      assert steered =~ "The user sent this while you were working"
      assert steered =~ message.id
    end

    test "a steer the turn never read is sent again as the next turn", ctx do
      steer_scripts(ctx, folded([]))
      working(ctx)

      {:ok, message} =
        Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} use the other file")

      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      # the next turn starts from it, and is at its own Bash call
      coder_id = ctx.coder.id
      assert_receive {:timeline, %{event_type: "agent_started"}}, 5_000
      assert_receive {:telemetry, ^coder_id, %Canopy.Engine.Event{type: :tool_started}}, 5_000

      assert [_prompt, _steered, redelivered] = stdin_lines(ctx.log)
      assert redelivered =~ "Your previous turn ended before you read this message"
      assert redelivered =~ message.id
      refute redelivered =~ ~s("priority")

      assert {:ok, _} = Runtime.stop_all(ctx.channel.id)
    end

    test "below the minimum CLI version the mention waits for the turn", ctx do
      steer_scripts(ctx, folded(["STEER_UUID"]), "2.1.0")
      working(ctx)

      {:ok, message} =
        Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} use the other file")

      refute_receive {:timeline, %{event_type: "agent_interrupted"}}, 300
      assert [_prompt] = stdin_lines(ctx.log)

      # the user's Abort ends the turn; the waiting message starts the next
      assert {:ok, _} = Runtime.abort(ctx.channel.id, ctx.coder.id)

      assert_receive {:timeline,
                      %{event_type: "agent_turn_completed", payload: %{"outcome" => "stopped"}}},
                     10_000

      coder_id = ctx.coder.id
      assert_receive {:telemetry, ^coder_id, %Canopy.Engine.Event{type: :tool_started}}, 5_000
      assert [_prompt, next] = stdin_lines(ctx.log)
      assert next =~ message.id
      refute next =~ "while you were working"

      assert {:ok, _} = Runtime.stop_all(ctx.channel.id)
    end
  end

  describe "default model and effort" do
    defp argv(log) do
      log |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "ARGV "))
    end

    test "an agent without its own runs on the defaults from Settings", ctx do
      {:ok, _} = Canopy.Agents.update(ctx.coder, %{model_id: nil, effort: nil})
      {:ok, _} = Canopy.Settings.put_default_model("claude_code", %{model_id: "sonnet"})
      {:ok, _} = Canopy.Settings.put_default_effort("claude_code", "high")

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")
      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000

      assert payload["model"] == "sonnet"
      assert payload["model_source"] == "default"
      assert [line] = argv(ctx.log)
      assert line =~ "--model sonnet"
      assert line =~ "--effort high"

      # a new default reaches the next turn, with no reset
      {:ok, _} = Canopy.Settings.put_default_model("claude_code", %{model_id: "opus"})
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} again")
      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000

      assert payload["model"] == "opus"
      assert [_, second] = argv(ctx.log)
      assert second =~ "--resume"
      assert second =~ "--model opus"
    end

    test "with no default either, no --model is passed and Claude Code picks", ctx do
      {:ok, _} = Canopy.Agents.update(ctx.coder, %{model_id: nil, effort: nil})

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")
      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000

      assert payload["model"] == "claude default"
      assert payload["model_source"] == "engine"
      assert [line] = argv(ctx.log)
      refute line =~ "--model"
      refute line =~ "--effort"
    end

    test "the agent's own model and effort win over the defaults", ctx do
      {:ok, _} = Canopy.Agents.update(ctx.coder, %{effort: "low"})
      {:ok, _} = Canopy.Settings.put_default_model("claude_code", %{model_id: "sonnet"})
      {:ok, _} = Canopy.Settings.put_default_effort("claude_code", "high")

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")
      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000

      assert payload["model"] == "haiku"
      assert payload["model_source"] == "agent"
      assert [line] = argv(ctx.log)
      assert line =~ "--model haiku"
      assert line =~ "--effort low"
    end
  end

  describe "MCP servers" do
    @fixtures Path.expand("../../support/mcp_fixtures/claude", __DIR__)

    defp mcp_file(log) do
      [_, path] = Regex.run(~r/--mcp-config (\S+)/, File.read!(log))
      path |> File.read!() |> JSON.decode!()
    end

    test "every turn loads the repository's .mcp.json, Canopy's own server winning a clash",
         ctx do
      File.cp!(
        Path.join([@fixtures, "repo", ".mcp.json"]),
        Path.join(ctx.repository.path, ".mcp.json")
      )

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      log = File.read!(ctx.log)
      assert log =~ "--strict-mcp-config"

      %{"mcpServers" => servers} = mcp_file(ctx.log)
      assert Map.keys(servers) |> Enum.sort() == ["canopy", "docs", "github"]
      assert servers["github"]["env"]["GITHUB_TOKEN"] =~ "ghp_"
      assert servers["canopy"]["url"] == Canopy.MCP.url()
      session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)
      assert servers["canopy"]["headers"]["Authorization"] == "Bearer " <> session.mcp_token

      # edits apply on the next turn
      File.rm!(Path.join(ctx.repository.path, ".mcp.json"))
      File.rm!(ctx.log)
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} again")
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000
      assert %{"mcpServers" => %{"canopy" => _} = only} = mcp_file(ctx.log)
      assert map_size(only) == 1
    end

    test "a malformed .mcp.json is logged and skipped; the turn still runs", ctx do
      File.write!(Path.join(ctx.repository.path, ".mcp.json"), "{ not json")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")

          assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}},
                         10_000

          assert payload["outcome"] == "ok"
        end)

      assert log =~ "skipping"
      assert log =~ ".mcp.json: invalid JSON"
      assert %{"mcpServers" => servers} = mcp_file(ctx.log)
      assert Map.keys(servers) == ["canopy"]
    end

    test "the turn's init is recorded on the session, with tool counts", ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)
      assert session.mcp_servers_seen_at

      assert %{
               "servers" => [
                 %{"name" => "canopy", "status" => "connected", "tool_count" => 2},
                 %{"name" => "github", "status" => "failed", "tool_count" => 0}
               ]
             } = session.mcp_servers

      assert %{servers: [%{"name" => "canopy"} | _]} =
               AgentSessions.latest_mcp_servers(ctx.repository.id, "claude_code")
    end

    test "the inventory: Canopy and the repository's servers loaded, personal ones not, no secrets",
         ctx do
      File.cp!(
        Path.join([@fixtures, "repo", ".mcp.json"]),
        Path.join(ctx.repository.path, ".mcp.json")
      )

      home = Path.join(Path.dirname(ctx.log), "home")
      File.mkdir_p!(home)

      File.write!(
        Path.join(home, ".claude.json"),
        @fixtures
        |> Path.join("home/.claude.json")
        |> File.read!()
        |> String.replace("REPO_PATH", ctx.repository.path)
      )

      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} hello")
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      assert {:ok, engine} =
               Canopy.Engine.ClaudeCode.mcp_inventory(ctx.repository,
                 home: home,
                 config_dir: nil,
                 managed_path: "/nonexistent/managed-mcp.json"
               )

      assert Enum.map(engine.servers, & &1.name) == ["canopy", "docs", "github"]
      assert [canopy, docs, github] = engine.servers
      assert %{source: %{kind: :canopy}, status: :connected, tool_count: 2} = canopy
      assert canopy.observed_at
      assert %{source: %{kind: :project}, status: :unknown} = docs
      assert %{source: %{kind: :project}, status: :failed} = github

      ignored = Enum.map(engine.ignored, &{&1.name, &1.source.kind})
      assert ignored == [{"canopy", :project}, {"local-db", :local}, {"personal", :user}]

      session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)
      text = inspect(engine)
      refute text =~ session.mcp_token
      refute text =~ Canopy.Settings.mcp_token()

      for secret <- ~w(ghp_fixture sk_fixture docs-pass pk_fixture lk_fixture oat_fixture),
          do: refute(text =~ secret)
    end

    test "a malformed .mcp.json shows as a note on the inventory", ctx do
      File.write!(Path.join(ctx.repository.path, ".mcp.json"), "{ not json")

      {:ok, engine} =
        Canopy.Engine.ClaudeCode.mcp_inventory(ctx.repository,
          home: "/nonexistent-home",
          config_dir: nil,
          managed_path: "/nonexistent"
        )

      assert Enum.map(engine.servers, & &1.name) == ["canopy"]
      assert [note] = engine.notes
      assert note =~ ".mcp.json could not be used (invalid JSON at byte"
    end
  end
end
