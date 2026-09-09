defmodule Canopy.IDTest do
  use ExUnit.Case, async: true

  alias Canopy.ID

  test "generates prefixed 26-character Crockford ids" do
    id = ID.generate("msg")
    assert String.starts_with?(id, "msg_")
    assert String.length(id) == 4 + 26
    assert ID.valid?(id, "msg")
    assert Regex.match?(~r/^msg_[0-7][0-9A-HJKMNP-TV-Z]{25}$/, id)
  end

  test "ids sort lexicographically in generation order" do
    ids = for _ <- 1..500, do: ID.generate("evt")
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)
  end

  test "ids generated across a millisecond boundary still sort by time" do
    first = ID.generate("msg")
    Process.sleep(2)
    second = ID.generate("msg")
    assert first < second

    assert {:ok, %DateTime{} = t1} = ID.timestamp(first)
    assert {:ok, %DateTime{} = t2} = ID.timestamp(second)
    assert DateTime.compare(t1, t2) in [:lt, :eq]
    assert DateTime.diff(DateTime.utc_now(), t1, :second) < 5
  end

  test "prefix/1 and valid?/2 reject malformed ids" do
    id = ID.generate("ho")
    assert ID.prefix(id) == "ho"
    refute ID.valid?(id, "msg")
    assert ID.prefix("nope") == nil
    assert ID.prefix("msg_") == nil
    assert ID.prefix("msg_" <> String.duplicate("I", 26)) == nil
    assert ID.prefix("Msg_" <> String.duplicate("0", 26)) == nil
    refute ID.valid?(nil, "msg")
    refute ID.valid?("msg_01", "msg")
  end

  test "rejects invalid prefixes" do
    assert_raise ArgumentError, fn -> ID.generate("Bad Prefix") end
    assert_raise ArgumentError, fn -> ID.generate("with_underscore") end
  end
end
