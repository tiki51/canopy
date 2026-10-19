defmodule Canopy.HoldTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Canopy.Fixtures

  alias Canopy.{Hold, Schedules}

  test "engage pauses schedules and release resumes exactly those" do
    %{channel: channel, agent: agent} = scenario()
    Hold.subscribe()

    {:ok, active} =
      Schedules.create(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "check",
        when: "0 9 * * *"
      })

    {:ok, already} =
      Schedules.create(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "old",
        when: "2h"
      })

    {:ok, already} = Schedules.cancel(already, "not needed")

    refute Hold.active?()
    assert :ok = Hold.engage("Insufficient balance")
    assert Hold.active?()
    assert Hold.reason() == "Insufficient balance"
    assert %DateTime{} = Hold.since()
    assert_receive {:hold, :engaged}

    assert %{status: "paused", status_reason: "on hold: Insufficient balance"} =
             Schedules.get!(active.id)

    assert %{status: "cancelled"} = Schedules.get!(already.id)

    # engaging again is a no-op
    assert :ok = Hold.engage("something else")
    assert Hold.reason() == "Insufficient balance"

    # held schedules do not fire even if their job runs
    assert :ok = Schedules.fire(active.id)

    assert :ok = Hold.release()
    refute Hold.active?()
    assert_receive {:hold, :released}
    assert %{status: "active"} = Schedules.get!(active.id)
    assert %{status: "cancelled"} = Schedules.get!(already.id)
  end

  test "recognises billing errors" do
    assert Hold.billing_error?("Insufficient balance. Manage your billing here: https://x")
    assert Hold.billing_error?("You have no credits remaining.")
    assert Hold.billing_error?("insufficient_quota")
    assert Hold.billing_error?("HTTP 402 Payment Required")
    refute Hold.billing_error?("Model not found: anthropic/claude")
    refute Hold.billing_error?(nil)
  end

  test "recognises Claude Code's billing and usage-limit wording" do
    assert Hold.billing_error?("Credit balance is too low")
    assert Hold.billing_error?("Claude AI usage limit reached|1759683600")
    assert Hold.billing_error?("You've hit your limit · resets 3pm")
    assert Hold.billing_error?("You've hit your monthly spend limit.")
    assert Hold.billing_error?("You have reached your weekly usage limit")
    assert Hold.billing_error?("You're out of extra usage")
    refute Hold.billing_error?("Budget limit reached ($0.52 of $0.50)")
    refute Hold.billing_error?("You've hit your fast limit")
    refute Hold.billing_error?("Context limit reached")
    refute Hold.billing_error?("error_max_turns")
  end

  test "recognises Codex's usage limits, not its rate limits or sign-in errors" do
    usage = %{
      "name" => "usageLimitExceeded",
      "data" => %{"message" => "You've hit your usage limit. Try again later."}
    }

    assert Hold.billing_error?(usage)
    assert Hold.billing_error?("You've hit your usage limit. Upgrade to Pro.")
    assert Hold.billing_error?(%{"name" => "usageLimitExceeded"})
    assert Hold.billing_error?(%{"name" => "insufficient_quota", "data" => %{"message" => "x"}})

    # a map with any other name doesn't decide; its first line is checked as
    # text by the runtime (record_agent_error), which still catches the wording
    refute Hold.billing_error?(%{
             "name" => "codex",
             "data" => %{"message" => "You've hit your usage limit"}
           })

    assert Hold.billing_error?("You've hit your usage limit")

    refute Hold.billing_error?(%{"name" => "codex", "data" => %{"message" => "stream closed"}})

    refute Hold.billing_error?(%{
             "name" => "rateLimitExceeded",
             "data" => %{"message" => "Rate limit reached for requests"}
           })

    refute Hold.billing_error?(%{"name" => "serverOverloaded", "data" => %{"message" => "busy"}})

    refute Hold.billing_error?(%{
             "name" => "unauthorized",
             "data" => %{"message" => "Codex is not signed in: run `codex login`"}
           })

    refute Hold.billing_error?(%{"name" => "httpConnectionFailed"})
    refute Hold.billing_error?(%{"name" => "contextWindowExceeded"})
    refute Hold.billing_error?(%{})
  end

  test "Claude Code and OpenCode error maps never engage the hold on deeper text" do
    # billing words below the first line (a stderr dump, an API body) don't count
    refute Hold.billing_error?(%{
             "name" => "APIError",
             "data" => %{"message" => "Request failed\nsee https://example.com/billing (402)"}
           })

    refute Hold.billing_error?(%{
             "name" => "claude_code",
             "data" => %{"message" => "exited 1\nCredit balance is too low"}
           })

    refute Hold.billing_error?(%{"name" => "UnknownError"})

    # their first line, checked as text, still decides as before
    assert Hold.billing_error?("Credit balance is too low")
    assert Hold.billing_error?("insufficient_quota: add credits")
  end

  test "a Claude Code error result carries the wording through to the check" do
    {events, _} =
      Canopy.ClaudeCode.Events.normalize(
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "Credit balance is too low",
          "usage" => %{}
        },
        Canopy.ClaudeCode.Events.new()
      )

    assert %{type: :agent_error, data: %{error: %{"data" => %{"message" => reason}}}} =
             List.last(events)

    assert Hold.billing_error?(reason)
  end
end
