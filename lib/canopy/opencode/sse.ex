defmodule Canopy.OpenCode.SSE do
  @moduledoc """
  Incremental parser for `text/event-stream` bytes.

  Feed raw chunks into `feed/2` with the leftover buffer from the previous call and get
  back complete events. Each event is a map with `:event`, `:data`, and `:id` keys;
  `:data` joins multi-line `data:` fields with newlines, as the spec requires.
  Comment lines (starting with `:`) are dropped.
  """

  @type event :: %{event: String.t() | nil, data: String.t(), id: String.t() | nil}

  @doc "Parses `chunk` appended to `buffer`; returns `{events, rest}`."
  @spec feed(binary(), binary()) :: {[event()], binary()}
  def feed(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    data = buffer <> chunk
    {complete, rest} = split_blocks(data)
    events = complete |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1)
    {events, rest}
  end

  # Blocks are separated by a blank line. The last fragment may be incomplete.
  defp split_blocks(data) do
    normalized = String.replace(data, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp parse_block(block) do
    fields =
      block
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ":")))
      |> Enum.map(&parse_line/1)

    case fields do
      [] ->
        nil

      _ ->
        data =
          fields |> Enum.filter(&(elem(&1, 0) == "data")) |> Enum.map_join("\n", &elem(&1, 1))

        %{
          event: field(fields, "event"),
          id: field(fields, "id"),
          data: data
        }
    end
  end

  defp parse_line(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> {name, String.trim_leading(value, " ")}
      [name] -> {name, ""}
    end
  end

  defp field(fields, name) do
    case List.keyfind(fields, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
