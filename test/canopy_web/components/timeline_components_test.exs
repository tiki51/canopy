defmodule CanopyWeb.TimelineComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CanopyWeb.TimelineComponents

  defp render_body(body, opts \\ []) do
    assigns = %{
      body: body,
      inline: Keyword.get(opts, :inline, false),
      mentions: Keyword.get(opts, :mentions, ["reviewer"])
    }

    rendered_to_string(~H"""
    <TimelineComponents.message_text body={@body} inline={@inline} mentions={@mentions} />
    """)
  end

  defp render_turn(event, opts \\ []) do
    assigns = %{event: event, root: opts[:root], activity: opts[:activity] || %{}}

    rendered_to_string(~H"""
    <TimelineComponents.timeline_item
      id="e"
      event={@event}
      names={%{"agt_1" => "backend"}}
      user_name="Priya"
      root={@root}
      activity={@activity}
    />
    """)
  end

  defp text_of(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  test "avatar initials switch to navy where white would fail contrast" do
    assert TimelineComponents.initial_color("#1e40af") == "white"
    assert TimelineComponents.initial_color("#7c3aed") == "white"
    assert TimelineComponents.initial_color("#ca8a04") == "#0B1834"
    assert TimelineComponents.initial_color("#0891B2") == "#0B1834"
    # Mid grey fails AA with both; white (4.3:1) still beats navy (4.2:1).
    assert TimelineComponents.initial_color("#7a7a7a") == "white"
    assert TimelineComponents.initial_color("not a colour") == "white"
  end

  test "markdown renders lists, code, tables and line breaks" do
    html =
      render_body("""
      @Steven

      Prioritize these:
      1. Add idempotency (`payments.py:21`)
      2. One retry owner

      ```python
      def charge(): pass
      ```

      | option | cost |
      |---|---|
      | a | low |

      first line
      second line
      """)

    assert html =~ ~s(class="message-body break-words">)
    assert html =~ ~s(<ol>\n<li>Add idempotency \(<code>payments.py:21</code>\))
    assert html =~ ~s(<pre><code class="language-python">def charge\(\): pass\n</code></pre>)
    assert html =~ ~s(<table>) and html =~ ~s(<td>low</td>)
    assert html =~ ~s(first line<br />\nsecond line)
  end

  test "mentions are highlighted outside code and left alone inside it" do
    html = render_body("ping @reviewer, not `@reviewer` and not\n```\n@reviewer\n```")

    assert html =~
             ~s(ping <span class="rounded bg-secondary/10 px-1 font-medium text-secondary">@reviewer</span>, not <code>@reviewer</code>)

    assert html =~ ~s(<pre><code>@reviewer\n</code></pre>)
    assert length(String.split(html, "<span class=")) == 2
  end

  test "raw html is escaped and unsafe links are neutralised" do
    html = render_body("<script>alert(1)</script> <b>bold?</b> [x](javascript:alert(1))")

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<b>"
    refute html =~ ~s(href="javascript)
    refute html =~ "<a "
  end

  test "links open in a new tab" do
    html = render_body("see https://example.com/docs")

    assert html =~
             ~s(<a target="_blank" rel="noopener noreferrer" href="https://example.com/docs">https://example.com/docs</a>)
  end

  test "inline bodies keep the text as written and highlight mentions" do
    html = render_body("handed off to @reviewer: **not bold**", inline: true)

    assert html =~
             ~s(handed off to <span class="rounded bg-secondary/10 px-1 font-medium text-secondary">@reviewer</span>: **not bold**</span>)

    refute html =~ "<strong>"
    refute html =~ ~r/<span[^>]*>\s/
  end

  test "a nil body renders nothing" do
    assert render_body(nil) =~ ~s(class="message-body break-words"></div>)
  end

  test "a turn the user stopped reads as stopped, not as an error" do
    turn = fn outcome ->
      TimelineComponents.event_text(
        %{
          event_type: "agent_turn_completed",
          agent_id: "agt_1",
          payload: %{"outcome" => outcome}
        },
        %{"agt_1" => "backend"},
        "Priya"
      )
    end

    assert turn.("stopped") =~ "was stopped by Priya"
    refute turn.("stopped") =~ "error"
    assert turn.("error") =~ "stopped with an error"
  end

  test "interrupts read as sentences; a steered turn says what it took mid-turn" do
    text = fn type, payload ->
      TimelineComponents.event_text(
        %{event_type: type, agent_id: "agt_1", payload: payload},
        %{"agt_1" => "backend"},
        "Priya"
      )
    end

    assert text.("agent_interrupted", %{"mode" => "next_step"}) ==
             "@backend will read your message after its current step"

    assert text.("agent_interrupted", %{"mode" => "next_step", "held" => true}) ==
             "@backend will read your message once the card is answered"

    assert text.("agent_interrupted", %{"mode" => "now"}) == "Priya interrupted @backend"

    assert text.("agent_turn_completed", %{
             "outcome" => "ok",
             "interrupted_by" => ["msg_1"],
             "tools" => 3
           }) == "@backend finished · took 1 message mid-turn · 3 tools"

    assert text.("agent_turn_completed", %{"outcome" => "interrupted", "interrupted_by" => ["m"]}) ==
             "@backend was interrupted by Priya"

    assert TimelineComponents.activity_class(%{
             event_type: "agent_interrupted",
             payload: %{"mode" => "next_step"}
           }) == "routine"

    refute TimelineComponents.activity_class(%{
             event_type: "agent_interrupted",
             payload: %{"mode" => "now"}
           })
  end

  test "question events read as sentences, not raw event names" do
    text = fn type, payload ->
      TimelineComponents.event_text(
        %{event_type: type, agent_id: "agt_1", payload: payload},
        %{"agt_1" => "backend"},
        "Priya"
      )
    end

    assert text.("question_requested", %{"headers" => ["Claim key"]}) ==
             "@backend asked a question"

    assert text.("question_resolved", %{"status" => "answered", "by" => "user"}) ==
             "Priya answered @backend's question"

    assert text.("question_resolved", %{"status" => "answered"}) == "question answered"

    assert text.("question_resolved", %{"status" => "rejected", "by" => "user"}) ==
             "Priya dismissed @backend's question"
  end

  test "lock events read as sentences, and the uneventful ones are routine" do
    names = %{"agt_1" => "backend", "agt_2" => "fullstack"}

    text = fn type, payload ->
      TimelineComponents.event_text(
        %{event_type: type, agent_id: "agt_1", payload: payload},
        names,
        "Priya"
      )
    end

    assert text.("lock_granted", %{
             "name" => "tests",
             "promoted" => false,
             "reason" => "full suite"
           }) ==
             "@backend took the `tests` lock: full suite"

    assert text.("lock_granted", %{"name" => "tests", "promoted" => true}) ==
             "the `tests` lock passed to @backend"

    assert text.("lock_queued", %{
             "name" => "tests",
             "position" => 2,
             "holder_agent_id" => "agt_2"
           }) ==
             "@backend is waiting for the `tests` lock held by @fullstack (2nd in line)"

    assert text.("lock_released", %{
             "name" => "tests",
             "released_by" => "turn_end",
             "was" => "held",
             "next_agent_id" => "agt_2"
           }) == "@backend's turn ended, releasing the `tests` lock; next: @fullstack"

    assert text.("lock_released", %{
             "name" => "tests",
             "released_by" => "user",
             "was" => "held",
             "note" => "force-released by Priya"
           }) == "Priya took the `tests` lock back from @backend: force-released by Priya"

    assert text.("lock_released", %{
             "name" => "tests",
             "released_by" => "user",
             "user" => true,
             "was" => "held"
           }) ==
             "Priya released the `tests` lock"

    assert text.("lock_released", %{
             "name" => "tests",
             "released_by" => "lease",
             "was" => "held",
             "note" => "not used within 3 minutes"
           }) == "the `tests` lock was taken back from @backend: not used within 3 minutes"

    assert text.("lock_released", %{
             "name" => "tests",
             "released_by" => "agent",
             "was" => "waiting"
           }) ==
             "@backend left the line for the `tests` lock"

    routine = &TimelineComponents.activity_class(%{event_type: &1, payload: &2})
    assert routine.("lock_granted", %{"promoted" => false}) == "routine"
    assert routine.("lock_granted", %{"promoted" => true}) == nil
    assert routine.("lock_released", %{"released_by" => "turn_end"}) == "routine"

    assert routine.("lock_released", %{"released_by" => "turn_end", "next_agent_id" => "agt_2"}) ==
             nil

    assert routine.("lock_released", %{"released_by" => "lease", "note" => "x"}) == nil
    assert routine.("lock_queued", %{}) == nil
  end

  test "paths inside the repository read relative to its root" do
    root = "/Users/me/tmp/acme-billing"

    assert TimelineComponents.relative_paths("#{root}/acme/billing/payments.py", root) ==
             "acme/billing/payments.py"

    assert TimelineComponents.relative_paths("cd #{root} && pytest #{root}/tests", root <> "/") ==
             "pytest tests"

    assert TimelineComponents.relative_paths(~s(cd "#{root}" && mix test), root) == "mix test"

    assert TimelineComponents.relative_paths("cd #{root}/acme && pytest", root) ==
             "cd acme && pytest"

    assert TimelineComponents.relative_paths("ls #{root}", root) == "ls ."

    assert TimelineComponents.relative_paths("/Users/me/tmp/acme-billing-2/x.py", root) ==
             "/Users/me/tmp/acme-billing-2/x.py"

    assert TimelineComponents.relative_paths("#{root}/a.py", nil) == "#{root}/a.py"
  end

  test "a first-version card hides step rows and drops a detail that repeats the title" do
    root = "/Users/me/tmp/acme-billing"

    event = %{
      id: "evt_1",
      channel_id: "chn_1",
      event_type: "agent_turn_completed",
      agent_id: "agt_1",
      inserted_at: ~U[2026-09-29 10:00:00Z],
      payload: %{
        "outcome" => "ok",
        "activity" => [
          %{
            "key" => "t1",
            "kind" => "tool",
            "label" => "Read acme/billing/payments.py",
            "detail" => "#{root}/acme/billing/payments.py"
          },
          %{
            "key" => "file-#{root}/acme/billing/payments.py",
            "kind" => "file",
            "label" => "payments.py",
            "detail" => "#{root}/acme/billing/payments.py"
          },
          %{
            "key" => "step-1",
            "kind" => "step",
            "label" => "step tool_use",
            "detail" => "218 tokens"
          },
          %{
            "key" => "t2",
            "kind" => "tool",
            "label" => "Run tests",
            "detail" => "pytest #{root}/tests"
          }
        ]
      }
    }

    html = render_turn(event, root: root, activity: %{open?: true})
    doc = LazyHTML.from_fragment(html)

    assert text_of(doc, "#turn-evt_1-t1") =~ "Read acme/billing/payments.py"
    refute text_of(doc, "#turn-evt_1-t1") =~ "— acme/billing/payments.py"
    # a file row labelled with the file's name shows its path instead
    assert text_of(doc, "#turn-evt_1-file--Users-me-tmp-acme-billing-acme-billing-payments-py") =~
             "acme/billing/payments.py"

    assert text_of(doc, "#turn-evt_1-t2") =~ "Run tests — pytest tests"
    # (the row key, a path, still names the row for the toggle event)
    refute LazyHTML.text(doc) =~ "/Users/me"
    refute html =~ "step tool_use"
    refute html =~ "218 tokens"
    # first-version rows know no durations, and there are no step dividers
    assert LazyHTML.query(doc, "[data-step-divider]") |> Enum.count() == 0
    refute text_of(doc, "#turn-evt_1-t2") =~ ~r/\d+\.\ds/
  end

  test "a detail the row doesn't need is dropped" do
    redundant? = &TimelineComponents.redundant_detail?/2

    assert redundant?.("Grep enqueue_charge", "enqueue_charge")
    assert redundant?.("Read acme/billing/payments.py", "acme/billing/payments.py")
    assert redundant?.("pytest -q", "pytest -q")
    assert redundant?.("canopy handoff_get", "ho_01M3P6W96MG9ABCDEFGHJKMNPQ")
    assert redundant?.("canopy message_send", "Reviewed the diff. Approving.")
    assert redundant?.("canopy_thread_reply", "Done.")

    refute redundant?.("Run tests", "pytest tests")
    refute redundant?.("Run the tests", "test")
    refute redundant?.("acme/billing/payments.py", "payments.py")
    refute redundant?.("canopy messages_search", "claim key")
    refute redundant?.("canopy handoff_get", nil)
  end

  test "a row labelled with a file's name shows its path instead" do
    assert TimelineComponents.path_label("payments.py", "acme/billing/payments.py") ==
             {"acme/billing/payments.py", nil}

    assert TimelineComponents.path_label("Run tests", "pytest tests") ==
             {"Run tests", "pytest tests"}

    assert TimelineComponents.path_label("s.py", "acme/billing/payments.py") ==
             {"s.py", "acme/billing/payments.py"}

    assert TimelineComponents.path_label("", "acme/") == {"", "acme/"}
    assert TimelineComponents.path_label("patch", nil) == {"patch", nil}
  end

  test "a finished card keeps its narration and shows the closing note when open" do
    note = "Reviewed the diff. Approving with two small notes."

    event = %{
      id: "evt_2",
      channel_id: "chn_1",
      event_type: "agent_turn_completed",
      agent_id: "agt_1",
      inserted_at: ~U[2026-09-29 10:00:00Z],
      payload: %{
        "outcome" => "ok",
        "final_text" => note,
        "activity" => [
          %{"key" => "text-1", "kind" => "text", "label" => "Reading the diff first."},
          %{"key" => "t1", "kind" => "tool", "label" => "canopy message_send", "detail" => note},
          %{"key" => "step-1", "kind" => "step", "label" => "step end_turn"}
        ]
      }
    }

    closed = render_turn(event)
    assert closed =~ ~s(id="turn-toggle-evt_2")
    assert closed =~ ~s(aria-expanded="false")
    refute closed =~ "Reading the diff first."
    refute closed =~ "Closing note"

    html = render_turn(event, activity: %{open?: true})
    assert html =~ "Reading the diff first."
    assert html =~ "canopy message_send"
    refute html =~ "— #{note}"
    assert html =~ ~s(id="turn-evt_2-note")
    assert html =~ "Closing note"
  end

  test "a finished turn with nothing recorded is still a plain line" do
    event = %{
      id: "evt_3",
      channel_id: "chn_1",
      event_type: "agent_turn_completed",
      agent_id: "agt_1",
      inserted_at: ~U[2026-09-29 10:00:00Z],
      payload: %{"outcome" => "ok", "tools" => 0, "activity" => []}
    }

    html = render_turn(event)
    assert html =~ ~s(id="line-evt_3")
    refute html =~ ~s(id="turn-evt_3")
  end

  test "rows show their category, status, duration and exit code; steps get dividers" do
    root = "/r"

    activity = [
      %{
        "key" => "text-a",
        "kind" => "text",
        "category" => "note",
        "step" => 0,
        "label" => "Testing."
      },
      %{
        "key" => "c1",
        "kind" => "tool",
        "status" => "error",
        "category" => "shell",
        "step" => 0,
        "label" => "mix test test/billing",
        "command" => "cd /r && mix test test/billing",
        "duration_ms" => 38_400,
        "exit_code" => 1,
        "fact" => "exit 1"
      },
      %{
        "key" => "c2",
        "kind" => "tool",
        "status" => "ok",
        "category" => "edit",
        "step" => 1,
        "label" => "/r/acme/payments.py",
        "path" => "/r/acme/payments.py",
        "duration_ms" => 200,
        "adds" => 12,
        "dels" => 3,
        "fact" => "+12 −3"
      },
      %{
        "key" => "c3",
        "kind" => "tool",
        "status" => "error",
        "category" => "shell",
        "step" => 1,
        "label" => "rm -rf build",
        "denied" => true
      }
    ]

    event = %{
      id: "evt_4",
      channel_id: "chn_1",
      event_type: "agent_turn_completed",
      agent_id: "agt_1",
      inserted_at: ~U[2026-09-29 10:00:00Z],
      payload: %{
        "outcome" => "ok",
        "tools" => 3,
        "activity" => activity,
        "activity_meta" => %{
          "v" => 2,
          "tallies" => %{"shell" => 2, "edit" => 1, "errors" => 2},
          "dropped" => 0,
          "steps" => [900, 2_100],
          "files" => [%{"path" => "/r/acme/payments.py", "adds" => 12, "dels" => 3}]
        }
      }
    }

    html = render_turn(event, root: root, activity: %{open?: true})
    doc = LazyHTML.from_fragment(html)

    assert [row] = LazyHTML.query(doc, "#turn-evt_4-c1") |> Enum.to_list()
    assert LazyHTML.attribute(row, "data-category") == ["shell"]
    assert LazyHTML.attribute(row, "data-status") == ["error"]
    assert text_of(doc, "#turn-evt_4-c1") =~ "exit 1"
    assert text_of(doc, "#turn-evt_4-c1") =~ "38.4s"
    assert html =~ ~s(bg-error/5)
    assert text_of(doc, "#turn-evt_4-c1-toggle") =~ "mix test test/billing"

    assert LazyHTML.attribute(LazyHTML.query(doc, "#turn-evt_4-c3"), "data-status") == ["denied"]
    assert text_of(doc, "#turn-evt_4-c2") =~ "acme/payments.py"
    assert text_of(doc, "#turn-evt_4-c2") =~ "+12 −3"

    # two steps: a divider each, with its tokens
    assert LazyHTML.query(doc, "[data-step-divider]") |> Enum.count() == 2
    assert html =~ "2.1k tok"

    # the changed file is a chip with its counts that opens Changes on it
    assert [chip] =
             LazyHTML.query(doc, "#turn-evt_4-files button[phx-value-path]") |> Enum.to_list()

    assert LazyHTML.attribute(chip, "phx-value-path") == ["acme/payments.py"]
    assert LazyHTML.text(chip) =~ "+12"

    # the filter chips count from the tallies
    assert text_of(doc, "#turn-evt_4-filter-errors") =~ "2"
    assert text_of(doc, "#turn-evt_4-filter-shell") =~ "2"

    # the header quotes the first failure
    assert text_of(doc, "#turn-evt_4-first-error") =~ "exit 1: mix test test/billing"

    # an opened row shows its detail; a turn from before details were kept says so
    open =
      render_turn(event,
        root: root,
        activity: %{
          open?: true,
          open_rows: MapSet.new(["c1"]),
          details: %{
            "c1" => %{
              "input" => "cd /r && mix test",
              "output" => "1 failure",
              "output_lines" => 1
            }
          }
        }
      )

    assert open =~ ~s(id="turn-evt_4-c1-detail")
    assert open =~ "1 failure"
    assert open =~ ~s(id="turn-evt_4-c1-command-text")

    old =
      render_turn(event,
        activity: %{open?: true, open_rows: MapSet.new(["c1"]), details: :not_recorded}
      )

    assert old =~ ~s(id="turn-evt_4-c1-detail")
    assert old =~ "recorded for turns before"
  end

  test "a long card starts with its earlier steps collapsed" do
    entries =
      for step <- 0..3, i <- 1..50 do
        %{key: "c#{step}-#{i}", kind: :tool, status: :ok, label: "x", step: step}
      end

    card = %{Canopy.Runtime.Activity.new() | entries: entries}
    items = TimelineComponents.activity_items(card)
    rows = Enum.filter(items, &(&1.type == :row))

    # 200 rows in four steps: whole steps collapse while at least 120 rows stay shown
    assert Enum.count(rows, & &1.early?) == 50
    assert Enum.count(items, &(&1.type == :divider)) == 4
    refute List.last(rows).early?

    short = %{card | entries: Enum.take(entries, 100)}
    refute Enum.any?(TimelineComponents.activity_items(short), & &1.early?)
  end

  test "an agent's message carries the receipt of the turn that posted it" do
    message = %{
      id: "msg_1",
      channel_id: "chn_1",
      agent_id: "agt_1",
      agent: %{name: "backend", color: nil},
      user: nil,
      kind: "post",
      body: "Fixed.",
      inserted_at: ~U[2026-09-29 10:00:00Z],
      sent_to_channel: false,
      thread_id: nil,
      documents: []
    }

    assigns = %{message: message}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.message_item
        message={@message}
        names={%{}}
        user_name="Priya"
        receipt={%{event_id: "evt_9", tools: 14, duration_ms: 185_000}}
      />
      """)

    assert html =~ ~s(id="message-receipt-msg_1")
    assert html =~ "activity=evt_9"
    assert html =~ "14 tools · 3m 5s"
  end

  test "diffs tint added and removed lines" do
    assigns = %{diff: "--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-old\n+new\n same\n"}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.diff_view id="d" diff={@diff} />
      """)

    assert html =~ ~s(data-diff="add"><span class="text-success">+</span>new</span>)
    assert html =~ ~s(data-diff="del"><span class="text-error">-</span>old</span>)
    assert html =~ ~s(class="block px-4 bg-success/10")
    assert html =~ ~s(class="block px-4 bg-error/10")
  end

  describe "playbook and watch lines" do
    @names %{"agt_pm" => "pm", "agt_be" => "backend", "agt_fe" => "frontend"}

    defp line(type, payload, agent_id \\ "agt_pm") do
      TimelineComponents.event_text(
        %{event_type: type, agent_id: agent_id, payload: Map.put(payload, "playbook", "bug-fix")},
        @names,
        "Steven"
      )
    end

    test "a run's lines" do
      assert line("playbook_started", %{"steps" => 6, "brief" => "login broken"}) ==
               "@pm started the bug-fix playbook · 6 steps: login broken"

      assert line(
               "playbook_started",
               %{
                 "steps" => 6,
                 "brief" => "x",
                 "trigger" => %{"key" => "pr:3"},
                 "coordinator_agent_id" => "agt_pm"
               },
               nil
             ) ==
               "a GitHub watch started the bug-fix playbook for @pm (pr:3) · 6 steps"

      assert line("playbook_step_completed", %{
               "title" => "Reproduce",
               "next" => "fix",
               "next_title" => "Fix",
               "next_owner_ids" => ["agt_be", "agt_fe"]
             }) == "bug-fix: Reproduce done → Fix (@backend, @frontend)"

      assert line("playbook_approval_requested", %{"title" => "User sign-off"}) ==
               "bug-fix is waiting for your sign-off on User sign-off"

      assert line(
               "playbook_approval_resolved",
               %{"title" => "User sign-off", "approved" => false, "note" => "still blue"},
               nil
             ) ==
               "Steven asked for changes on User sign-off of bug-fix: still blue"

      assert line("playbook_coordinator_changed", %{
               "from_agent_id" => "agt_pm",
               "to_agent_id" => "agt_be",
               "by" => "handoff"
             }) ==
               "bug-fix: coordinator @pm → @backend (it followed the handoff)"

      assert line("playbook_stalled", %{"title" => "Fix", "quiet_s" => 1900}) ==
               "bug-fix has been on Fix for 31 min with no activity; nudged @pm"

      assert line("playbook_completed", %{"outcome" => nil}) == "the bug-fix playbook is complete"

      assert TimelineComponents.activity_class(%{event_type: "playbook_step_started"}) ==
               "routine"
    end

    test "a watch firing" do
      assert TimelineComponents.event_text(
               %{
                 event_type: "schedule_fired",
                 agent_id: "agt_pm",
                 payload: %{
                   "kind" => "watch",
                   "keys" => ["pr:1", "pr:2"],
                   "watch" => "new pull requests in a/b",
                   "runs" => 0
                 }
               },
               @names,
               "Steven"
             ) == "a watch found 2 new items for @pm (new pull requests in a/b)"
    end
  end
end
