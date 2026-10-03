defmodule CanopyWeb.NotifyTest do
  use ExUnit.Case, async: true

  alias Canopy.Agents.Agent
  alias Canopy.Channels.Channel
  alias Canopy.Messages.Message
  alias Canopy.Timeline.Event
  alias CanopyWeb.Notify

  @pm %Agent{id: "agt_pm", name: "pm"}
  @channel %Channel{id: "ch_1", name: "site-review", kind: "channel", status: "open"}
  @dm %Channel{id: "ch_dm", name: "dm-pm", kind: "dm", status: "open", agents: [@pm]}

  defp ctx(channel \\ @channel), do: %{channel: channel, names: %{"agt_pm" => "pm"}}

  defp event(type, attrs) do
    struct!(
      %Event{
        id: "evt_1",
        channel_id: @channel.id,
        agent_id: @pm.id,
        agent: @pm,
        event_type: type,
        ref_id: "req_1",
        payload: %{}
      },
      attrs
    )
  end

  defp message_event(attrs, channel \\ @channel) do
    message =
      struct!(
        %Message{
          id: "msg_1",
          channel_id: channel.id,
          agent_id: @pm.id,
          kind: "post",
          body: "@You the build is green",
          mentions_user: true
        },
        attrs
      )

    event("message", channel_id: channel.id, ref_id: message.id, message: message)
  end

  describe "needs you" do
    test "a question card: its own tag, the headers, and a link to the card" do
      note =
        Notify.classify(
          event("question_requested", payload: %{"headers" => ["Retry key", "Port"]}),
          ctx()
        )

      assert note == %{
               id: "card:req_1",
               kind: "needs_you",
               channel_id: "ch_1",
               place: "#site-review",
               tag: "card:req_1",
               title: "@pm needs you in #site-review",
               body: "Retry key · Port",
               url: "/channels/ch_1#question-req_1"
             }
    end

    test "a permission card says what is asked" do
      note =
        Notify.classify(
          event("permission_requested",
            ref_id: "per_9",
            payload: %{"permission" => "bash", "patterns" => ["git push origin main"]}
          ),
          ctx()
        )

      assert %{tag: "card:per_9", body: "bash permission: git push origin main"} = note
      assert note.url == "/channels/ch_1#permission-per_9"
    end

    test "in a DM the title names only the agent" do
      note = Notify.classify(event("question_requested", channel_id: "ch_dm"), ctx(@dm))
      assert %{title: "@pm needs you", place: "@pm"} = note
      assert note.body == "A question is waiting for your answer."
    end

    test "a playbook step held for sign-off" do
      note =
        Notify.classify(
          event("playbook_approval_requested",
            ref_id: "pbr_1",
            payload: %{
              "run_id" => "pbr_1",
              "playbook" => "bug-fix",
              "title" => "Review",
              "result" => "**Ready**: two files changed"
            }
          ),
          ctx()
        )

      assert %{kind: "needs_you", tag: "signoff:pbr_1", id: "signoff:evt_1"} = note
      assert note.title == "bug-fix needs your sign-off in #site-review"
      assert note.body == "Review: Ready: two files changed"
      assert note.url == "/channels/ch_1#evt-evt_1"
    end

    test "detached, resolved, and other card events say nothing" do
      for type <- ~w(question_detached question_resolved permission_detached permission_resolved
                     playbook_approval_resolved agent_turn_completed),
          do: assert(Notify.classify(event(type, []), ctx()) == nil, type)
    end
  end

  describe "mentions" do
    test "an agent message that mentions the user links to it, as plain text" do
      note =
        Notify.classify(
          message_event(body: "@You see [the PR](https://x.test/1) — `mix test` is **green**"),
          ctx()
        )

      assert note == %{
               id: "evt_1",
               kind: "mention",
               channel_id: "ch_1",
               place: "#site-review",
               tag: "mention:ch_1",
               title: "@pm mentioned you in #site-review",
               body: "@You see the PR — mix test is green",
               url: "/channels/ch_1?msg=msg_1"
             }
    end

    test "a long body is cut to 140 characters" do
      note = Notify.classify(message_event(body: "@You " <> String.duplicate("word ", 60)), ctx())
      assert String.length(note.body) == 140
      assert String.ends_with?(note.body, "…")
    end

    test "a thread reply links to itself, which opens its thread" do
      note = Notify.classify(message_event(kind: "thread_reply", thread_id: "msg_root"), ctx())
      assert note.title == "@pm mentioned you in a thread in #site-review"
      assert note.url == "/channels/ch_1?msg=msg_1"
    end

    test "not a mention: no flag, the user's own message, a system note" do
      refute Notify.classify(
               message_event(mentions_user: false, body: "the build is green"),
               ctx()
             )

      refute Notify.classify(message_event(agent_id: nil, user_id: "usr_1"), ctx())
      refute Notify.classify(message_event(kind: "system"), ctx())
    end

    test "a followed thread's reply that does not mention the user says nothing" do
      refute Notify.classify(
               message_event(kind: "thread_reply", thread_id: "msg_root", mentions_user: false),
               ctx()
             )
    end

    test "every agent message in a DM counts" do
      note = Notify.classify(message_event([mentions_user: false, body: "done"], @dm), ctx(@dm))
      assert %{kind: "mention", title: "@pm", body: "done", tag: "mention:ch_dm"} = note

      in_thread =
        Notify.classify(
          message_event([mentions_user: false, thread_id: "msg_root"], @dm),
          ctx(@dm)
        )

      assert in_thread.title == "@pm wrote in a thread"
    end

    test "a message with only files" do
      assert %{body: "Sent a file."} =
               Notify.classify(message_event(body: nil, mentions_user: true), ctx())
    end
  end

  describe "work finished" do
    defp quiet(info) do
      {:channel_quiet, "ch_1",
       Map.merge(
         %{
           run_id: "run_1",
           agent_ids: ["agt_pm", "agt_gone"],
           turns: 7,
           errors: 0,
           duration_ms: 245_000,
           paused?: false,
           trigger: "user"
         },
         info
       )}
    end

    test "a run the user started: who, how many turns, how long" do
      assert Notify.classify(quiet(%{}), ctx()) == %{
               id: "work:run_1",
               kind: "work",
               channel_id: "ch_1",
               place: "#site-review",
               tag: "work:ch_1",
               title: "#site-review is done",
               body: "@pm · 7 turns · 4 m",
               url: "/channels/ch_1"
             }
    end

    test "an error and a pause say so" do
      assert %{body: "@pm · stopped with an error"} = Notify.classify(quiet(%{errors: 1}), ctx())

      assert %{title: "#site-review paused", body: "@pm · paused after 7 agent turns"} =
               Notify.classify(quiet(%{paused?: true}), ctx())
    end

    test "schedules, watches and playbooks count; agents among themselves do not" do
      for trigger <- ~w(scheduled watch playbook playbook_nudge),
          do: assert(Notify.classify(quiet(%{trigger: trigger}), ctx()), trigger)

      for trigger <- ~w(agent delegation handoff lock other),
          do: refute(Notify.classify(quiet(%{trigger: trigger}), ctx()), trigger)
    end

    test "a task moved to completed; other task changes say nothing" do
      done =
        event("task_updated",
          payload: %{"changes" => %{"status" => "completed"}, "title" => "Fix the retry"}
        )

      assert %{kind: "work", tag: "work:ch_1", id: "task:evt_1"} =
               note = Notify.classify(done, ctx())

      assert note.body == "Task completed: Fix the retry"

      refute Notify.classify(
               event("task_updated", payload: %{"changes" => %{"title" => "x"}}),
               ctx()
             )

      refute Notify.classify(
               event("task_updated", payload: %{"changes" => %{"status" => "working"}}),
               ctx()
             )
    end
  end

  test "an archived or unknown channel says nothing" do
    archived = %{@channel | status: "archived"}
    refute Notify.classify(event("question_requested", []), ctx(archived))
    refute Notify.classify(message_event([]), ctx(archived))
    refute Notify.classify(event("question_requested", []), %{channel: nil})
  end
end
