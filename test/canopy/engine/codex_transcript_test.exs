defmodule Canopy.Engine.CodexTranscriptTest do
  @moduledoc "§9: a Codex thread's history as transcript pages, against the fake binary."
  use ExUnit.Case, async: false

  alias Canopy.Codex.Transcript
  alias Canopy.Engine.TranscriptEntry, as: Entry

  @moduletag :tmp_dir
  @fixture Path.expand("../../support/codex_fixtures/turns-list.jsonl", __DIR__)

  defp fixture_turns do
    @fixture
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find(&String.starts_with?(&1, ~s({"send":)))
    |> String.replace("$ID", "1")
    |> JSON.decode!()
    |> get_in(["send", "result", "data"])
    # the fixture answers sortDirection "desc", newest first
    |> Enum.reverse()
  end

  defp binary, do: Keyword.fetch!(Application.get_env(:canopy, :codex), :binary)

  setup do
    previous = System.get_env("FAKE_CODEX_SCRIPT")

    on_exit(fn ->
      if previous,
        do: System.put_env("FAKE_CODEX_SCRIPT", previous),
        else: System.delete_env("FAKE_CODEX_SCRIPT")
    end)

    :ok
  end

  describe "entries/2" do
    test "the fixture's turns, oldest first" do
      entries = Transcript.entries(fixture_turns(), "/repo")

      assert Enum.map(entries, &{&1.id, &1.kind}) == [
               {"cx-t1-u1", :prompt},
               {"cx-t1-r1", :reasoning},
               {"cx-t1-c1", :tool},
               {"cx-t1-a1", :text},
               {"cx-t2-u2", :prompt},
               {"cx-t2-k1", :compaction},
               {"cx-t2-a2", :text}
             ]

      [prompt, reasoning, tool, text, prompt2, compaction, text2] = entries

      assert prompt.text == "Fix the bug"
      assert prompt.steered? == false
      assert prompt.message_id == "t1"
      assert prompt.at == DateTime.from_unix!(1_792_379_067)
      assert prompt.attachments == []

      assert reasoning.text == "Looking at the code"

      assert %Entry{
               tool: %{
                 name: "bash",
                 call_id: "c1",
                 title: "mix test",
                 input: "mix test",
                 output: "ok\n",
                 truncated?: false,
                 status: :ok,
                 duration_ms: 50
               }
             } = tool

      assert text.text == "Fixed."
      assert prompt2.text == "Thanks"
      assert prompt2.steered? == false
      assert prompt2.message_id == "t2"

      assert compaction.compaction == %{
               trigger: :auto,
               pre_tokens: nil,
               post_tokens: nil,
               summary: nil
             }

      assert text2.text == "You're welcome."
    end

    test "a second userMessage in a turn was steered in; empty reasoning is hidden thinking" do
      turns = [
        %{
          "id" => "t",
          "items" => [
            %{
              "type" => "userMessage",
              "id" => "u1",
              "content" => [%{"type" => "text", "text" => "a"}]
            },
            %{"type" => "reasoning", "id" => "r", "summary" => []},
            %{
              "type" => "userMessage",
              "id" => "u2",
              "content" => [
                %{"type" => "text", "text" => "b"},
                %{"type" => "localImage", "path" => "/tmp/x/shot.png"}
              ]
            }
          ]
        }
      ]

      assert [first, hidden, steered] = Transcript.entries(turns)
      refute first.steered?
      assert hidden.kind == :thinking_hidden
      assert steered.steered?
      assert steered.attachments == [%{kind: :image, name: "shot.png", mime: nil}]
    end

    test "file changes, MCP calls, web searches and declined commands" do
      turns = [
        %{
          "id" => "t",
          "items" => [
            %{
              "type" => "fileChange",
              "id" => "f",
              "status" => "completed",
              "changes" => [
                %{"path" => "/repo/lib/a.ex", "kind" => %{"type" => "add"}, "diff" => "x\n"}
              ]
            },
            %{
              "type" => "mcpToolCall",
              "id" => "m",
              "server" => "canopy",
              "tool" => "message_send",
              "status" => "completed",
              "arguments" => %{"text" => "hi"},
              "result" => %{"content" => [%{"type" => "text", "text" => "posted"}]}
            },
            %{"type" => "webSearch", "id" => "w", "query" => "elixir"},
            %{
              "type" => "commandExecution",
              "id" => "c",
              "command" => "/bin/zsh -lc 'rm -rf /'",
              "status" => "declined"
            },
            %{"type" => "agentMessage", "id" => "empty", "text" => ""}
          ]
        }
      ]

      assert [file, mcp, web, declined] = Transcript.entries(turns, "/repo")

      assert file.tool.name == "apply_patch"
      assert file.tool.title == "lib/a.ex"
      assert file.tool.output == "--- /dev/null\n+++ lib/a.ex\n+x"
      assert file.tool.status == :ok

      assert mcp.tool.name == "mcp__canopy__message_send"
      assert mcp.tool.output == "posted"

      assert web.tool.name == "websearch"
      assert web.tool.title == "elixir"

      assert declined.tool.status == :denied
      assert declined.tool.input == "rm -rf /"
    end
  end

  describe "fetch_turns/2" do
    # a thread of `n` turns, answered newest first in pages of the asked size
    defp thread(n, test_pid) do
      fn "thread/turns/list", params ->
        send(test_pid, {:asked, params})
        assert params["sortDirection"] == "desc"
        newest_first = Enum.map(n..1//-1, &%{"id" => "t#{&1}"})
        start = String.to_integer(params["cursor"] || "0")
        page = Enum.slice(newest_first, start, params["limit"])
        next = if start + length(page) < n, do: Integer.to_string(start + length(page))
        {:ok, %{"data" => page, "nextCursor" => next}}
      end
    end

    test "a short thread comes back whole, oldest first" do
      assert {:ok, turns} = Transcript.fetch_turns(thread(3, self()), "thr")
      assert Enum.map(turns, & &1["id"]) == ["t1", "t2", "t3"]
    end

    test "past 500 turns the newest are kept and the oldest dropped" do
      assert {:ok, turns} = Transcript.fetch_turns(thread(620, self()), "thr")
      assert length(turns) == 500
      assert hd(turns)["id"] == "t121"
      assert List.last(turns)["id"] == "t620"
    end
  end

  describe "read/3 against the fake" do
    test "the whole thread, paged", %{tmp_dir: dir} do
      System.put_env("FAKE_CODEX_SCRIPT", @fixture)
      ref = %{engine_session_id: "thr-1", directory: dir}

      assert {:ok, page} = Transcript.read([binary: binary()], ref, [])
      assert page.total == 7
      assert page.compactions == 1
      assert page.system_prompts == []
      assert length(page.entries) == 7
      assert page.before == nil
      refute page.newer?

      assert {:ok, page} = Transcript.read([binary: binary()], ref, limit: 3)
      assert Enum.map(page.entries, & &1.id) == ["cx-t2-u2", "cx-t2-k1", "cx-t2-a2"]
      assert page.before == "cx-t2-u2"

      assert {:ok, page} = Transcript.read([binary: binary()], ref, limit: 3, before: page.before)
      assert Enum.map(page.entries, & &1.id) == ["cx-t1-r1", "cx-t1-c1", "cx-t1-a1"]
    end

    test "a thread Codex has no rollout for is not_found", %{tmp_dir: dir} do
      script = Path.join(dir, "not-found.jsonl")

      File.write!(script, """
      {"await":"thread/turns/list"}
      {"send":{"id":$ID,"error":{"code":-32600,"message":"no rollout found for thread id x"}}}
      """)

      System.put_env("FAKE_CODEX_SCRIPT", script)
      ref = %{engine_session_id: "x", directory: dir}
      assert Transcript.read([binary: binary()], ref, []) == {:error, :not_found}
    end

    test "any other error is unreachable", %{tmp_dir: dir} do
      script = Path.join(dir, "boom.jsonl")

      File.write!(script, """
      {"await":"thread/turns/list"}
      {"send":{"id":$ID,"error":{"code":-32603,"message":"internal error"}}}
      """)

      System.put_env("FAKE_CODEX_SCRIPT", script)
      ref = %{engine_session_id: "x", directory: dir}
      assert Transcript.read([binary: binary()], ref, []) == {:error, :unreachable}
    end

    test "a binary that can't start is unreachable", %{tmp_dir: dir} do
      ref = %{engine_session_id: "x", directory: dir}
      assert Transcript.read([binary: "/nonexistent/codex"], ref, []) == {:error, :unreachable}
    end
  end
end
