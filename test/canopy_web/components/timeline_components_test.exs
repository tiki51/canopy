defmodule CanopyWeb.TimelineComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CanopyWeb.TimelineComponents

  defp render_body(body, opts \\ []) do
    assigns = %{body: body, inline: Keyword.get(opts, :inline, false)}

    rendered_to_string(~H"""
    <TimelineComponents.message_text body={@body} inline={@inline} />
    """)
  end

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

  test "the activity list hides step rows and drops a detail that repeats the title" do
    root = "/Users/me/tmp/acme-billing"

    event = %{
      id: "evt_1",
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

    assigns = %{event: event, root: root}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.timeline_item
        id="e1"
        event={@event}
        names={%{"agt_1" => "backend"}}
        user_name="Priya"
        root={@root}
      />
      """)

    assert html =~ "Read acme/billing/payments.py"
    assert html =~ ~s(<span class="text-base-content">acme/billing/payments.py</span>)
    refute html =~ "/Users/me"
    refute html =~ "— acme/billing/payments.py"
    refute html =~ ">payments.py<"
    assert html =~ "— pytest tests"
    refute html =~ "step tool_use"
    refute html =~ "218 tokens"
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

  test "the receipt leaves the closing note out of its activity list" do
    note = "Reviewed the diff. Approving with two small notes."

    event = %{
      id: "evt_2",
      event_type: "agent_turn_completed",
      agent_id: "agt_1",
      inserted_at: ~U[2026-09-29 10:00:00Z],
      payload: %{
        "outcome" => "ok",
        "final_text" => note,
        "activity" => [
          %{"key" => "text-1", "kind" => "text", "label" => "Reading the diff first."},
          %{"key" => "t1", "kind" => "tool", "label" => "canopy message_send", "detail" => note},
          %{"key" => "text-2", "kind" => "text", "label" => note},
          %{"key" => "step-1", "kind" => "step", "label" => "step end_turn"}
        ]
      }
    }

    assigns = %{event: event}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.timeline_item
        id="e2"
        event={@event}
        names={%{"agt_1" => "backend"}}
        user_name="Priya"
      />
      """)

    assert html =~ "Reading the diff first."
    assert html =~ "canopy message_send"
    refute html =~ ~s(id="turn-evt_2-text-2")
    refute html =~ "— #{note}"
    assert html =~ "Closing note"
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
end
