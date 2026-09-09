defmodule Canopy.OpenCode.SSETest do
  use ExUnit.Case, async: true

  alias Canopy.OpenCode.SSE

  test "parses complete events and keeps the incomplete tail" do
    {events, rest} = SSE.feed("", "data: one\n\ndata: tw")
    assert [%{data: "one", event: nil, id: nil}] = events
    assert rest == "data: tw"

    {events, rest} = SSE.feed(rest, "o\n\n")
    assert [%{data: "two"}] = events
    assert rest == ""
  end

  test "handles CRLF, comments, event names, ids, and multi-line data" do
    chunk = ": keepalive\r\nevent: message\r\nid: 7\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\n"
    assert {[%{event: "message", id: "7", data: "{\"a\":\n1}"}], ""} = SSE.feed("", chunk)
  end

  test "a bare heartbeat comment produces no event" do
    assert {[], ""} = SSE.feed("", ":\n\n")
  end

  test "data split across arbitrary byte boundaries reassembles" do
    payload = "data: " <> String.duplicate("x", 5000) <> "\n\n"

    {events, rest} =
      payload
      |> :binary.bin_to_list()
      |> Enum.chunk_every(97)
      |> Enum.map(&:binary.list_to_bin/1)
      |> Enum.reduce({[], ""}, fn chunk, {acc, buf} ->
        {evs, buf} = SSE.feed(buf, chunk)
        {acc ++ evs, buf}
      end)

    assert rest == ""
    assert [%{data: data}] = events
    assert byte_size(data) == 5000
  end
end
