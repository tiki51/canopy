defmodule Canopy.ClaudeCode.TurnTest do
  use ExUnit.Case, async: false

  alias Canopy.ClaudeCode.{Command, Supervisor, Turn}
  alias Canopy.Engine
  alias Canopy.Engine.Event

  @fake Path.expand("../../support/fake_claude.sh", __DIR__)

  setup do
    dir = Path.join([File.cwd!(), "_build", "test", "tmp", "claude-" <> suffix()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    sid = Ecto.UUID.generate()
    :ok = Engine.subscribe_session(sid)
    {:ok, dir: dir, sid: sid, log: Path.join(dir, "calls.log")}
  end

  defp suffix, do: System.unique_integer([:positive]) |> Integer.to_string(36)

  defp script!(dir, lines) do
    path = Path.join(dir, "script-#{suffix()}.jsonl")
    File.write!(path, Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\n")
    path
  end

  defp start(ctx, env, opts \\ []) do
    command = fn flag ->
      Command.build(
        binary: @fake,
        cwd: ctx.dir,
        stderr_file: Path.join(ctx.dir, "stderr.log"),
        session: {flag, ctx.sid},
        extra_env: [{"FAKE_CLAUDE_LOG", ctx.log} | env]
      )
    end

    {:ok, pid} =
      Supervisor.start_turn(
        ctx.sid,
        [
          repository_id: "repo_test",
          command: command,
          message: Command.user_message("do it"),
          stderr_file: Path.join(ctx.dir, "stderr.log"),
          cwd: ctx.dir
        ] ++
          opts
      )

    Process.monitor(pid)
    pid
  end

  defp init_line(sid),
    do: %{
      type: "system",
      subtype: "init",
      session_id: sid,
      model: "claude-haiku-4-5",
      mcp_servers: []
    }

  defp result_line(sid, extra \\ %{}) do
    Map.merge(
      %{
        type: "result",
        subtype: "success",
        is_error: false,
        num_turns: 2,
        result: "done",
        session_id: sid,
        total_cost_usd: 0.01,
        usage: %{input_tokens: 5, output_tokens: 3}
      },
      extra
    )
  end

  defp argv_lines(log),
    do:
      log |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "ARGV "))

  defp stdin_lines(log),
    do:
      log |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "STDIN "))

  test "a scripted turn broadcasts its events under the session id and exits", ctx do
    script =
      script!(ctx.dir, [
        init_line("SESSION_ID"),
        %{
          type: "assistant",
          session_id: "SESSION_ID",
          message: %{
            id: "msg_1",
            content: [%{type: "tool_use", id: "toolu_1", name: "Bash", input: %{command: "ls"}}]
          }
        },
        %{
          type: "user",
          session_id: "SESSION_ID",
          message: %{
            content: [
              %{type: "tool_result", tool_use_id: "toolu_1", content: "a.ex", is_error: false}
            ]
          }
        },
        %{
          type: "assistant",
          session_id: "SESSION_ID",
          message: %{id: "msg_2", content: [%{type: "text", text: "all good"}]}
        },
        result_line("SESSION_ID")
      ])

    pid = start(ctx, [{"FAKE_CLAUDE_SCRIPT", script}])
    sid = ctx.sid

    assert_receive {:engine_event,
                    %Event{type: :agent_status, session_id: ^sid, data: %{status: :busy}}},
                   5_000

    assert_receive {:engine_event,
                    %Event{
                      type: :tool_started,
                      session_id: ^sid,
                      data: %{tool: "Bash", title: "ls"}
                    }},
                   5_000

    assert_receive {:engine_event,
                    %Event{
                      type: :tool_completed,
                      data: %{call_id: "toolu_1", output: "a.ex", status: :ok}
                    }},
                   5_000

    assert_receive {:engine_event, %Event{type: :text_done, data: %{text: "all good"}}}, 5_000
    assert_receive {:engine_event, %Event{type: :turn_usage, data: %{cost: 0.01}}}, 5_000
    assert_receive {:engine_event, %Event{type: :agent_completed, session_id: ^sid}}, 5_000
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000

    assert [argv] = argv_lines(ctx.log)
    assert argv =~ "--session-id #{sid}"
    assert [stdin] = stdin_lines(ctx.log)
    assert stdin =~ ~s("content":"do it")
    assert Supervisor.whereis(sid) == nil
  end

  test "a second turn for the same session is refused while one runs", ctx do
    pid = start(ctx, [{"FAKE_CLAUDE_SLEEP", "5"}])

    assert Supervisor.start_turn(ctx.sid,
             repository_id: "r",
             command: fn _ -> nil end,
             message: "x"
           ) == {:error, :busy}

    assert :ok = Turn.abort(pid)
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
  end

  test "an exit without a result is an error carrying the stderr tail", ctx do
    pid = start(ctx, [{"FAKE_CLAUDE_STDERR", "boom: no credit"}, {"FAKE_CLAUDE_EXIT", "3"}])

    assert_receive {:engine_event,
                    %Event{
                      type: :agent_error,
                      data: %{error: %{"data" => %{"message" => message}}}
                    }},
                   5_000

    assert message =~ "status 3"
    assert message =~ "boom: no credit"
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
  end

  test "a session id Claude Code already knows is retried with --resume", ctx do
    pid =
      start(ctx, [
        {"FAKE_CLAUDE_STDERR", "Error: Session ID x is already in use."},
        {"FAKE_CLAUDE_EXIT", "1"}
      ])

    assert_receive {:engine_event, %Event{type: :agent_error}}, 5_000
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
    assert [first, second] = argv_lines(ctx.log)
    assert first =~ "--session-id"
    assert second =~ "--resume #{ctx.sid}"
  end

  test "an unknown session on resume is retried with --session-id", ctx do
    pid =
      start(
        ctx,
        [
          {"FAKE_CLAUDE_STDERR", "No conversation found with session ID: x"},
          {"FAKE_CLAUDE_EXIT", "1"}
        ],
        flag: :resume
      )

    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
    assert [first, second] = argv_lines(ctx.log)
    assert first =~ "--resume"
    assert second =~ "--session-id #{ctx.sid}"
  end

  test "an empty zero-turn result is resent once, then accepted", ctx do
    script =
      script!(ctx.dir, [
        init_line("SESSION_ID"),
        result_line("SESSION_ID", %{num_turns: 0, result: ""})
      ])

    pid = start(ctx, [{"FAKE_CLAUDE_SCRIPT", script}])

    assert_receive {:engine_event, %Event{type: :agent_completed}}, 5_000
    refute_received {:engine_event, %Event{type: :agent_error}}
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
    assert length(stdin_lines(ctx.log)) == 2
  end

  test "a compaction turn accepts an empty result without resending", ctx do
    script =
      script!(ctx.dir, [
        init_line("SESSION_ID"),
        result_line("SESSION_ID", %{num_turns: 0, result: ""})
      ])

    pid = start(ctx, [{"FAKE_CLAUDE_SCRIPT", script}], compact?: true)

    assert_receive {:engine_event, %Event{type: :agent_completed}}, 5_000
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
    assert length(stdin_lines(ctx.log)) == 1
  end

  test "an aborted turn ends as completed, not as an error", ctx do
    script = script!(ctx.dir, [init_line("SESSION_ID")])
    pid = start(ctx, [{"FAKE_CLAUDE_SCRIPT", script}, {"FAKE_CLAUDE_SLEEP", "20"}])
    assert_receive {:engine_event, %Event{type: :agent_status}}, 5_000

    assert :ok = Turn.abort(pid)
    assert_receive {:engine_event, %Event{type: :turn_usage, data: %{cost: 0.001}}}, 5_000
    assert_receive {:engine_event, %Event{type: :agent_completed}}, 5_000
    refute_received {:engine_event, %Event{type: :agent_error}}
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
  end

  test "a silent process is killed after the stall window", ctx do
    pid = start(ctx, [{"FAKE_CLAUDE_SLEEP", "30"}], stall_ms: 600)

    assert_receive {:engine_event,
                    %Event{
                      type: :agent_error,
                      data: %{error: %{"data" => %{"message" => message}}}
                    }},
                   5_000

    assert message =~ "no output"
    assert_receive {:DOWN, _, :process, ^pid, :normal}, 5_000
  end
end
