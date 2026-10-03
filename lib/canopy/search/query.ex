defmodule Canopy.Search.Query do
  @moduledoc """
  Turns free text into a safe FTS5 query for the search index.

    * every bare word becomes a quoted token, so FTS5 operators (`AND`, `OR`,
      `NOT`, `NEAR`, `-`, parentheses) are taken as literal words;
    * `"quoted phrases"` stay phrases;
    * a trailing `*` asks for a prefix match (`retr*`);
    * terms with no letters or digits are dropped.

  The tokenizer splits on punctuation, so `enqueue_charge`, `lib/canopy/messages.ex`
  and `handle_info/2` become quoted phrases of their parts and match as typed.
  """

  @doc """
  The FTS5 query for `text`, or `""` when it has no searchable term.

  Options:

    * `:prefix_last` — live typing: the last bare term also matches as a
      prefix when it has at least two characters and the text does not end
      in a space (default false)
  """
  def to_fts(text, opts \\ [])

  def to_fts(text, opts) when is_binary(text) do
    terms =
      ~r/"[^"]*"\*?|\S+/
      |> Regex.scan(text)
      |> Enum.map(&List.first/1)

    terms =
      if Keyword.get(opts, :prefix_last, false) and not String.match?(text, ~r/\s\z/u),
        do: star_last(terms),
        else: terms

    terms
    |> Enum.map(&term_to_fts/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def to_fts(_text, _opts), do: ""

  @doc "How many letters and digits `text` has: the page searches from two."
  def searchable_length(text) when is_binary(text),
    do: ~r/[[:alnum:]]/u |> Regex.scan(text) |> length()

  def searchable_length(_text), do: 0

  defp star_last([]), do: []

  defp star_last(terms) do
    {last, rest} = List.pop_at(terms, -1)

    bare? =
      not String.starts_with?(last, "\"") and not String.ends_with?(last, "*") and
        searchable_length(last) >= 2

    if bare?, do: rest ++ [last <> "*"], else: terms
  end

  defp term_to_fts(term) do
    {inner, prefix?} =
      case term do
        <<?", _::binary>> ->
          {stripped, prefix?} = strip_prefix_star(term)
          {String.trim(stripped, "\""), prefix?}

        _ ->
          strip_prefix_star(term)
      end

    inner = inner |> String.replace("\"", "") |> String.trim()

    cond do
      not Regex.match?(~r/[[:alnum:]]/u, inner) -> ""
      prefix? -> ~s("#{inner}"*)
      true -> ~s("#{inner}")
    end
  end

  defp strip_prefix_star(term) do
    if String.ends_with?(term, "*") do
      {String.trim_trailing(term, "*"), true}
    else
      {term, false}
    end
  end
end
