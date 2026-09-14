defmodule Canopy.ClaudeCode.EventsTest do
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.Events
  alias Canopy.Engine.Event

  @fixture Path.expand("../../support/claude_code_fixtures/events-capture.jsonl", __DIR__)
  @cwd "/Users/stevenbarber/devl/canopy/tmp/claude-spike/repo"

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
             {"Read", "calc.py"},
             {"Edit", "calc.py"},
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
    # nine message_start/message_delta pairs across the three processes
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

    assert [%Event{data: %{session: %{"model" => "claude-haiku-4-5-20251001"}}} | _] =
             for(%Event{type: :session_updated} = e <- events, do: e)

    assert Enum.count(events, &(&1.type == :agent_status and &1.data.status == :busy)) > 3
    # allowed rate-limit lines are noise
    refute Enum.any?(events, &(&1.type == :agent_status and &1.data.status == :retry))
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
