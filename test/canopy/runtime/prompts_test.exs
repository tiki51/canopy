defmodule Canopy.Runtime.PromptsTest do
  use Canopy.DataCase, async: false

  alias Canopy.Runtime.Prompts

  test "the system prompt tells agents to take a lock before the test suite and never broker one" do
    text =
      Prompts.system(
        %{name: "backend", display_name: nil, role: nil, system_prompt: nil},
        %{name: "p"},
        %{
          id: "r",
          path: "/r"
        }
      )

    assert text =~ "call `canopy_lock_acquire` (name `tests`"
    assert text =~ "If you are queued, end your turn"
    assert text =~ "Never announce, pass, or broker locks in messages."
  end

  test "a lock grant names the lock, the repository, the reason, and when it frees itself" do
    repository = %{name: "acme-billing"}

    tests = %{
      name: "tests",
      reason: "precommit",
      hold_across_turns: false,
      repository: repository
    }

    text = Prompts.lock_granted([tests], standalone?: true)

    assert text =~
             "You now hold the `tests` lock in acme-billing (you asked for it: \"precommit\"). Do the work that needs it now. It is released automatically when this turn ends; call canopy_lock_release sooner if you finish early."

    assert text =~ "The time now is"

    e2e = %{name: "e2e", reason: nil, hold_across_turns: true, repository: repository}
    both = Prompts.lock_granted([tests, e2e])

    assert both =~
             "You now hold these locks in acme-billing: `tests` (you asked for it: \"precommit\"), `e2e`."

    assert both =~ "stays yours until you call canopy_lock_release"
    refute both =~ "The time now is"
  end

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
    # a repository with no notes yet gets told so, not a broken path
    assert text =~ "The shared notes for this repository are empty so far."
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

  test "each agent is told its own execution mode, not the channel's" do
    build = Prompts.system(agent_with("build"), %{name: "c"}, %{id: "r", path: "/r"})
    assert build =~ "you have write access and are expected to do the work yourself"
    assert build =~ "that describes their session, not yours"
    refute build =~ "read-only"

    plan = Prompts.system(agent_with("plan"), %{name: "c"}, %{id: "r", path: "/r"})
    assert plan =~ "Your session is read-only"
    assert plan =~ "never tell the channel that execution is blocked"
    refute plan =~ "you have write access"

    # a custom OpenCode agent: Canopy cannot know its reach, but a teammate's
    # limits still must not be read as the channel's
    custom = Prompts.system(agent_with("reviewer-ro"), %{name: "c"}, %{id: "r", path: "/r"})
    assert custom =~ "A teammate's limits are their own"
    refute custom =~ "Your session"

    for text <- [build, plan, custom], do: refute(text =~ "{{")
  end

  test "the preamble names the engine and its way of identifying the agent" do
    {channel, repository} = {%{name: "general"}, %{path: "/repo"}}

    opencode = Prompts.system(agent_with("build"), channel, repository)
    assert opencode =~ "Your OpenCode session is your private workbench"
    assert opencode =~ "Never set `canopy_session_id`"

    claude =
      Prompts.system(Map.put(agent_with("build"), :engine, "claude_code"), channel, repository)

    assert claude =~ "Your Claude Code session is your private workbench"
    assert claude =~ "Your identity travels with every Canopy tool call"
    assert claude =~ "AskUserQuestion"
    # an unanswered question comes back later as a new message
    assert claude =~ "end your turn then, and their answer reaches you later as a new message"
    refute claude =~ "canopy_session_id"
  end

  test "a late answer is a message mentioning the agent that names each question and answer" do
    one = [%{"question" => "Include the attempt number?", "options" => [%{"label" => "Yes"}]}]

    assert Prompts.answer_message("pm", one, [["Yes"]]) ==
             ~s(@pm Answer to your question "Include the attempt number?": Yes)

    two = one ++ [%{"question" => "Anything else?", "options" => []}]
    text = Prompts.answer_message("pm", two, [["Yes"], ["keep it short", "and fast"]])
    assert text =~ "@pm Answers to your questions:"
    assert text =~ ~s(- "Include the attempt number?": Yes)
    assert text =~ ~s(- "Anything else?": keep it short, and fast)

    declined = Prompts.answer_message("pm", one, [[]], as_message?: true)
    assert declined =~ ~s[your question "Include the attempt number?": (no answer)\n]
    assert declined =~ "reported the question as declined"
    refute declined =~ "(delegation"
  end

  test "a late approval is a message saying what was approved and to do it now" do
    assert Prompts.approval_message("pm", %{permission: "Bash", patterns: ["make test"]}, :always) ==
             "@pm Approved: Bash make test (always). You can do it now."

    assert Prompts.approval_message("pm", %{permission: "edit", patterns: []}, :once) ==
             "@pm Approved: edit (once). You can do it now."
  end

  test "the pending-delegation reminder lists each delegation and how to report it" do
    assert Prompts.pending_delegations("payments", []) == ""

    one = Prompts.pending_delegations("payments", [%{id: "dl_1", from: "@pm", description: "a"}])
    assert one =~ ~s{You have a pending delegation in #payments:\n- dl_1 from @pm ("a")}
    assert one =~ ~s(canopy_task_update with status "completed", a result, and its delegation id)

    two =
      Prompts.pending_delegations("payments", [
        %{id: "dl_1", from: "@pm", description: "a"},
        %{id: "dl_2", from: "Steven", description: "line one\nline two"}
      ])

    assert two =~ "You have pending delegations in #payments:"
    assert two =~ ~s{- dl_2 from Steven ("line one line two")}
  end

  defp agent_with(opencode_agent) do
    %{
      name: "x",
      display_name: "X",
      role: "r",
      system_prompt: nil,
      opencode_agent: opencode_agent
    }
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
    refute with_members =~ "Teams here"
  end

  test "the wake names whole teams; the system text never mentions them" do
    agent = Canopy.Fixtures.agent_fixture(%{name: "teamless"})
    system = Prompts.system(agent, %{name: "c"}, %{id: "r", path: "/r"})

    team = Canopy.Fixtures.team_fixture([agent], name: "crew")

    wake =
      Prompts.new_message(%{
        channel: "c",
        sender: "Steven",
        message_id: "msg_42",
        thread?: false,
        members: ["teamless"],
        teams: [team.name]
      })

    assert wake =~ "Members of #c: @teamless\nTeams here: @crew.\n"
    assert Prompts.system(agent, %{name: "c"}, %{id: "r", path: "/r"}) == system
    refute system =~ "Teams here"
  end

  describe "playbooks" do
    defp system_text do
      Prompts.system(
        %{name: "pm", display_name: nil, role: nil, system_prompt: nil},
        %{name: "p"},
        %{id: "r", path: "/r"}
      )
    end

    test "{{playbooks}} lists the enabled playbooks in the system text, or says there are none" do
      assert "playbooks" in Prompts.preamble_variables()
      assert system_text() =~ "No playbooks are defined yet."

      assert system_text() =~
               "`canopy_playbooks_list` / `canopy_playbook_get` / `canopy_playbook_start`"

      {:ok, _} = Canopy.Playbooks.create(%{body: Canopy.Playbooks.bug_fix_text()})
      text = system_text()

      assert text =~
               "Playbooks you can run with canopy_playbook_start:\n- bug-fix — Reproduce, fix"

      # the list is part of the cacheable prefix: the same text twice
      assert text == system_text()
    end

    test "a custom preamble without the variable lists none" do
      {:ok, _} = Canopy.Playbooks.create(%{body: Canopy.Playbooks.bug_fix_text()})
      {:ok, _} = Canopy.Settings.update(%{collaboration_prompt: "You are {{name}}."})
      assert system_text() == "You are pm."
    end

    test "the in-progress note says where the run is, the owners, and the delegations" do
      args = %{
        playbook: "bug-fix",
        run_id: "pbr_1",
        status: "active",
        step: "fix",
        title: "Fix",
        position: 3,
        total: 6,
        round: 2,
        owners: ["@backend", "@frontend"],
        delegations: {2, 2}
      }

      text = Prompts.playbook_in_progress(args)

      assert text =~
               "Playbook in progress here: bug-fix (run pbr_1), step 3 of 6 \"Fix\" (round 2), owners @backend, @frontend; you coordinate it. All delegations for this step are done."

      assert Prompts.playbook_in_progress(%{args | status: "awaiting_approval"}) =~
               "is waiting for the user's approval"
    end
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
