defmodule Canopy.ClaudeCode.TranscriptTest do
  # The index is one process for the app; keep its cache to this test's files.
  use ExUnit.Case, async: false

  alias Canopy.ClaudeCode.{Transcript, TranscriptIndex}

  @dir Path.expand("../../support/claude_code_fixtures/transcripts", __DIR__)
  @basic "aaaaaaaa-0000-4000-8000-000000000001"
  @compacted "aaaaaaaa-0000-4000-8000-000000000002"
  @partial "aaaaaaaa-0000-4000-8000-000000000003"
  @image "aaaaaaaa-0000-4000-8000-000000000004"
  @repo "/tmp/canopy-repo"
  # the partial fixture's last line, whole
  @partial_line ~s({"parentUuid":"p-a1","isSidechain":false,"userType":"external","entrypoint":"sdk-cli","cwd":"/tmp/canopy-repo","sessionId":"aaaaaaaa-0000-4000-8000-000000000003","version":"2.1.266","gitBranch":"main","uuid":"p-a2","timestamp":"2026-10-02T11:00:02.000Z","type":"assistant","requestId":"req_msg_p2","apiBlockIndex":0,"effort":"low","message":{"model":"claude-sonnet-5","id":"msg_p2","type":"message","role":"assistant","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":10},"content":[{"type":"text","text":"All green."}]}})

  defp read(sid, opts \\ [], dir \\ @dir),
    do: Transcript.read(dir, %{engine_session_id: sid, directory: @repo}, opts)

  defp kinds(page), do: Enum.map(page.entries, & &1.kind)

  describe "locate/3" do
    test "finds the computed folder first" do
      assert {:ok, path} = Transcript.locate(@dir, @basic, @repo)
      assert path == Path.join([@dir, "projects", "-tmp-canopy-repo", @basic <> ".jsonl"])
    end

    test "looks in every project folder when the computed one misses" do
      # the stored path and the folder disagree (a moved repository, or APFS case)
      assert {:ok, path} = Transcript.locate(@dir, @compacted, @repo)
      assert path =~ "-srv-moved-canopy-repo"
      assert {:ok, ^path} = Transcript.locate(@dir, @compacted, nil)
    end

    test "rejects ids that are not UUIDs, and files that name another session" do
      assert Transcript.locate(@dir, "../../../etc/passwd", @repo) == {:error, :not_found}
      assert Transcript.locate(@dir, "ses_abc", @repo) == {:error, :not_found}

      assert Transcript.locate(@dir, "aaaaaaaa-0000-4000-8000-000000000005", nil) ==
               {:error, :not_found}

      assert Transcript.locate(@dir, "aaaaaaaa-0000-4000-8000-0000000000ff", @repo) ==
               {:error, :not_found}

      assert Transcript.locate(nil, @basic, @repo) == {:error, :not_found}
    end

    test "a missing file or config dir reads as not found" do
      assert read("aaaaaaaa-0000-4000-8000-0000000000ff") == {:error, :not_found}
      assert read(@basic, [], "/nonexistent/claude") == {:error, :not_found}
    end

    test "encodes a directory the way Claude Code names its folders" do
      assert Transcript.encode("/Users/me/canopy_all/canopy") == "-Users-me-canopy-all-canopy"
    end
  end

  describe "read/3" do
    test "maps each line kind and drops attachments and bookkeeping" do
      {:ok, page} = read(@basic)

      assert kinds(page) == [
               :prompt,
               :text,
               :thinking_hidden,
               :tool,
               :step,
               :tool,
               :step,
               :text,
               :step,
               :prompt,
               :text,
               :step
             ]

      assert page.total == 8
      assert page.before == nil
      refute page.newer?

      [prompt | _] = page.entries
      assert prompt.text =~ "Message ID: msg_basic1"
      assert prompt.at == ~U[2026-10-01 10:00:01.000Z]

      # session_context (the user's email) never becomes an entry
      refute Enum.any?(page.entries, &(&1.text && &1.text =~ "example.com"))
    end

    test "pairs a tool call with its result, its status and duration" do
      {:ok, page} = read(@basic)
      [bash, read] = Enum.filter(page.entries, &(&1.kind == :tool))

      assert bash.tool.name == "Bash"
      assert bash.tool.title == "Show the MCP config"
      assert bash.tool.status == :ok
      assert bash.tool.duration_ms == 1300
      assert bash.tool.input =~ ~s("command": "cat .canopy/mcp.json && env")
      assert bash.tool.output =~ "Authorization"
      assert bash.message_id == "msg_01A"

      assert read.tool.status == :error
      assert read.tool.output == "File does not exist."
      assert read.tool.title == "Read lib/billing/payments.ex"
    end

    test "a tool call on a page finds its result wherever it falls" do
      # the Bash call's result line comes after the call, on neither page
      {:ok, %{entries: [_ | _]} = tail} = read(@basic, limit: 4)
      {:ok, page} = read(@basic, limit: 1, before: tail.before)

      assert [%{kind: :tool, tool: %{name: "Bash", status: :ok} = tool}, %{kind: :step}] =
               page.entries

      assert tool.output =~ "mcpServers"
    end

    test "one step per message id, after its last line" do
      {:ok, page} = read(@basic)
      steps = Enum.filter(page.entries, &(&1.kind == :step))

      assert Enum.map(steps, & &1.message_id) == ["msg_01A", "msg_01B", "msg_01C", "msg_02A"]
      [first | _] = steps
      assert first.step.model == "claude-sonnet-5"
      assert first.step.tokens["input"] == 10
      assert first.step.tokens["cache"]["read"] == 2000
      assert first.step.cost == nil

      index = Enum.find_index(page.entries, &(&1.id == "step-msg_01A"))
      assert Enum.at(page.entries, index - 1).kind == :tool
    end

    test "empty thinking is a hidden thought" do
      {:ok, page} = read(@basic)
      assert %{kind: :thinking_hidden, text: nil} = Enum.at(page.entries, 2)
    end

    test "splits the system prompt into Canopy's text and the engine's, once per change" do
      {:ok, page} = read(@basic)
      assert [%{canopy: canopy, engine: [_, _]} = prompt] = page.system_prompts
      assert canopy =~ "You are Backend (@backend)"
      assert prompt.at == ~U[2026-10-01 10:00:01.020Z]

      {:ok, compacted} = read(@compacted)
      assert [first, second] = compacted.system_prompts
      refute first.canopy =~ "logged"
      assert second.canopy =~ "logged"
    end

    test "builds a compaction with its summary; the engine's own lines are notes" do
      {:ok, page} = read(@compacted)

      assert kinds(page) == [
               :prompt,
               :text,
               :step,
               :compaction,
               :engine_note,
               :engine_note,
               :engine_note,
               :prompt,
               :text,
               :step
             ]

      compaction = Enum.find(page.entries, &(&1.kind == :compaction))

      assert compaction.compaction == %{
               trigger: :manual,
               pre_tokens: 118_000,
               post_tokens: 9_000,
               summary:
                 "This session is being continued from a previous conversation. Summary: the retry worker was fixed."
             }

      assert page.compactions == 1
      assert Enum.all?(Enum.filter(page.entries, &(&1.kind == :engine_note)), & &1.synthetic?)
    end

    test "an image in a prompt is metadata only" do
      {:ok, page} = read(@image)
      [prompt | _] = page.entries

      assert prompt.text == "What does this screenshot show?"
      assert prompt.attachments == [%{kind: :image, name: nil, mime: "image/png"}]
      refute inspect(page) =~ "iVBORw0KGgo"
    end

    test "around a message id lands on its turn's prompt" do
      {:ok, page} = read(@basic, around: {:message_id, "msg_01C"}, limit: 2)
      assert [%{kind: :prompt, id: "b-prompt-1"} | _] = page.entries
      assert page.before == nil
      assert page.newer?

      {:ok, second} = read(@basic, around: {:message_id, "msg_02A"})
      assert [%{id: "b-prompt-2"} | _] = second.entries
      assert second.before
    end

    test "an unknown message id falls back to a time, then to the newest page" do
      {:ok, page} =
        read(@basic, around: {:message_id, "result"}, fallback_at: ~U[2026-10-01 10:04:00Z])

      assert [%{id: "b-prompt-2"} | _] = page.entries

      {:ok, tail} = read(@basic, around: {:message_id, "nope"}, limit: 1)
      assert [%{kind: :text, text: "You're welcome."}, %{kind: :step}] = tail.entries
    end

    test "around a time lands on the first line at or after it" do
      {:ok, page} = read(@basic, around: {:at, ~U[2026-10-01 10:00:03Z]}, limit: 1)
      assert [%{kind: :tool, tool: %{name: "Read"}}, %{kind: :step}] = page.entries
    end

    test "pages back with before and forward with after" do
      {:ok, tail} = read(@basic, limit: 2)
      assert [%{id: "b-prompt-2"}, %{kind: :text}, %{kind: :step}] = tail.entries
      refute tail.newer?

      {:ok, older} = read(@basic, limit: 2, before: tail.before)
      assert [%{kind: :tool}, %{kind: :step}, %{kind: :text}, %{kind: :step}] = older.entries

      {:ok, newer} = read(@basic, limit: 50, after: older.after)
      assert [%{id: "b-prompt-2"} | _] = newer.entries

      {:ok, none} = read(@basic, after: tail.after)
      assert none.entries == []
      assert none.after == tail.after
    end
  end

  describe "a file still being written" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "canopy-transcript-#{System.unique_integer([:positive])}")

      folder = Path.join([dir, "projects", "-tmp-canopy-repo"])
      File.mkdir_p!(folder)

      File.cp!(
        Path.join([@dir, "projects", "-tmp-canopy-repo", @partial <> ".jsonl"]),
        Path.join(folder, @partial <> ".jsonl")
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, path: Path.join(folder, @partial <> ".jsonl")}
    end

    test "skips the partial last line, then indexes only what was appended", %{
      dir: dir,
      path: path
    } do
      {:ok, page} = read(@partial, [], dir)
      assert [:prompt, :text, :step] = kinds(page)

      first = TranscriptIndex.cached(path)
      assert tuple_size(first.lines) == 2
      assert first.offset < File.stat!(path).size

      # the turn finishes writing its line
      partial = File.read!(path) |> String.split("\n") |> List.last()
      assert String.starts_with?(@partial_line, partial)

      rest =
        binary_part(
          @partial_line,
          byte_size(partial),
          byte_size(@partial_line) - byte_size(partial)
        ) <> "\n"

      File.write!(path, rest, [:append])

      {:ok, page} = read(@partial, [], dir)
      assert [:prompt, :text, :step, :text, :step] = kinds(page)
      assert List.last(Enum.filter(page.entries, &(&1.kind == :text))).text == "All green."

      grown = TranscriptIndex.cached(path)
      assert tuple_size(grown.lines) == 3
      assert grown.offset == File.stat!(path).size
      # the earlier lines were kept, not read again
      assert Tuple.to_list(grown.lines) |> Enum.take(2) == Tuple.to_list(first.lines)
    end
  end
end
