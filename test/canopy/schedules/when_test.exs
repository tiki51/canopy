defmodule Canopy.Schedules.WhenTest do
  use ExUnit.Case, async: true

  alias Canopy.Schedules.When

  @now ~U[2026-09-10 12:00:00Z]

  test "relative durations" do
    assert {:once, ~U[2026-09-10 12:30:00Z]} = When.parse("30m", @now)
    assert {:once, ~U[2026-09-10 14:00:00Z]} = When.parse("in 2 hours", @now)
    assert {:once, ~U[2026-09-11 12:00:00Z]} = When.parse("1d", @now)
    assert {:once, ~U[2026-09-10 12:01:30Z]} = When.parse("90 seconds", @now)
    assert {:error, reason} = When.parse("3 fortnights", @now)
    assert reason =~ "unknown unit"
  end

  test "absolute times, with and without an offset" do
    assert {:once, ~U[2026-09-10 21:00:00Z]} = When.parse("2026-09-10T14:00:00-07:00", @now)
    assert {:once, ~U[2026-09-10 21:00:00Z]} = When.parse("at 2026-09-10T14:00-07:00", @now)

    # offset-less is local: it round-trips through the local offset
    {:once, at} = When.parse("2026-09-11 09:30", @now)
    assert When.to_local_naive(at) == ~N[2026-09-11 09:30:00]

    assert {:error, "that time is in the past"} = When.parse("2026-09-10T11:00:00Z", @now)
    assert {:error, reason} = When.parse("2028-01-01T00:00:00Z", @now)
    assert reason =~ "more than a year"
    assert {:error, reason} = When.parse("tomorrow-ish", @now)
    assert reason =~ "could not read"
  end

  test "cron expressions, in local time, at least five minutes apart" do
    assert {:recurring, "0 9 * * 1-5", first} = When.parse("0 9 * * 1-5", @now)
    local = When.to_local_naive(first)
    assert local.hour == 9 and local.minute == 0
    assert Date.day_of_week(NaiveDateTime.to_date(local)) in 1..5
    assert DateTime.compare(first, @now) == :gt

    assert {:recurring, "*/15 * * * *", _} = When.parse("*/15 * * * *", @now)
    assert {:error, reason} = When.parse("* * * * *", @now)
    assert reason =~ "at least 5 minutes"
    assert {:error, reason} = When.parse("99 9 * * *", @now)
    assert reason =~ "bad cron"

    {:ok, next} = When.next_run("0 9 * * 1-5", first)
    assert DateTime.diff(next, first, :second) in [86_400, 3 * 86_400]
  end

  test "empty input" do
    assert {:error, "when is empty"} = When.parse("", @now)
    assert {:error, "when is empty"} = When.parse(nil, @now)
  end
end
