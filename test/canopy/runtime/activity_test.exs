defmodule Canopy.Runtime.ActivityTest do
  use ExUnit.Case, async: true

  alias Canopy.Engine.Event
  alias Canopy.Runtime.Activity

  defp ev(type, data), do: %Event{type: type, session_id: "s", data: data, raw_type: "test"}

  test "a repeated step-finish part is one row and one cost" do
    card =
      Activity.fold_all([
        ev(:step_completed, %{
          part_id: "st1",
          reason: "tool-calls",
          cost: 0.003,
          tokens: %{input: 10}
        }),
        ev(:step_completed, %{
          part_id: "st1",
          reason: "tool-calls",
          cost: 0.003,
          tokens: %{input: 10}
        }),
        ev(:patch, %{part_id: "pt1", hash: "h", files: ["a.ex"]}),
        ev(:patch, %{part_id: "pt1", hash: "h", files: ["a.ex"]})
      ])

    assert [
             %{kind: :step, label: "step tool-calls"},
             %{kind: :diff, label: "patch", detail: "a.ex"}
           ] =
             card.entries

    assert_in_delta card.cost, 0.003, 0.00001
  end

  test "a blank tool title falls back to the tool name, and completion replaces the running row" do
    card =
      Activity.fold_all([
        ev(:tool_started, %{
          call_id: "c1",
          tool: "read",
          title: "",
          input: %{"filePath" => "lib/a.ex"}
        }),
        ev(:tool_completed, %{
          call_id: "c1",
          tool: "read",
          title: "Read a.ex",
          status: :ok,
          input: %{}
        })
      ])

    assert [%{key: "c1", label: "Read a.ex", status: :ok}] = card.entries
    assert card.tool_count == 1
  end

  test "the agent's text streams into one entry in order with the tools and is finished in place" do
    card =
      Activity.fold_all([
        ev(:text_delta, %{part_id: "t1", delta: "Checking the "}),
        ev(:text_delta, %{part_id: "t1", delta: "formula first."}),
        ev(:tool_started, %{call_id: "c1", tool: "bash", input: %{"command" => "brew audit"}}),
        ev(:text_done, %{part_id: "t1", text: "Checking the formula first."}),
        ev(:tool_completed, %{call_id: "c1", tool: "bash", status: :ok, input: %{}}),
        ev(:text_delta, %{part_id: "t2", delta: "Audit passed, "})
      ])

    assert [
             %{kind: :text, status: :ok, label: "Checking the formula first."},
             %{kind: :tool, status: :ok},
             %{kind: :text, status: :running, label: "Audit passed, "}
           ] = card.entries

    # Claude Code keys deltas by block index and the finished text by message
    card =
      Activity.fold_all([
        ev(:text_delta, %{part_id: "0", delta: "One "}),
        ev(:text_delta, %{part_id: "0", delta: "moment."}),
        ev(:text_done, %{part_id: "msg_1-text", text: "One moment."}),
        ev(:tool_completed, %{call_id: "c2", tool: "read", status: :ok, input: %{}}),
        ev(:text_delta, %{part_id: "0", delta: "Done."}),
        ev(:text_done, %{part_id: "msg_2-text", text: "Done."})
      ])

    assert [
             %{kind: :text, key: "text-msg_1-text", label: "One moment."},
             %{kind: :tool},
             %{kind: :text, key: "text-msg_2-text", label: "Done."}
           ] = card.entries

    # the closing text becomes the reply, so the stored card drops it
    assert [%{kind: :text}, %{kind: :tool}] = Activity.drop_trailing_text(card).entries

    assert [%{"kind" => "text", "label" => "One moment."} | _] =
             card |> Activity.drop_trailing_text() |> Activity.to_payload()

    assert [%{kind: :text}, %{kind: :tool}] =
             card
             |> Activity.drop_trailing_text()
             |> Activity.to_payload()
             |> Activity.from_payload()
  end

  test "payload round-trip keeps entries and normalises unknown values" do
    card = Activity.fold_all([ev(:file_changed, %{path: "/r/lib/a.ex"})])
    payload = Activity.to_payload(card)

    assert [%{"kind" => "file", "status" => "ok", "label" => "a.ex", "detail" => "/r/lib/a.ex"}] =
             payload

    assert [%{kind: :file, status: :ok, label: "a.ex"}] = Activity.from_payload(payload)

    assert [%{kind: :tool, status: :ok, key: "0", label: ""}] =
             Activity.from_payload([%{"kind" => "bogus", "status" => 3}])

    assert Activity.from_payload(nil) == []
  end

  test "the card's verb follows the latest running tool" do
    assert Activity.verb(Activity.new()) == "thinking"

    running = fn tool, input ->
      Activity.fold_all([ev(:tool_started, %{call_id: "c", tool: tool, input: input})])
    end

    assert Activity.verb(running.("read", %{"filePath" => "a.ex"})) == "researching"
    assert Activity.verb(running.("grep", %{})) == "researching"
    assert Activity.verb(running.("webfetch", %{})) == "researching the web"
    assert Activity.verb(running.("edit", %{})) == "building"

    assert Activity.verb(running.("bash", %{"command" => "mix test test/foo_test.exs"})) ==
             "testing"

    assert Activity.verb(running.("bash", %{"command" => "npm ci"})) == "installing"
    assert Activity.verb(running.("bash", %{"command" => "ls -la"})) == "running commands"
    assert Activity.verb(running.("todowrite", %{})) == "planning"
    assert Activity.verb(running.("canopy_messages_read", %{})) == "catching up"
    assert Activity.verb(running.("canopy_message_send", %{})) == "writing"
    assert Activity.verb(running.("canopy_delegate_task", %{})) == "coordinating"
    assert Activity.verb(running.("canopy_pass", %{})) == "wrapping up"
    assert Activity.verb(running.("mystery", %{})) == "working"

    # once the tool completes and text streams, it is thinking again
    done =
      Activity.fold_all([
        ev(:tool_started, %{call_id: "c", tool: "edit", input: %{}}),
        ev(:tool_completed, %{call_id: "c", tool: "edit", status: :ok, input: %{}}),
        ev(:text_delta, %{delta: "So", message_id: "m", part_id: "p"})
      ])

    assert Activity.verb(done) == "thinking"
  end
end
