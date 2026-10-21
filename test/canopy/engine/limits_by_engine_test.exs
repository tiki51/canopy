defmodule Canopy.Engine.LimitsByEngineTest do
  @moduledoc """
  How each adapter reads a usage or billing limit off its engine's error:
  the edges the adapters' own tests leave out (OpenCode's 429/402 headers,
  Codex's window choice and kinds, Claude Code's clock times and unknown
  window types).
  """
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.Limits
  alias Canopy.Codex.Events, as: CodexEvents
  alias Canopy.OpenCode.Events, as: OpenCodeEvents

  @far 4_102_444_800
  @now ~U[2026-10-16 08:00:00.000000Z]

  describe "OpenCode session.error" do
    defp api_error(status, message, headers \\ %{}) do
      %{
        "name" => "APIError",
        "data" => %{
          "message" => message,
          "statusCode" => status,
          "isRetryable" => false,
          "responseHeaders" => headers
        }
      }
    end

    test "a 429 limit takes its reset from anthropic-ratelimit-unified-reset, over retry-after" do
      headers = %{"anthropic-ratelimit-unified-reset" => "#{@far}", "retry-after" => "120"}

      assert %{kind: "usage", reason: "usage limit", resets_at: at, detail: "Usage limit reached"} =
               OpenCodeEvents.limit(api_error(429, "Usage limit reached", headers))

      assert DateTime.to_unix(at) == @far
    end

    test "a 429 limit with only retry-after resets that many seconds from now" do
      %{resets_at: at} =
        OpenCodeEvents.limit(api_error(429, "Usage limit reached", %{"Retry-After" => "7200"}))

      assert_in_delta DateTime.diff(at, DateTime.utc_now(), :second), 7200, 5
    end

    test "a 429 limit with no reset header waits for Release" do
      assert %{kind: "billing", resets_at: nil} =
               OpenCodeEvents.limit(api_error(429, "Usage limit reached"))
    end

    test "headers that aren't a map give no reset rather than raising" do
      for headers <- [nil, [], "retry-after: 60", [["retry-after", "60"]]] do
        assert %{resets_at: nil} =
                 OpenCodeEvents.limit(api_error(429, "Usage limit reached", headers))
      end
    end

    test "a 402 is billing, insufficient balance" do
      assert %{kind: "billing", reason: "insufficient balance", resets_at: nil} =
               OpenCodeEvents.limit(api_error(402, "Insufficient balance"))
    end

    test "not a limit: a plain rate limit, another status, another error" do
      refute OpenCodeEvents.limit(api_error(429, "Rate limit exceeded, slow down"))
      refute OpenCodeEvents.limit(api_error(500, "Usage limit reached"))
      refute OpenCodeEvents.limit(%{"name" => "ProviderAuthError", "data" => %{"message" => "x"}})
      refute OpenCodeEvents.limit(%{})
    end

    test "the session.error event carries it" do
      [event] =
        OpenCodeEvents.normalize(%{
          "type" => "session.error",
          "properties" => %{
            "sessionID" => "ses_1",
            "error" => api_error(402, "Insufficient balance")
          }
        })

      assert %{type: :agent_error, data: %{limit: %{reason: "insufficient balance"}}} = event
    end
  end

  describe "Codex failed turn" do
    defp window(used, at, mins \\ 300),
      do: %{"usedPercent" => used, "resetsAt" => at, "windowDurationMins" => mins}

    defp codex_limit(snapshot, name \\ "usageLimitExceeded") do
      acc = %{rate_limits: snapshot}
      CodexEvents.limit(%{"message" => "limit", "codexErrorInfo" => name}, acc)
    end

    test "with no window used up, the earliest window's reset" do
      %{resets_at: at} =
        codex_limit(%{
          "primary" => window(80, @far + 3600),
          "secondary" => window(40, @far)
        })

      assert DateTime.to_unix(at) == @far
    end

    test "with both windows used up, the latest reset" do
      %{resets_at: at} =
        codex_limit(%{"primary" => window(100, @far), "secondary" => window(100, @far + 3600)})

      assert DateTime.to_unix(at) == @far + 3600
    end

    test "a week-long window that ran out is the weekly usage limit" do
      assert %{kind: "usage", reason: "weekly usage limit"} =
               codex_limit(%{
                 "primary" => window(40, @far),
                 "secondary" => window(100, @far + 3600, 10_080)
               })
    end

    test "credits depleted and insufficient_quota are billing" do
      assert %{kind: "billing", reason: "insufficient balance"} =
               codex_limit(%{
                 "primary" => window(100, @far),
                 "rateLimitReachedType" => "workspace_member_credits_depleted"
               })

      assert %{kind: "billing", reason: "insufficient balance"} =
               codex_limit(%{}, "insufficient_quota")
    end

    test "no snapshot: no reset time; a rate limit or other failure: no limit" do
      assert %{resets_at: nil, reason: "usage limit"} = codex_limit(nil)
      refute codex_limit(%{"primary" => window(100, @far)}, "rateLimitExceeded")
      refute CodexEvents.limit(nil, %{})
    end
  end

  describe "Claude Code text" do
    test "an hour with no minutes and no zone is read in the local zone" do
      %{resets_at: at} = Limits.from(nil, "You've hit your session limit · resets 4pm", @now)

      {_date, {h, m, _}} =
        at
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()

      assert {h, m} == {16, 0}
      assert DateTime.compare(at, @now) == :gt
    end

    test "an unknown window type is usage with a reset time, billing without one" do
      info = %{"status" => "rejected", "resetsAt" => @far, "rateLimitType" => "something_new"}

      assert %{kind: "usage", reason: "usage limit"} =
               Limits.from(info, "You've hit your limit", @now)

      assert %{kind: "billing", reason: "usage limit", resets_at: nil} =
               Limits.from(
                 %{"status" => "rejected", "rateLimitType" => "something_new"},
                 "You've hit your limit",
                 @now
               )
    end

    test "a reset already past is passed through; engage, not Limits, treats it as unknown" do
      past = DateTime.to_unix(@now) - 3600
      info = %{"status" => "rejected", "resetsAt" => past, "rateLimitType" => "five_hour"}
      assert DateTime.to_unix(Limits.from(info, "You've hit your limit", @now).resets_at) == past
    end
  end
end
