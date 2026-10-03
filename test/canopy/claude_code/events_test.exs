defmodule Canopy.ClaudeCode.EventsTest do
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.Events
  alias Canopy.Engine.Event

  @fixture Path.expand("../../support/claude_code_fixtures/events-capture.jsonl", __DIR__)
  @cwd "/workspace/repo"

  defp replay(path \\ @fixture, cwd \\ @cwd) do
    path
    |> File.stream!()
    |> Enum.map(&JSON.decode!/1)
    |> Enum.flat_map_reduce(Events.new(cwd), fn line, acc -> Events.normalize(line, acc) end)
    |> elem(0)
  end

  test "tool calls become started/completed pairs with titles, in order" do
    events = replay()

    started = for %Event{type: :tool_started, data: d} <- events, do: {d.tool, d.title}

    assert started == [
             {"Bash", "Check git status"},
             {"Glob", "Glob calc.py"},
             {"Read", "Read calc.py"},
             {"Edit", "Edit calc.py"},
             {"ToolSearch", "ToolSearch"},
             {"mcp__spike__echo", "mcp__spike__echo"},
             {"AskUserQuestion", "AskUserQuestion"}
           ]

    completed = for %Event{type: :tool_completed, data: d} <- events, do: d
    assert length(completed) == 7
    assert Enum.all?(completed, &(&1.status == :ok))

    assert Enum.map(completed, & &1.call_id) ==
             Enum.map(for(%Event{type: :tool_started, data: d} <- events, do: d), & &1.call_id)

    edit = Enum.find(completed, &(&1.tool == "Edit"))
    assert edit.input["file_path"] == @cwd <> "/calc.py"
    assert edit.output =~ "has been updated"
  end

  test "a successful edit reports the file as changed; reads do not" do
    changed = for %Event{type: :file_changed, data: %{path: path}} <- replay(), do: path
    assert changed == [@cwd <> "/calc.py"]
  end

  test "text streams as deltas and lands as text_done" do
    events = replay()
    deltas = for %Event{type: :text_delta, data: %{delta: d}} <- events, do: d
    assert Enum.join(deltas) =~ "CANOPY"
    assert [%Event{data: %{text: first}} | _] = for(%Event{type: :text_done} = e <- events, do: e)
    assert first =~ "Fixed"
  end

  test "each model call is one step with token buckets; the usage is not double counted" do
    steps = for %Event{type: :step_completed, data: d} <- replay(), do: d
    # Nine message_start/message_delta pairs across three turns.
    assert length(steps) == 9
    assert Enum.all?(steps, &(&1.tokens["input"] >= 0 and is_map(&1.tokens["cache"])))
    assert Enum.any?(steps, &(&1.tokens["cache"]["read"] > 20_000))
  end

  test "every result ends a turn with its usage and cost" do
    events = replay()
    usage = for %Event{type: :turn_usage, data: d} <- events, do: d
    assert [%{cost: first}, %{cost: compact}, %{cost: last}] = usage
    assert_in_delta first, 0.0746, 0.001
    assert compact > 0
    assert last > 0
    assert Enum.count(events, &(&1.type == :agent_completed)) == 3
    refute Enum.any?(events, &(&1.type == :agent_error))
  end

  test "the compaction boundary is reported with its token counts" do
    assert [%Event{data: %{message: %{"compact" => meta}}}] =
             for(%Event{type: :message_updated} = e <- replay(), do: e)

    assert meta["pre_tokens"] == 25655
    assert meta["post_tokens"] == 1764
  end

  test "init and status lines mark the agent busy and carry the model" do
    events = replay()

    assert [%Event{data: %{session: %{"model" => "claude-test"}}} | _] =
             for(%Event{type: :session_updated} = e <- events, do: e)

    assert Enum.count(events, &(&1.type == :agent_status and &1.data.status == :busy)) > 3
    # allowed rate-limit lines are noise
    refute Enum.any?(events, &(&1.type == :agent_status and &1.data.status == :retry))
  end

  test "init lists the MCP servers the turn loaded, with tool counts" do
    assert [%Event{data: %{servers: servers}}] =
             for(%Event{type: :mcp_servers} = e <- replay(), do: e)

    assert servers == [
             %{name: "canopy", status: "connected", tool_count: 3},
             %{name: "spike", status: "connected", tool_count: 1},
             %{name: "broken", status: "failed", tool_count: 0}
           ]
  end

  test "an error result becomes agent_error with a readable message" do
    {events, _} =
      Events.normalize(
        %{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "result" => "",
          "num_turns" => 5,
          "total_cost_usd" => 0.02,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        },
        Events.new()
      )

    assert [
             %Event{type: :step_completed},
             %Event{type: :turn_usage, data: %{cost: 0.02}},
             %Event{type: :agent_error, data: %{error: error}}
           ] = events

    assert error == %{"name" => "error_max_turns", "data" => %{"message" => "error_max_turns"}}
  end

  test "tool results carry their timing and what the structured result says" do
    completed =
      for %Event{type: :tool_completed, data: d} <- replay(), into: %{}, do: {d.call_id, d}

    started = for %Event{type: :tool_started, data: d} <- replay(), into: %{}, do: {d.call_id, d}

    # the tool_use and tool_result line timestamps bracket the call
    assert %{"start" => start} = started["call-1"].time
    assert %{"start" => ^start, "end" => finish} = completed["call-1"].time
    assert finish - start == 676

    bash = completed["call-1"]
    assert bash.stdout == "clean"
    refute Map.has_key?(bash, :stderr)
    refute Map.has_key?(bash, :exit_code)

    assert completed["call-2"].matches == 1

    edit = completed["call-4"]
    assert edit.adds == 1 and edit.dels == 1
    assert edit.patch =~ "--- calc.py\n+++ calc.py\n@@ -1,1 +1,1 @@"
    assert edit.patch =~ "+def add(a, b): return a + b"

    # lines without the newer fields still complete, untimed
    assert completed["call-5"].time == %{}
  end

  test "a failed Bash call's exit code comes only from an `Exit code N` prefix" do
    run = fn content ->
      {_, acc} =
        Events.normalize(
          %{
            "type" => "assistant",
            "message" => %{
              "id" => "m",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "b1",
                  "name" => "Bash",
                  "input" => %{"command" => "mix test"}
                }
              ]
            }
          },
          Events.new()
        )

      {[%Event{type: :tool_completed, data: d}], _} =
        Events.normalize(
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "b1",
                  "content" => content,
                  "is_error" => true
                }
              ]
            },
            "tool_use_result" => %{"stdout" => "", "stderr" => "boom", "interrupted" => true}
          },
          acc
        )

      d
    end

    # unverified format (no capture yet): read the prefix, nothing else
    assert %{exit_code: 2, status: :error, stderr: "boom", interrupted: true} =
             run.("Exit code 2\nboom")

    refute Map.has_key?(run.("Command failed with exit code 2"), :exit_code)
  end

  test "a denied tool shows up as a failed tool call" do
    {[%Event{type: :tool_completed, data: d}], _} =
      Events.normalize(
        %{
          "type" => "system",
          "subtype" => "permission_denied",
          "tool_name" => "Bash",
          "reason" => "no approval available"
        },
        Events.new()
      )

    assert d.status == :error and d.tool == "Bash" and d.error == "no approval available"
    assert d.denied == true
  end

  test "a tool result for an unknown call still completes something" do
    {[%Event{type: :tool_completed, data: d}], _} =
      Events.normalize(
        %{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "x",
                "content" => "hi",
                "is_error" => false
              }
            ]
          }
        },
        Events.new()
      )

    assert d.call_id == "x" and d.output == "hi"
  end
end
