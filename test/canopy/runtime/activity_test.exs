defmodule Canopy.Runtime.ActivityTest do
  use ExUnit.Case, async: true

  alias Canopy.Engine.Event
  alias Canopy.Runtime.Activity

  defp ev(type, data), do: %Event{type: type, session_id: "s", data: data, raw_type: "test"}

  defp started(key, tool, input, extra \\ %{}),
    do: ev(:tool_started, Map.merge(%{call_id: key, tool: tool, input: input}, extra))

  defp completed(key, tool, input, extra \\ %{}),
    do:
      ev(
        :tool_completed,
        Map.merge(%{call_id: key, tool: tool, input: input, status: :ok}, extra)
      )

  test "a repeated step-finish part is one step and one cost; patches add chips, not rows" do
    card =
      Activity.fold_all([
        ev(:step_completed, %{
          part_id: "st1",
          reason: "tool-calls",
          cost: 0.003,
          tokens: %{input: 10, output: 5}
        }),
        ev(:step_completed, %{
          part_id: "st1",
          reason: "tool-calls",
          cost: 0.003,
          tokens: %{input: 10, output: 5}
        }),
        ev(:patch, %{part_id: "pt1", hash: "h", files: ["/r/a.ex"]}),
        ev(:patch, %{part_id: "pt1", hash: "h", files: ["/r/a.ex"]})
      ])

    assert card.entries == []
    assert [%{tokens: 15}] = card.steps
    assert card.tokens == 15
    assert [%{path: "/r/a.ex"}] = card.files
    assert_in_delta card.cost, 0.003, 0.00001
  end

  test "rows are labelled by category, and completion replaces the running row" do
    card =
      Activity.fold_all([
        started("c1", "read", %{}, %{title: ""}),
        started("c1", "read", %{"filePath" => "lib/a.ex"}, %{title: ""}),
        completed("c1", "read", %{}, %{title: "Read a.ex"})
      ])

    assert [%{key: "c1", label: "lib/a.ex", category: :read, status: :ok, path: "lib/a.ex"}] =
             card.entries

    assert card.tool_count == 1
    assert card.tallies == %{read: 1}

    # a blank title falls back to the tool name while nothing better is known
    assert [%{label: "mystery", category: :other}] =
             Activity.fold_all([started("c2", "mystery", %{}, %{title: " "})]).entries
  end

  test "categories cover each tool family, Canopy's own tools included" do
    assert Activity.category("Bash") == :shell
    assert Activity.category("bash") == :shell
    assert Activity.category("Read") == :read
    assert Activity.category("ls") == :read
    assert Activity.category("Grep") == :search
    assert Activity.category("Glob") == :search
    assert Activity.category("Edit") == :edit
    assert Activity.category("Write") == :edit
    assert Activity.category("apply_patch") == :edit
    assert Activity.category("WebFetch") == :web
    assert Activity.category("websearch") == :web
    assert Activity.category("mcp__canopy__message_send") == :canopy
    assert Activity.category("canopy_handoff_get") == :canopy
    assert Activity.category("TodoWrite") == :plan
    assert Activity.category("Task") == :agent
    assert Activity.category("mcp__spike__echo") == :other
    assert Activity.category(nil) == :other

    card = Activity.fold_all([started("c", "mcp__canopy__message_send", %{"text" => "hi"})])
    assert [%{label: "canopy message_send", category: :canopy}] = card.entries
  end

  test "rows carry the model step they came from" do
    card =
      Activity.fold_all([
        ev(:text_done, %{part_id: "t1", text: "Looking at the code."}),
        started("c1", "read", %{"filePath" => "a.ex"}),
        completed("c1", "read", %{"filePath" => "a.ex"}),
        ev(:step_completed, %{part_id: "s1", tokens: %{input: 100, output: 20}}),
        started("c2", "bash", %{"command" => "mix test"}),
        # the first call finishing late keeps its step
        completed("c1", "read", %{"filePath" => "a.ex"}),
        ev(:step_completed, %{part_id: "s2", tokens: %{input: 50}})
      ])

    assert [%{step: 0, kind: :text}, %{key: "c1", step: 0}, %{key: "c2", step: 1}] = card.entries
    assert Enum.map(card.steps, & &1.tokens) == [120, 50]
  end

  test "a call's duration comes from the engine's time, else from the runtime's stamps" do
    engine =
      Activity.fold_all([
        started("c1", "bash", %{"command" => "ls"}, %{time: %{"start" => 1_000}, at: 5_000}),
        completed("c1", "bash", %{"command" => "ls"}, %{
          time: %{"start" => 1_000, "end" => 3_500},
          at: 9_000
        })
      ])

    assert [%{started_at: 1_000, duration_ms: 2_500}] = engine.entries
    assert engine.started_at == 5_000

    stamped =
      Activity.fold_all([
        started("c1", "bash", %{"command" => "ls"}, %{at: 5_000}),
        completed("c1", "bash", %{"command" => "ls"}, %{at: 5_400})
      ])

    assert [%{started_at: 5_000, duration_ms: 400}] = stamped.entries
  end

  test "a failed command keeps its command, its exit code, and counts as an error" do
    card =
      Activity.fold_all([
        started("c1", "bash", %{"command" => "mix test test/billing", "description" => "Run"}),
        ev(:tool_completed, %{
          call_id: "c1",
          tool: "bash",
          status: :error,
          input: %{"command" => "mix test test/billing"},
          error: "1 failure\nmore",
          exit_code: 1
        }),
        # a later update of the same call does not count again
        ev(:tool_completed, %{
          call_id: "c1",
          tool: "bash",
          status: :error,
          input: %{},
          error: "1 failure"
        })
      ])

    assert [
             %{
               status: :error,
               label: "mix test test/billing",
               command: "mix test test/billing",
               description: "Run",
               exit_code: 1,
               fact: "exit 1",
               detail: "1 failure"
             }
           ] = card.entries

    assert card.tallies == %{shell: 1, errors: 1}
    assert %{"error" => "1 failure", "input" => "mix test test/billing"} = card.details["c1"]

    # OpenCode reports a non-zero exit as a completed call: it still failed
    exited =
      Activity.fold_all([completed("c2", "bash", %{"command" => "false"}, %{exit_code: 2})])

    assert [%{status: :error, fact: "exit 2"}] = exited.entries
    assert exited.tallies.errors == 1
  end

  test "an excerpt keeps the head and the tail and says how much it left out" do
    text = Enum.map_join(1..300, "\n", &"line #{&1}")
    {excerpt, true} = Activity.excerpt(text)
    lines = String.split(excerpt, "\n")

    assert length(lines) == 121
    assert hd(lines) == "line 1"
    assert List.last(lines) == "line 300"
    assert "⋯ 180 lines omitted ⋯" in lines

    assert Activity.excerpt("short\noutput") == {"short\noutput", false}

    {long, true} = Activity.excerpt(String.duplicate("x", 20_000))
    assert String.length(long) < 8_100
    assert long =~ "⋯ cut ⋯"
  end

  test "slim_event cuts outputs before broadcast and records the full line count" do
    output = Enum.map_join(1..500, "\n", &"out #{&1}")

    slim =
      Activity.slim_event(
        completed(
          "c1",
          "bash",
          %{"command" => "make", "content" => String.duplicate("y", 9_000)},
          %{
            output: output,
            metadata: %{"output" => output, "exit" => 0}
          }
        )
      )

    assert slim.data.output_lines == 500
    assert length(String.split(slim.data.output, "\n")) == 121
    assert slim.data.metadata == %{}
    assert String.length(slim.data.input["content"]) <= 4_000
    assert slim.data.input["command"] == "make"

    card = Activity.fold(slim, Activity.new())

    assert %{"output_lines" => 500, "truncated" => true, "output" => excerpt} =
             card.details["c1"]

    assert excerpt =~ "lines omitted"

    # other events pass through untouched
    delta = ev(:text_delta, %{part_id: "p", delta: "hi"})
    assert Activity.slim_event(delta) == delta
  end

  test "past the row cap the oldest finished rows go, counted; tallies stay exact" do
    events =
      Enum.flat_map(1..320, fn i ->
        key = "c#{i}"
        [started(key, "read", %{"filePath" => "f#{i}.ex"}), completed(key, "read", %{})]
      end)

    # one call still running among the oldest is never the one evicted
    card = Activity.fold_all([started("live", "bash", %{"command" => "sleep 9"}) | events])

    assert length(card.entries) == 300
    assert card.dropped == 21
    assert card.tool_count == 321
    assert card.tallies == %{read: 320, shell: 1}
    assert hd(card.entries).key == "live"
    assert Enum.at(card.entries, 1).key == "c22"
    refute Map.has_key?(card.details, "c1")
  end

  test "edit line counts go to the row and the file's chip; a diff with no edit adds a chip" do
    path = "/r/acme/billing/payments.py"

    card =
      Activity.fold_all([
        started("c1", "Edit", %{"file_path" => path}),
        completed("c1", "Edit", %{"file_path" => path}, %{adds: 12, dels: 3, patch: "@@\n+a"}),
        ev(:file_changed, %{path: path}),
        started("c2", "Edit", %{"file_path" => path}),
        completed("c2", "Edit", %{"file_path" => path}, %{adds: 1, dels: 0}),
        # memory is not work
        ev(:file_changed, %{path: "/r/.canopy/notes.md"}),
        ev(:diff, %{files: [%{"file" => "acme/gen.py", "additions" => 40, "deletions" => 0}]})
      ])

    assert [
             %{key: "c1", fact: "+12 −3", changed: true, adds: 12},
             %{key: "c2", fact: "+1 −0"}
           ] = card.entries

    assert [payments, gen] = card.files
    assert payments.path == path
    assert Activity.chip_stats(payments) == {13, 3}
    assert gen.path == "acme/gen.py"
    assert Activity.chip_stats(gen) == {40, 0}
    assert card.details["c1"]["patch"] == "@@\n+a"

    # a diff fills in an edit that reported no counts of its own
    card =
      Activity.fold_all([
        completed("c3", "write", %{"filePath" => "/r/acme/new.py"}),
        ev(:diff, %{files: [%{"file" => "acme/new.py", "additions" => 4, "deletions" => 0}]})
      ])

    assert [%{fact: "+4 −0", adds: 4}] = card.entries
  end

  test "the agent's text streams into one entry in order with the tools and is finished in place" do
    card =
      Activity.fold_all([
        ev(:text_delta, %{part_id: "t1", delta: "Checking the "}),
        ev(:text_delta, %{part_id: "t1", delta: "formula first."}),
        started("c1", "bash", %{"command" => "brew audit"}),
        ev(:text_done, %{part_id: "t1", text: "Checking the formula first."}),
        completed("c1", "bash", %{}),
        ev(:text_delta, %{part_id: "t2", delta: "Audit passed, "})
      ])

    assert [
             %{kind: :text, status: :ok, label: "Checking the formula first."},
             %{kind: :tool, status: :ok, label: "brew audit"},
             %{kind: :text, status: :running, label: "Audit passed, "}
           ] = card.entries

    # Claude Code keys deltas by block index and the finished text by message
    card =
      Activity.fold_all([
        ev(:text_delta, %{part_id: "0", delta: "One "}),
        ev(:text_delta, %{part_id: "0", delta: "moment."}),
        ev(:text_done, %{part_id: "msg_1-text", text: "One moment."}),
        completed("c2", "read", %{}),
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

    assert [%{kind: :text}, %{kind: :tool}] =
             card
             |> Activity.drop_trailing_text()
             |> Activity.to_payload()
             |> Activity.from_payload()
  end

  test "a payload round trip keeps the rows, never the details; first-version payloads still load" do
    card =
      Activity.fold_all([
        ev(:text_done, %{part_id: "t", text: "Running the tests."}),
        started("c1", "bash", %{"command" => "mix test"}, %{at: 1_000}),
        ev(:tool_completed, %{
          call_id: "c1",
          tool: "bash",
          status: :error,
          input: %{"command" => "mix test"},
          output: "boom",
          exit_code: 1,
          at: 3_000
        }),
        ev(:step_completed, %{part_id: "s1", tokens: %{input: 7}}),
        completed("c2", "edit", %{"filePath" => "/r/a.ex"}, %{adds: 2, dels: 1})
      ])

    payload = Activity.to_payload(card)

    assert [
             %{"kind" => "text", "category" => "note", "step" => 0},
             %{
               "key" => "c1",
               "kind" => "tool",
               "status" => "error",
               "category" => "shell",
               "command" => "mix test",
               "exit_code" => 1,
               "duration_ms" => 2_000,
               "fact" => "exit 1"
             } = shell,
             %{"key" => "c2", "category" => "edit", "adds" => 2, "dels" => 1, "step" => 1}
           ] = payload

    refute Map.has_key?(shell, "output")
    assert Jason.encode!(payload)

    meta = Activity.meta_payload(card)

    assert %{
             "v" => 2,
             "tallies" => %{"shell" => 1, "edit" => 1, "errors" => 1},
             "dropped" => 0,
             "steps" => [7],
             "files" => [%{"path" => "/r/a.ex", "adds" => 2, "dels" => 1}]
           } = meta

    assert %{"c1" => %{"output" => "boom"}} = Activity.details_payload(card)

    restored =
      Activity.card_from_payload(%{"activity" => payload, "activity_meta" => meta, "tools" => 2})

    assert restored.version == 2
    assert restored.tallies == %{shell: 1, edit: 1, errors: 1}

    assert [%{category: :note}, %{exit_code: 1, duration_ms: 2_000}, %{fact: "+2 −1"}] =
             restored.entries

    assert restored.details == %{}

    # first-version rows: no categories or durations, unknown values normalised
    v1 =
      Activity.card_from_payload(%{
        "tools" => 1,
        "files" => ["/r/lib/a.ex"],
        "activity" => [
          %{"key" => "c1", "kind" => "tool", "status" => "ok", "label" => "Read lib/a.ex"},
          %{"kind" => "bogus", "status" => 3}
        ]
      })

    assert v1.version == 1

    assert [%{category: :read, duration_ms: nil}, %{kind: :tool, status: :ok, key: "1"}] =
             v1.entries

    assert [%{path: "/r/lib/a.ex"}] = v1.files
    assert Activity.from_payload(nil) == []
  end

  test "the card's verb follows the latest running tool, and the current call is its row" do
    assert Activity.verb(Activity.new()) == "thinking"
    assert Activity.current(Activity.new()) == nil

    running = fn tool, input ->
      Activity.fold_all([ev(:tool_started, %{call_id: "c", tool: tool, input: input})])
    end

    assert Activity.verb(running.("read", %{"filePath" => "a.ex"})) == "researching"
    assert %{label: "a.ex"} = Activity.current(running.("read", %{"filePath" => "a.ex"}))
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
    assert Activity.current(done) == nil
  end
end
