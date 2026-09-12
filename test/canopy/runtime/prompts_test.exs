defmodule Canopy.Runtime.PromptsTest do
  use Canopy.DataCase, async: false

  alias Canopy.Runtime.Prompts

  test "system prompt substitutes identity and appends the role prompt" do
    agent = %{
      name: "backend",
      display_name: "Backend",
      role: "Primary implementation",
      system_prompt: "Prefer small diffs."
    }

    text = Prompts.system(agent, %{name: "payments"}, %{id: "r1", path: "/repo"})
    assert text =~ "You are Backend (@backend)"
    assert text =~ "channel #payments"
    assert text =~ "/repo"
    assert text =~ "Role: Primary implementation"
    assert text =~ "/repo/.canopy/notes/backend.md"
    assert text =~ "This is the only repository registered in Canopy."

    with_others =
      Prompts.system(agent, %{name: "payments"}, %{id: "r1", path: "/repo"}, [
        %{id: "r1", name: "billing", path: "/repo"},
        %{id: "r2", name: "calculator_app", path: "/other"}
      ])

    assert with_others =~ "Other repositories registered in Canopy: calculator_app (/other)."
    assert with_others =~ "canopy_channel_create or canopy_dm_start"
    assert text =~ "/repo/.canopy/NOTES.md"
    # the clock is not in the system text (it would spoil the cacheable prefix)
    refute text =~ "The time now is"
    assert String.ends_with?(text, "Prefer small diffs.")
    refute text =~ "{{"
  end

  test "system prompt works without a role prompt" do
    agent = %{name: "x", display_name: nil, role: nil, system_prompt: nil}
    text = Prompts.system(agent, %{name: "c"}, %{id: "r", path: "/r"})
    assert text =~ "You are x (@x)"
    refute text =~ "{{"
  end

  test "wake prompts never contain message bodies, only ids" do
    text =
      Prompts.new_message(%{channel: "c", sender: "Steven", message_id: "msg_42", thread?: false})

    assert text =~ "msg_42"
    refute text =~ "message body"
    refute text =~ "Members of"

    with_members =
      Prompts.new_message(%{
        channel: "c",
        sender: "Steven",
        message_id: "msg_42",
        thread?: false,
        members: ["backend", "reviewer"]
      })

    assert with_members =~ "Members of #c: @backend, @reviewer"
  end

  test "the system prompt carries the agent's memory" do
    agent =
      Canopy.Fixtures.agent_fixture(%{
        name: "mem",
        display_name: "Mem",
        role: "r",
        system_prompt: nil
      })

    text = Prompts.system(agent, %{name: "c"}, %{id: "r", path: "/r"})
    assert text =~ "Your memory across repositories is empty so far."

    {:ok, _} = Canopy.Memory.put(agent.id, "## 2026-09-10\n- the worker is payments.py")
    text = Prompts.system(agent, %{name: "c"}, %{id: "r", path: "/r"})
    assert text =~ "the worker is payments.py"
    assert text =~ "canopy_memory_write"
  end

  test "scheduled prompts tell the agent not to poll for a human" do
    text =
      Prompts.scheduled(%{
        channel: "c",
        schedule_id: "sch_1",
        instruction: "check",
        kind: "recurring"
      })

    assert text =~ "do not keep checking"
    assert text =~ "canopy_schedule_cancel"
    assert text =~ "The user's reply wakes you"
  end

  test "wake prompts inline short messages, point long ones at message_get, and end with the time" do
    short =
      Prompts.new_message(%{
        channel: "c",
        sender: "Steven",
        message_id: "msg_1",
        thread?: false,
        body: "Why is it slow?"
      })

    assert short =~ "Message text:\nWhy is it slow?"
    assert short =~ ~r/The time now is \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\n\z/

    long =
      Prompts.new_message(%{
        channel: "c",
        sender: "Steven",
        message_id: "msg_1",
        thread?: false,
        body: String.duplicate("x", 1_500)
      })

    assert long =~ "The message is long (1500 chars): read it with canopy_message_get"
    refute long =~ String.duplicate("x", 100)

    assert Prompts.scheduled(%{channel: "c", schedule_id: "s", instruction: "i", kind: "once"}) =~
             "The time now is"

    assert Prompts.delegation(%{channel: "c", from: "@a", delegation_id: "d", task: "t"}) =~
             "The time now is"
  end

  test "new_message lists attachments and how each one reaches the agent" do
    doc = fn id, name, kind, size ->
      %Canopy.Documents.Document{id: id, filename: name, kind: kind, byte_size: size}
    end

    plan = [
      {doc.("doc_1", "shot.png", "image", 2_048), :part},
      {doc.("doc_2", "report.md", "text", 300), :part},
      {doc.("doc_3", "dump.csv", "text", 5_000_000), :path},
      {doc.("doc_4", "huge.png", "image", 9_000_000), :path},
      {doc.("doc_5", "spec.pdf", "pdf", 10_000), :path}
    ]

    text =
      Prompts.new_message(%{
        channel: "payments",
        sender: "Steven",
        message_id: "msg_1",
        thread?: false,
        body: "see attached",
        attachments: plan
      })

    assert text =~ "Attachments on this message:"

    assert text =~
             "- doc_1 shot.png (image, 2 KB) — attached to this prompt as an image; also at .canopy/files/doc_1-shot.png"

    assert text =~
             "- doc_2 report.md (text, 300 B) — attached to this prompt as text; also at .canopy/files/doc_2-report.md"

    assert text =~
             "- doc_3 dump.csv (text, 4.8 MB) — not attached; read it at .canopy/files/doc_3-dump.csv or with canopy_document_get"

    assert text =~
             "- doc_4 huge.png (image, 8.6 MB) — too large to attach; at .canopy/files/doc_4-huge.png"

    assert text =~ "- doc_5 spec.pdf (pdf, 9 KB) — at .canopy/files/doc_5-spec.pdf"
    assert text =~ "canopy_documents_list"

    plain =
      Prompts.new_message(%{
        channel: "p",
        sender: "S",
        message_id: "m",
        thread?: false,
        body: "hi"
      })

    refute plain =~ "Attachments"
  end
end
