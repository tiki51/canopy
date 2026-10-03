defmodule Canopy.Messages.CodeMask do
  @moduledoc """
  Blanks the code in a Markdown body, so `@mentions` written inside code wake
  nobody. `mask/1` returns a binary of the same byte size with every byte of a
  fenced code block or an inline code span replaced by a space; offsets into
  the masked text are offsets into the original.

  The rules are a small subset of CommonMark, kept identical to
  `maskCode` in `assets/js/composer_tokens.js` (the composer highlight), and
  checked against both by `test/support/composer_token_cases.json`:

    * A fenced block opens on a line of three or more backticks or tildes
      (indentation allowed, for fences inside list items; a backtick fence's
      info string has no backticks). It closes on a line holding only a fence
      of the same character, at least as long, or runs to the end.
    * Outside fences, the text is cut into paragraphs at blank lines. In each,
      a run of N backticks opens a span closed by the next run of exactly N;
      with no closer, the run is literal. A backslash escapes the next character.

  Indented (four-space) code blocks are not recognised: in chat that indent is
  far more often a list continuation.
  """

  @open_fence ~r/\A[ \t]*(`{3,}|~{3,})(.*)\z/s

  @doc "The body with its code replaced by spaces, byte for byte."
  @spec mask(String.t()) :: String.t()
  def mask(text) when is_binary(text) do
    if String.contains?(text, ["`", "~~~"]) do
      text |> ranges() |> blank(text)
    else
      text
    end
  end

  @doc false
  # `[{start, stop}]` byte ranges of code, in order.
  def ranges(text) do
    {ranges, state, _offset} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], {:text, 0}, 0}, fn line, {acc, state, offset} ->
        stop = offset + byte_size(line)
        {acc, state} = step(text, line, offset, stop, acc, state)
        {acc, state, stop + 1}
      end)

    acc =
      case state do
        {:text, from} -> spans(text, from, byte_size(text), ranges)
        {:fence, from, _char, _len} -> [{from, byte_size(text)} | ranges]
      end

    Enum.reverse(acc)
  end

  defp step(text, line, offset, stop, acc, {:text, from}) do
    cond do
      blank?(line) ->
        {spans(text, from, offset, acc), {:text, stop + 1}}

      fence = open_fence(line) ->
        {char, len} = fence
        {spans(text, from, offset, acc), {:fence, offset, char, len}}

      true ->
        {acc, {:text, from}}
    end
  end

  defp step(_text, line, _offset, stop, acc, {:fence, from, char, len} = state) do
    if close_fence?(line, char, len),
      do: {[{from, stop} | acc], {:text, stop + 1}},
      else: {acc, state}
  end

  defp blank?(line), do: String.trim(line) == ""

  defp open_fence(line) do
    case Regex.run(@open_fence, line) do
      [_, "`" <> _ = fence, info] ->
        if String.contains?(info, "`"), do: nil, else: {?`, byte_size(fence)}

      [_, fence, _info] ->
        {?~, byte_size(fence)}

      nil ->
        nil
    end
  end

  defp close_fence?(line, char, len) do
    trimmed = String.trim(line)

    byte_size(trimmed) >= len and
      trimmed |> :binary.bin_to_list() |> Enum.all?(&(&1 == char))
  end

  # Inline code spans in text[from, to): a paragraph with no blank lines.
  defp spans(_text, from, to, acc) when from >= to, do: acc
  defp spans(text, from, to, acc), do: scan(text, from, to, acc)

  defp scan(text, i, to, acc) do
    case :binary.match(text, ["`", "\\"], scope: {i, to - i}) do
      :nomatch ->
        acc

      {pos, _} ->
        case :binary.at(text, pos) do
          ?\\ ->
            scan(text, min(pos + 2, to), to, acc)

          ?` ->
            n = run(text, pos, to)

            case closer(text, pos + n, to, n) do
              nil -> scan(text, pos + n, to, acc)
              close -> scan(text, close + n, to, [{pos, close + n} | acc])
            end
        end
    end
  end

  defp closer(text, i, to, n) do
    case :binary.match(text, "`", scope: {i, max(to - i, 0)}) do
      :nomatch ->
        nil

      {pos, _} ->
        case run(text, pos, to) do
          ^n -> pos
          m -> closer(text, pos + m, to, n)
        end
    end
  end

  defp run(text, pos, to) do
    if pos < to and :binary.at(text, pos) == ?`, do: 1 + run(text, pos + 1, to), else: 0
  end

  defp blank([], text), do: text

  defp blank(ranges, text) do
    {parts, last} =
      Enum.map_reduce(ranges, 0, fn {from, stop}, at ->
        {[binary_part(text, at, from - at), :binary.copy(" ", stop - from)], stop}
      end)

    IO.iodata_to_binary([parts, binary_part(text, last, byte_size(text) - last)])
  end
end
