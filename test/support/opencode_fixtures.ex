defmodule Canopy.OpenCodeFixtures do
  @moduledoc "Raw SSE payloads captured from OpenCode 1.18.11 during the Phase 0 spikes."

  @dir Path.expand("opencode_fixtures", __DIR__)

  @doc "Decoded events from `test/support/opencode_fixtures/<name>.jsonl`."
  def events(name) do
    @dir
    |> Path.join("#{name}.jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  @doc "The same events re-encoded as an SSE byte stream."
  def sse(name) do
    name
    |> events()
    |> Enum.map_join(fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end)
  end
end
