defmodule Canopy.Codex.EventsTest do
  @moduledoc "§6: codex app-server notifications as Canopy engine events."
  use ExUnit.Case, async: true

  alias Canopy.Codex.Events
  alias Canopy.Engine.Event

  @turn "019a0000-0000-7000-8000-0000000000aa"
  @earlier "019a0000-0000-7000-8000-0000000000a0"
  @repo "/work/repo"

  defp acc(opts \\ []), do: Events.new(@repo, opts) |> Events.put_turn(@turn)

  # Runs notifications through one accumulator; returns all events and the acc.
  defp run(acc, notifications) do
    Enum.reduce(notifications, {[], acc}, fn {method, params}, {events, acc} ->
      {new, acc} = Events.normalize(method, params, acc)
      {events ++ new, acc}
    end)
  end

  defp types(events), do: Enum.map(events, & &1.type)

  defp breakdown(input, cached, output, reasoning \\ 0) do
    %{
      "totalTokens" => input + output,
      "inputTokens" => input,
      "cachedInputTokens" => cached,
      "cacheWriteInputTokens" => 0,
      "outputTokens" => output,
      "reasoningOutputTokens" => reasoning
    }
  end

  defp usage(turn_id, total, last \\ nil) do
    {"thread/tokenUsage/updated",
     %{
       "threadId" => "thr",
       "turnId" => turn_id,
       "tokenUsage" => %{
         "total" => total,
         "last" => last || total,
         "modelContextWindow" => 258_400
       }
     }}
  end

  defp started(item, extra \\ %{}),
    do:
      {"item/started",
       Map.merge(%{"threadId" => "thr", "turnId" => @turn, "item" => item}, extra)}

  defp completed(item, extra \\ %{}),
    do:
      {"item/completed",
       Map.merge(%{"threadId" => "thr", "turnId" => @turn, "item" => item}, extra)}

  defp turn_completed(status, error \\ nil),
    do:
      {"turn/completed",
       %{
         "threadId" => "thr",
         "turn" => %{"id" => @turn, "status" => status, "items" => [], "error" => error}
       }}

  defp command_item(status, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "commandExecution",
        "id" => "exec-1",
        "command" => "/bin/zsh -lc 'mix test'",
        "cwd" => @repo,
        "status" => status,
        "commandActions" => [%{"type" => "unknown", "command" => "mix test"}],
        "aggregatedOutput" => nil,
        "exitCode" => nil,
        "durationMs" => nil
      },
      extra
    )
  end

  describe "session_event/2" do
    test "a thread/start or thread/resume response" do
      response = %{
        "thread" => %{"id" => "thr", "cliVersion" => "0.163.0", "model" => "ignored"},
        "model" => "gpt-5-codex",
        "approvalPolicy" => "on-request",
        "sandbox" => %{"type" => "workspaceWrite"}
      }

      assert %Event{type: :session_updated, data: %{session: session}} =
               Events.session_event(response, %{"permission_mode" => "acceptEdits"})

      assert session == %{
               "model" => "gpt-5-codex",
               "version" => "0.163.0",
               "sandbox" => "workspaceWrite",
               "approval" => "on-request",
               "permission_mode" => "acceptEdits"
             }
    end

    test "missing fields are left out; a string sandbox is kept" do
      assert %Event{data: %{session: %{"sandbox" => "read-only", "model" => "m"}}} =
               Events.session_event(%{"thread" => %{"model" => "m"}, "sandbox" => "read-only"})
    end
  end

  describe "turn/started and MCP status" do
    test "busy, keeping the turn id" do
      acc = Events.new(@repo)

      {events, acc} =
        run(acc, [{"turn/started", %{"turn" => %{"id" => @turn, "status" => "inProgress"}}}])

      assert [%Event{type: :agent_status, data: %{status: :busy}}] = events
      assert acc.turn_id == @turn
    end

    test "statuses before turn/started are sent with it; late ones on their own" do
      {events, acc} =
        run(Events.new(@repo), [
          {"mcpServer/startupStatus/updated", %{"name" => "canopy", "status" => "starting"}},
          {"mcpServer/startupStatus/updated", %{"name" => "canopy", "status" => "ready"}},
          {"mcpServer/startupStatus/updated", %{"name" => "docs", "status" => "starting"}}
        ])

      assert events == []

      {events, acc} = run(acc, [{"turn/started", %{"turn" => %{"id" => @turn}}}])
      assert [:agent_status, :mcp_servers] = types(events)

      assert List.last(events).data.servers == [
               %{name: "canopy", status: "connected", tool_count: nil},
               %{name: "docs", status: "starting", tool_count: nil}
             ]

      {events, _acc} =
        run(acc, [
          {"mcpServer/startupStatus/updated", %{"name" => "notes", "status" => "starting"}},
          {"mcpServer/startupStatus/updated",
           %{"name" => "docs", "status" => "failed", "error" => "boom"}}
        ])

      assert [%Event{type: :mcp_servers, data: %{servers: servers}}] = events

      assert %{name: "docs", status: "failed"} in Enum.map(
               servers,
               &Map.take(&1, [:name, :status])
             )
    end

    test "no MCP statuses, no :mcp_servers event" do
      {events, _} = run(Events.new(@repo), [{"turn/started", %{"turn" => %{"id" => @turn}}}])
      assert types(events) == [:agent_status]
    end
  end

  describe "agent messages" do
    test "deltas and the completed text" do
      {events, _} =
        run(acc(), [
          {"item/agentMessage/delta",
           %{"turnId" => @turn, "itemId" => "msg-2", "delta" => "All "}},
          {"item/agentMessage/delta", %{"turnId" => @turn, "itemId" => "msg-2", "delta" => ""}},
          completed(%{
            "type" => "agentMessage",
            "id" => "msg-2",
            "text" => "All done.",
            "phase" => "final_answer"
          })
        ])

      assert [
               %Event{
                 type: :text_delta,
                 data: %{message_id: @turn, part_id: "msg-2", delta: "All "}
               },
               %Event{
                 type: :text_done,
                 data: %{message_id: @turn, part_id: "msg-2", text: "All done."}
               }
             ] = events
    end

    test "commentary is text too; an empty message is nothing" do
      {events, _} =
        run(acc(), [
          completed(%{
            "type" => "agentMessage",
            "id" => "c",
            "text" => "Looking",
            "phase" => "commentary"
          }),
          completed(%{"type" => "agentMessage", "id" => "e", "text" => ""})
        ])

      assert [%Event{type: :text_done, data: %{text: "Looking"}}] = events
    end
  end

  describe "command items" do
    test "started and completed" do
      {events, acc} = run(acc(), [started(command_item("inProgress"), %{"startedAtMs" => 1000})])

      assert [%Event{type: :tool_started, data: data}] = events
      assert data.tool == "bash"
      assert data.call_id == "exec-1"
      assert data.part_id == "exec-1"
      assert data.message_id == @turn
      assert data.status == :running
      assert data.input == %{"command" => "mix test"}
      assert data.title == "mix test"
      assert data.time == %{"start" => 1000}
      assert Events.item_open?(acc)

      done =
        command_item("completed", %{
          "aggregatedOutput" => "3 tests, 0 failures\n",
          "exitCode" => 0,
          "durationMs" => 1200
        })

      {events, acc} = run(acc, [completed(done, %{"completedAtMs" => 2200})])
      refute Events.item_open?(acc)

      assert [%Event{type: :tool_completed, data: data}] = events
      assert data.tool == "bash"
      assert data.status == :ok
      assert data.output == "3 tests, 0 failures\n"
      assert data.stdout == "3 tests, 0 failures\n"
      assert data.exit_code == 0
      assert data.error == nil
      assert data.time == %{"start" => 1000, "end" => 2200}
      refute Map.has_key?(data, :denied)
    end

    test "a non-zero exit is an error" do
      {events, _} =
        run(acc(), [
          completed(command_item("failed", %{"aggregatedOutput" => "boom", "exitCode" => 1}))
        ])

      assert [%Event{data: %{status: :error, exit_code: 1, error: "boom"}}] = events
    end

    test "a declined command is denied" do
      {events, _} = run(acc(), [completed(command_item("declined"))])

      assert [%Event{data: %{status: :error, denied: true} = data}] = events
      assert data.error == "the user declined the command"
    end

    test "the command shown: actions joined, else the unwrapped raw command" do
      item =
        command_item("inProgress", %{
          "commandActions" => [
            %{"type" => "read", "command" => "cat a"},
            %{"type" => "read", "command" => "cat b"}
          ]
        })

      {[%Event{data: %{input: %{"command" => "cat a && cat b"}}}], _} =
        run(acc(), [started(item)])

      item = command_item("inProgress", %{"commandActions" => []})
      {[%Event{data: %{title: "mix test"}}], _} = run(acc(), [started(item)])
    end

    test "item_open?/1 holds between started and completed only for work items" do
      refute Events.item_open?(acc())

      {_, acc} = run(acc(), [started(%{"type" => "reasoning", "id" => "r1"})])
      refute Events.item_open?(acc)

      {_, acc} = run(acc, [started(command_item("inProgress"))])
      assert Events.item_open?(acc)

      {_, acc} = run(acc, [completed(command_item("completed", %{"exitCode" => 0}))])
      refute Events.item_open?(acc)
    end
  end

  describe "file changes" do
    test "apply_patch with display paths, the patch and counts, and :file_changed" do
      item = %{
        "type" => "fileChange",
        "id" => "exec-3",
        "changes" => [
          %{
            "path" => @repo <> "/lib/a.ex",
            "kind" => %{"type" => "add"},
            "diff" => "defmodule A do\nend\n"
          },
          %{
            "path" => @repo <> "/lib/b.ex",
            "kind" => %{"type" => "update"},
            "diff" => "@@ -1 +1 @@\n-x\n+y\n"
          }
        ],
        "status" => "inProgress"
      }

      {events, acc} = run(acc(), [started(item)])
      assert [%Event{type: :tool_started, data: data}] = events
      assert data.tool == "apply_patch"
      assert data.input == %{"files" => ["lib/a.ex", "lib/b.ex"]}
      assert data.title == "Edit lib/a.ex +1"

      {events, _} = run(acc, [completed(%{item | "status" => "completed"})])

      assert [%Event{type: :tool_completed, data: data} | changed] = events
      assert data.status == :ok
      assert data.adds == 3
      assert data.dels == 1
      assert data.patch =~ "--- /dev/null\n+++ lib/a.ex\n+defmodule A do"
      assert data.error == nil

      assert Enum.map(changed, &{&1.type, &1.data.path}) == [
               {:file_changed, @repo <> "/lib/a.ex"},
               {:file_changed, @repo <> "/lib/b.ex"}
             ]
    end

    test "a declined change is denied and changes nothing" do
      item = %{
        "type" => "fileChange",
        "id" => "f",
        "changes" => [
          %{"path" => "/etc/hosts", "kind" => %{"type" => "update"}, "diff" => "@@\n-a\n+b\n"}
        ],
        "status" => "declined"
      }

      {events, _} = run(acc(), [completed(item)])
      assert [%Event{type: :tool_completed, data: %{status: :error, denied: true}}] = events
    end
  end

  describe "MCP and other tool items" do
    test "an MCP call is mcp__<server>__<tool>" do
      item = %{
        "type" => "mcpToolCall",
        "id" => "exec-2",
        "server" => "canopy",
        "tool" => "message_send",
        "status" => "inProgress",
        "arguments" => %{"text" => "hi"},
        "result" => nil,
        "error" => nil
      }

      {[%Event{type: :tool_started, data: data}], acc} = run(acc(), [started(item)])
      assert data.tool == "mcp__canopy__message_send"
      assert data.input == %{"text" => "hi"}

      done = %{
        item
        | "status" => "completed",
          "result" => %{"content" => [%{"type" => "text", "text" => "posted"}]}
      }

      {[%Event{type: :tool_completed, data: data}], _} = run(acc, [completed(done)])
      assert data.status == :ok
      assert data.output == "posted"
      assert data.error == nil
    end

    test "an MCP error carries its message" do
      item = %{
        "type" => "mcpToolCall",
        "id" => "m",
        "server" => "docs",
        "tool" => "search",
        "status" => "failed",
        "error" => %{"message" => "server gone"}
      }

      {[%Event{data: %{status: :error, error: "server gone"}}], _} = run(acc(), [completed(item)])
    end

    test "web search, dynamic tools and collab agents" do
      {events, _} =
        run(acc(), [
          started(%{"type" => "webSearch", "id" => "w", "query" => "elixir json"}),
          started(%{
            "type" => "dynamicToolCall",
            "id" => "d",
            "tool" => "lookup",
            "arguments" => %{"a" => 1}
          }),
          started(%{"type" => "collabAgentToolCall", "id" => "a", "tool" => "spawn"})
        ])

      assert [
               %Event{
                 data: %{
                   tool: "websearch",
                   title: "elixir json",
                   input: %{"query" => "elixir json"}
                 }
               },
               %Event{data: %{tool: "lookup", input: %{"a" => 1}}},
               %Event{data: %{tool: "agent"}}
             ] = events

      {events, _} =
        run(acc(), [completed(%{"type" => "webSearch", "id" => "w", "query" => "q"})])

      assert [%Event{type: :tool_completed, data: %{tool: "websearch", status: :ok}}] = events
    end

    test "reasoning shows nothing in the feed; compaction updates the message" do
      {events, _} =
        run(acc(), [
          started(%{"type" => "reasoning", "id" => "r"}),
          completed(%{"type" => "reasoning", "id" => "r", "summary" => ["thinking"]}),
          completed(%{"type" => "contextCompaction", "id" => "k"})
        ])

      assert [%Event{type: :message_updated, data: %{message: %{"compact" => %{}}}}] = events
    end
  end

  test "turn/diff/updated counts per file" do
    diff =
      "diff --git a/hello.txt b/hello.txt\nnew file mode 100644\n--- /dev/null\n+++ b/hello.txt\n" <>
        "@@ -0,0 +1 @@\n+hello\n" <>
        "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1,2 +1,2 @@\n-a\n-b\n+c\n"

    {[%Event{type: :diff, data: %{files: files}}], _} =
      run(acc(), [{"turn/diff/updated", %{"turnId" => @turn, "diff" => diff}}])

    assert files == [
             %{"file" => "hello.txt", "additions" => 1, "deletions" => 0},
             %{"file" => "lib/a.ex", "additions" => 1, "deletions" => 2}
           ]

    assert {[], _} = Events.normalize("turn/diff/updated", %{"diff" => ""}, acc())
  end

  describe "tokens" do
    test "tokens/1 splits cached input out of input" do
      assert Events.tokens(breakdown(1000, 400, 100, 20)) == %{
               "input" => 600,
               "output" => 100,
               "reasoning" => 20,
               "cache" => %{"read" => 400, "write" => 0}
             }

      assert Events.tokens(%{}) == %{
               "input" => 0,
               "output" => 0,
               "reasoning" => 0,
               "cache" => %{"read" => 0, "write" => 0}
             }
    end

    test "breakdown/1 and subtract/2" do
      assert Events.breakdown(nil) == Events.zero()
      assert Events.breakdown(%{"inputTokens" => 5.4})["inputTokens"] == 5
      assert Events.subtract(breakdown(10, 0, 5), breakdown(20, 0, 1))["inputTokens"] == 0
      assert Events.subtract(breakdown(10, 0, 5), breakdown(20, 0, 1))["outputTokens"] == 4
    end
  end

  describe "usage" do
    test "steps from the change in total; a duplicate update emits nothing" do
      first = breakdown(2000, 800, 150)
      second = breakdown(3500, 1600, 300)

      {events, acc} =
        run(acc(model: "gpt-5-codex"), [
          usage(@turn, first),
          usage(@turn, first),
          usage(@turn, second, breakdown(1500, 800, 150))
        ])

      assert [
               %Event{type: :step_completed, data: one},
               %Event{type: :step_completed, data: two}
             ] = events

      assert one.part_id == "usage-1"
      assert one.message_id == @turn
      # the step's own estimate: 1200 × 1.25 + 800 × 0.125 + 150 × 10, per million
      assert_in_delta one.cost, 0.0031, 1.0e-9
      assert one.cost_estimated == true
      assert one.reason == "completed"
      assert one.context_window == 258_400

      assert one.tokens == %{
               "input" => 1200,
               "output" => 150,
               "reasoning" => 0,
               "cache" => %{"read" => 800, "write" => 0}
             }

      assert two.part_id == "usage-2"

      assert two.tokens == %{
               "input" => 700,
               "output" => 150,
               "reasoning" => 0,
               "cache" => %{"read" => 800, "write" => 0}
             }

      assert acc.context == 2000

      usage = Events.turn_usage(acc, "completed")
      assert usage.type == :turn_usage
      assert usage.data.cost_estimated == true
      assert usage.data.finish == "completed"
      assert usage.data.tokens == Events.tokens(second)
      assert usage.data.cost == Canopy.Codex.Pricing.cost("gpt-5-codex", Events.tokens(second))
      assert usage.data.cost > 0
    end

    test "after resume, another turn's replayed totals set the base and are never counted" do
      replayed = breakdown(5000, 2000, 500)
      now = breakdown(6000, 2400, 600)

      {events, acc} = run(acc(), [usage(@earlier, replayed)])
      assert events == []

      {events, acc} = run(acc, [usage(@turn, now)])

      assert [%Event{type: :step_completed, data: %{tokens: tokens}}] = events

      assert tokens == %{
               "input" => 600,
               "output" => 100,
               "reasoning" => 0,
               "cache" => %{"read" => 400, "write" => 0}
             }

      # turn usage is total − base
      assert Events.turn_usage(acc, "completed").data.tokens == tokens

      # another turn's update after this turn counted is ignored
      {events, acc2} = run(acc, [usage(@earlier, breakdown(9999, 0, 0))])
      assert events == []
      assert acc2 == acc
    end

    test "an update before the turn id is known is a base" do
      acc = Events.new(@repo)
      {[], acc} = run(acc, [usage(@turn, breakdown(100, 0, 10))])
      assert acc.base == breakdown(100, 0, 10)
    end

    test "no usage at all is a zero turn" do
      assert Events.turn_usage(acc(), "completed").data.tokens == Events.tokens(%{})
    end
  end

  describe "turn/completed" do
    test "completed: usage then completed" do
      {events, _} = run(acc(), [usage(@turn, breakdown(100, 0, 10)), turn_completed("completed")])

      assert [:step_completed, :turn_usage, :agent_completed] = types(events)
      assert Enum.at(events, 1).data.finish == "completed"
      assert Enum.at(events, 1).data.cost_estimated == true
    end

    test "interrupted is completed, not an error" do
      {events, _} = run(acc(), [turn_completed("interrupted")])
      assert [:turn_usage, :agent_completed] = types(events)
      assert hd(events).data.finish == "interrupted"
    end

    test "failed: usage, then an error named from codexErrorInfo" do
      error = %{"message" => "model gpt-9 does not exist", "codexErrorInfo" => "badRequest"}

      {events, _} = run(acc(), [turn_completed("failed", error)])
      assert [:turn_usage, :agent_error] = types(events)

      assert List.last(events).data.error == %{
               "name" => "badRequest",
               "data" => %{"message" => "model gpt-9 does not exist"}
             }
    end

    test "a one-key map names the error by its key" do
      error = %{
        "message" => "connection failed",
        "codexErrorInfo" => %{"httpConnectionFailed" => %{"httpStatusCode" => nil}}
      }

      {events, _} = run(acc(), [turn_completed("failed", error)])
      assert List.last(events).data.error["name"] == "httpConnectionFailed"
    end

    test "unauthorized says to sign in" do
      {events, _} =
        run(acc(), [
          turn_completed("failed", %{"message" => "401", "codexErrorInfo" => "unauthorized"})
        ])

      assert List.last(events).data.error == %{
               "name" => "unauthorized",
               "data" => %{"message" => "Codex is not signed in: run `codex login`"}
             }
    end

    test "a failed turn without its own error reports the kept error, else a generic one" do
      kept = %{
        "message" => "You've hit your usage limit.",
        "codexErrorInfo" => "usageLimitExceeded"
      }

      {events, acc} =
        run(acc(), [{"error", %{"turnId" => @turn, "willRetry" => false, "error" => kept}}])

      assert events == []
      assert Events.error(acc) == kept

      {events, _} = run(acc, [turn_completed("failed")])
      assert List.last(events).data.error["name"] == "usageLimitExceeded"

      {events, _} = run(acc(), [turn_completed("failed")])

      assert List.last(events).data.error == %{
               "name" => "codex",
               "data" => %{"message" => "the turn failed"}
             }
    end

    test "error_name/1" do
      assert Events.error_name("rateLimitExceeded") == "rateLimitExceeded"
      assert Events.error_name(%{"a" => 1}) == "a"
      assert Events.error_name(%{"a" => 1, "b" => 2}) == "codex"
      assert Events.error_name(nil) == "codex"
    end
  end

  test "an error that will be retried is a :retry status" do
    error = %{"message" => "Reconnecting... 1/5", "codexErrorInfo" => "serverOverloaded"}

    {[%Event{type: :agent_status, data: data}], acc} =
      run(acc(), [{"error", %{"turnId" => @turn, "willRetry" => true, "error" => error}}])

    assert data.status == :retry
    assert data.raw == %{"message" => "Reconnecting... 1/5", "name" => "serverOverloaded"}
    assert Events.error(acc) == nil
  end

  test "model/rerouted updates the session and the model priced" do
    {[%Event{type: :session_updated, data: %{session: %{"model" => "gpt-5"}}}], acc} =
      run(acc(model: "gpt-5-codex"), [
        {"model/rerouted", %{"fromModel" => "gpt-5-codex", "toModel" => "gpt-5"}}
      ])

    assert acc.model == "gpt-5"
  end

  test "everything else is ignored" do
    for method <- [
          "remoteControl/status/changed",
          "account/rateLimits/updated",
          "thread/status/changed",
          "deprecationNotice",
          "serverRequest/resolved",
          "item/reasoning/summaryTextDelta"
        ] do
      assert {[], _} = Events.normalize(method, %{"x" => 1}, acc())
    end
  end
end
