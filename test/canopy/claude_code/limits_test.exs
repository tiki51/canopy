defmodule Canopy.ClaudeCode.LimitsTest do
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.{Events, Limits}

  @now ~U[2026-10-16 08:00:00.000000Z]
  @far 4_102_444_800

  test "a rejected rate_limit_info gives the reset time, in seconds or milliseconds" do
    info = %{"status" => "rejected", "resetsAt" => @far, "rateLimitType" => "five_hour"}
    text = "You've hit your session limit · resets 4:50am (America/Los_Angeles)"

    assert %{kind: "usage", reason: "usage limit", resets_at: at, detail: ^text} =
             Limits.from(info, text, @now)

    assert DateTime.to_unix(at) == @far

    ms = %{info | "resetsAt" => @far * 1000}
    assert DateTime.to_unix(Limits.from(ms, text, @now).resets_at) == @far
  end

  test "the window's type names the reason" do
    weekly = %{"status" => "rejected", "resetsAt" => @far, "rateLimitType" => "seven_day_opus"}

    assert %{kind: "usage", reason: "weekly usage limit"} =
             Limits.from(weekly, "You've hit your limit", @now)

    overage = %{"status" => "rejected", "resetsAt" => @far, "rateLimitType" => "overage"}

    assert %{kind: "usage", reason: "usage limit"} =
             Limits.from(overage, "You've hit your limit", @now)
  end

  test "a |epoch suffix gives the reset time" do
    assert %{resets_at: at, kind: "usage"} =
             Limits.from(nil, "Claude AI usage limit reached|#{@far}", @now)

    assert DateTime.to_unix(at) == @far
  end

  test "a clock time in the local zone is the next such time after now" do
    zone = Limits.local_zone()
    text = "You've hit your session limit · resets 4:50am" <> if(zone, do: " (#{zone})", else: "")

    %{resets_at: at} = Limits.from(nil, text, @now)
    assert DateTime.compare(at, @now) == :gt
    assert DateTime.diff(at, @now, :hour) < 24

    {_date, {h, m, _}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    assert {h, m} == {4, 50}

    # after that time today, it is tomorrow's
    later = DateTime.add(at, 60, :second)
    assert DateTime.diff(Limits.from(nil, text, later).resets_at, at, :hour) in 23..25
  end

  test "a clock time in another zone gives no reset time" do
    zone =
      if Limits.local_zone() == "Pacific/Chatham", do: "Asia/Kathmandu", else: "Pacific/Chatham"

    assert %{resets_at: nil, kind: "billing"} =
             Limits.from(nil, "You've hit your session limit · resets 4:50am (#{zone})", @now)
  end

  test "billing wording" do
    assert %{kind: "billing", reason: "insufficient balance", resets_at: nil} =
             Limits.from(nil, "Credit balance is too low", @now)

    assert %{kind: "billing", reason: "monthly spend limit"} =
             Limits.from(nil, "You've hit your monthly spend limit.", @now)

    assert %{reason: "weekly usage limit"} =
             Limits.from(nil, "You have reached your weekly usage limit", @now)
  end

  test "not a limit: the per-turn budget, fast mode, a full context" do
    refute Limits.from(nil, "Budget limit reached ($0.52 of $0.50)", @now)
    refute Limits.from(nil, "You've hit your fast limit", @now)
    refute Limits.from(nil, "Context limit reached", @now)
    refute Limits.from(nil, nil, @now)
    refute Limits.from(%{"status" => "allowed"}, "error_max_turns", @now)
  end

  test "a rejected window followed by an unrelated error is not a limit" do
    info = %{"status" => "rejected", "resetsAt" => @far, "rateLimitType" => "five_hour"}

    for text <- [
          nil,
          "error_max_turns",
          "API Error: 500 Internal Server Error",
          "Prompt is too long"
        ] do
      refute Limits.from(info, text, @now)
    end

    acc = Events.new()

    {_, acc} =
      Events.normalize(%{"type" => "rate_limit_event", "rate_limit_info" => info}, acc)

    {events, acc} =
      Events.normalize(
        %{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "result" => "Reached max turns",
          "usage" => %{}
        },
        acc
      )

    assert %{type: :agent_error, data: %{limit: nil}} = List.last(events)
    assert acc.rate_limit == nil
  end

  test "the stream: a rejected rate_limit_event, then the error result, carries the limit" do
    acc = Events.new()

    {[%{type: :agent_status}], acc} =
      Events.normalize(
        %{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{
            "status" => "rejected",
            "resetsAt" => @far,
            "rateLimitType" => "five_hour"
          }
        },
        acc
      )

    {events, acc} =
      Events.normalize(
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "You've hit your session limit · resets 4:50am",
          "usage" => %{}
        },
        acc
      )

    assert %{type: :agent_error, data: %{limit: %{kind: "usage", resets_at: at}}} =
             List.last(events)

    assert DateTime.to_unix(at) == @far
    assert acc.rate_limit == nil
  end

  test "an allowed or warning rate_limit_event is ignored" do
    for status <- ["allowed", "allowed_warning"] do
      assert {[], %{rate_limit: nil}} =
               Events.normalize(
                 %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => status}},
                 Events.new()
               )
    end
  end

  test "an error result that isn't a limit carries none" do
    {events, _} =
      Events.normalize(
        %{"type" => "result", "subtype" => "error_max_turns", "is_error" => true, "usage" => %{}},
        Events.new()
      )

    assert %{type: :agent_error, data: %{limit: nil}} = List.last(events)
  end
end
