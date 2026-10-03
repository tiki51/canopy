defmodule Canopy.OpenCode.TranscriptTest do
  use ExUnit.Case, async: true

  import Mox

  alias Canopy.Engine
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :verify_on_exit!

  @fixture Path.expand("../../support/opencode_fixtures/transcript_messages.json", __DIR__)
  @ref %{engine_session_id: "ses_transcript1", directory: "/tmp/canopy-repo"}

  defp messages, do: @fixture |> File.read!() |> JSON.decode!()

  defp read(opts \\ []) do
    Engine.OpenCode.transcript(nil, @ref, Keyword.put_new(opts, :base_url, "http://oc.test"))
  end

  defp stub_messages(result \\ nil) do
    expect(OC, :messages, fn "/tmp/canopy-repo", "ses_transcript1", [], opts ->
      assert opts[:base_url] == "http://oc.test"
      result || {:ok, messages()}
    end)
  end

  test "maps prompts, reasoning, text, tools, steps, compaction and errors" do
    stub_messages()
    {:ok, page} = read()

    assert Enum.map(page.entries, & &1.kind) == [
             :prompt,
             :reasoning,
             :text,
             :tool,
             :tool,
             :tool,
             :step,
             :text,
             :step,
             :compaction,
             :prompt,
             :engine_note,
             :tool,
             :engine_note
           ]

    [prompt, reasoning, text, read, bash, edit, step | _] = page.entries

    assert prompt.message_id == "msg_u1"
    assert prompt.text =~ "Message ID: msg_c1"
    assert prompt.attachments == [%{kind: :image, name: "shot.png", mime: "image/png"}]
    assert prompt.at == ~U[2025-10-01 10:00:00.000Z]

    assert reasoning.text == "The worker and the webhook both enqueue."
    assert reasoning.message_id == "msg_a1"
    assert text.text == "I'll read the worker first."

    assert read.tool.status == :ok
    assert read.tool.title == "lib/worker.ex"
    assert read.tool.duration_ms == 120
    assert read.tool.input =~ ~s("filePath": "/tmp/canopy-repo/lib/worker.ex")
    assert read.tool.output =~ "defmodule Worker"

    assert bash.tool.status == :error
    assert bash.tool.output =~ "exit 1"
    assert edit.tool.status == :denied

    assert step.step.cost == 0.0012
    assert step.step.model == "gpt-5-nano"
    assert step.step.files == ["/tmp/canopy-repo/lib/worker.ex"]
    assert step.message_id == "msg_a1"

    synthetic = Enum.at(page.entries, 7)
    assert synthetic.synthetic?

    compaction = Enum.find(page.entries, &(&1.kind == :compaction))
    assert compaction.compaction.trigger == :auto
    assert compaction.compaction.summary =~ "race on enqueue_charge"
    # the summary is the compaction's, not a text entry of its own
    refute Enum.any?(page.entries, &(&1.kind == :text and &1.text =~ "race on"))
    assert page.compactions == 1

    note = Enum.at(page.entries, 11)
    assert note.synthetic?
    assert List.last(page.entries).text == "Error: The operation was aborted."
    assert Enum.at(page.entries, 12).tool.status == :running

    # file bytes never come through
    refute inspect(page) =~ "base64"
  end

  test "a command that completed with a non-zero exit code failed" do
    message = %{
      "info" => %{"id" => "msg_x", "role" => "assistant", "time" => %{"created" => 1}},
      "parts" => [
        %{
          "id" => "prt_x",
          "type" => "tool",
          "tool" => "bash",
          "state" => %{
            "status" => "completed",
            "input" => %{"command" => "mix test"},
            "output" => "1 failure",
            "metadata" => %{"exit" => 1}
          }
        }
      ]
    }

    stub_messages({:ok, [message]})
    {:ok, %{entries: [entry]}} = read()
    assert entry.tool.status == :error
    assert entry.tool.output == "1 failure"
  end

  test "keeps one system prompt per change" do
    stub_messages()
    {:ok, page} = read()

    assert [first, second] = page.system_prompts
    assert first.canopy =~ "You are Backend"
    assert first.engine == nil
    refute first.canopy =~ "log every retry"
    assert second.canopy =~ "log every retry"
    assert second.at == ~U[2025-10-01 10:02:00.000Z]
  end

  test "pages locally with part ids as cursors" do
    stub_messages()
    {:ok, tail} = read(limit: 3)
    assert Enum.map(tail.entries, & &1.id) == ["prt_u3b", "prt_a3a", "msg_a3-error"]
    assert tail.before == "prt_u3b"
    refute tail.newer?

    stub_messages()
    {:ok, older} = read(limit: 2, before: tail.before)
    assert Enum.map(older.entries, & &1.id) == ["prt_u2a", "msg_u3"]
    assert older.newer?

    stub_messages()
    {:ok, newer} = read(after: older.after)
    assert hd(newer.entries).id == "prt_u3b"
  end

  test "around a message id lands on its turn's prompt" do
    stub_messages()
    {:ok, page} = read(around: {:message_id, "msg_a1"}, limit: 3)
    assert [%{id: "msg_u1", kind: :prompt} | _] = page.entries
    assert page.before == nil
  end

  test "a missing session is not found; a server that can't be reached is unreachable" do
    stub_messages({:error, {:http, 404, %{"name" => "NotFoundError"}}})
    assert read() == {:error, :not_found}

    stub_messages({:error, {:transport, :econnrefused}})
    assert read() == {:error, :unreachable}
  end
end
