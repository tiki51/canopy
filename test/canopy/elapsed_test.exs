defmodule Canopy.ElapsedTest do
  use ExUnit.Case, async: true

  alias Canopy.Elapsed

  test "coarse/1 says a duration in whole minutes" do
    assert Elapsed.coarse(0) == "<1m"
    assert Elapsed.coarse(59_999) == "<1m"
    assert Elapsed.coarse(60_000) == "1m"
    assert Elapsed.coarse(4 * 60_000 + 30_000) == "4m"
    assert Elapsed.coarse(59 * 60_000) == "59m"
    assert Elapsed.coarse(60 * 60_000) == "1h 0m"
    assert Elapsed.coarse(125 * 60_000) == "2h 5m"
    # a clock a little ahead of the start never goes negative
    assert Elapsed.coarse(-5_000) == "<1m"
  end

  test "since/2 counts from one time to another" do
    from = ~U[2026-10-05 09:00:00.000000Z]
    assert Elapsed.since(from, ~U[2026-10-05 09:00:59.000000Z]) == "<1m"
    assert Elapsed.since(from, ~U[2026-10-05 09:06:05.000000Z]) == "6m"
    assert Elapsed.since(from, ~U[2026-10-05 11:05:00.000000Z]) == "2h 5m"
    assert Elapsed.since(from, ~U[2026-10-05 08:59:00.000000Z]) == "<1m"
  end
end
