defmodule Canopy.Engine.TranscriptEntry do
  @moduledoc """
  One row of an engine session's transcript (`Canopy.Engine.transcript/4`),
  normalized so the transcript page never sees an engine's history format.

  `kind` is one of:

    * `:prompt` — what Canopy sent (`text`, `attachments`)
    * `:text` — the model's text between tool calls
    * `:reasoning` — reasoning text the engine kept
    * `:thinking_hidden` — the model thought, but the engine kept no text
    * `:tool` — a call and its result, paired (`tool`)
    * `:step` — one model call's usage (`step`)
    * `:compaction` — the context was summarised here (`compaction`)
    * `:engine_note` — something the engine added itself (`synthetic?` hides it by default)

  and two that only `Canopy.Transcripts` adds: `:turn` (a Canopy turn
  divider, `turn`) and `:system_changed` (the system text changed, `text`).

  `message_id` is the engine message id, the same one the adapters put on
  `:step_completed` events, so a turn summary's ids find their place here.
  Strings are redacted by `Canopy.Transcripts` before anything shows them;
  bytes (images, files) never get this far, only `attachments` metadata.
  """

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    :at,
    :message_id,
    :text,
    :tool,
    :step,
    :compaction,
    :turn,
    attachments: [],
    synthetic?: false,
    redacted?: false,
    steered?: false
  ]

  @type tool :: %{
          name: String.t(),
          call_id: String.t() | nil,
          title: String.t() | nil,
          input: String.t() | nil,
          output: String.t() | nil,
          status: :ok | :error | :running | :denied,
          duration_ms: non_neg_integer() | nil,
          truncated?: boolean()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          at: DateTime.t() | nil,
          message_id: String.t() | nil,
          text: String.t() | nil,
          tool: tool() | nil,
          step: %{tokens: map(), cost: number() | nil, model: String.t() | nil} | nil,
          compaction:
            %{
              trigger: :auto | :manual,
              pre_tokens: integer() | nil,
              post_tokens: integer() | nil,
              summary: String.t() | nil
            }
            | nil,
          turn: map() | nil,
          attachments: [%{kind: :image | :file, name: String.t() | nil, mime: String.t() | nil}],
          synthetic?: boolean(),
          redacted?: boolean(),
          steered?: boolean()
        }

  @output_head 4_096
  @output_tail 12_288
  @input_cap 8_192

  @doc """
  A tool's output as the page keeps it: up to 16 KB, the first 4 KB and the
  last 12 KB when longer. `{text, truncated?}`.
  """
  def cap_output(nil), do: {nil, false}

  def cap_output(text) when is_binary(text) do
    if byte_size(text) <= @output_head + @output_tail do
      {text, false}
    else
      head = text |> binary_part(0, @output_head) |> String.replace_invalid()
      tail = text |> binary_part(byte_size(text) - @output_tail, @output_tail)
      tail = String.replace_invalid(tail)
      cut = byte_size(text) - @output_head - @output_tail
      {head <> "\n… #{div(cut, 1024)} KB not shown …\n" <> tail, true}
    end
  end

  def cap_output(other), do: cap_output(inspect(other))

  @doc "A tool's input, pretty-printed and capped at 8 KB."
  def cap_input(nil), do: nil
  def cap_input(input) when input == %{}, do: nil

  def cap_input(input) do
    text =
      case input do
        text when is_binary(text) -> text
        other -> pretty(other)
      end

    if byte_size(text) > @input_cap,
      do: String.replace_invalid(binary_part(text, 0, @input_cap)) <> "\n…",
      else: text
  end

  defp pretty(term) do
    Jason.encode!(term, pretty: true)
  rescue
    _ -> inspect(term, pretty: true, limit: 200)
  end

  @doc "A wall-clock time from milliseconds since the epoch, or an ISO 8601 string."
  def time(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  def time(ms) when is_float(ms), do: time(trunc(ms))

  def time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  def time(_), do: nil

  @doc """
  Pages through `entries` (a whole session, oldest first) the way
  `Canopy.Engine.transcript/4` describes, using entry ids as cursors.
  `prompt?` tells where a turn begins, for `around: {:message_id, id}`.
  """
  def page(entries, opts) do
    tuple = List.to_tuple(entries)
    n = tuple_size(tuple)
    limit = Keyword.get(opts, :limit, 50)
    index_of = fn id -> Enum.find_index(entries, &(&1.id == id)) end

    {start, stop} =
      window(n, limit, opts, %{
        before: index_of,
        after: index_of,
        message_id: fn id -> Enum.find_index(entries, &(&1.message_id == id)) end,
        at: fn at -> Enum.find_index(entries, &(&1.at && DateTime.compare(&1.at, at) != :lt)) end,
        prompt?: fn i -> elem(tuple, i).kind == :prompt end
      })

    page = if stop > start, do: Enum.slice(entries, start, stop - start), else: []

    %{
      entries: page,
      before: if(start > 0 and page != [], do: hd(page).id),
      after: if(page != [], do: List.last(page).id, else: opts[:after]),
      newer?: stop < n
    }
  end

  @doc """
  The `{start, stop}` slice of `n` rows a page covers. `find` answers, for
  the cursor options, the row index of a cursor (`before`, `after`), of the
  first row of an engine message (`message_id`) and of the first row at or
  after a time (`at`), and whether a row starts a turn (`prompt?`).
  """
  def window(n, limit, opts, find) do
    cond do
      cursor = opts[:before] ->
        stop = find.before.(cursor) || n
        {max(stop - limit, 0), stop}

      cursor = opts[:after] ->
        start = (find.after.(cursor) || n - 1) + 1
        {min(start, n), min(start + limit, n)}

      around = opts[:around] ->
        case anchor(around, find, opts) do
          nil -> {max(n - limit, 0), n}
          i -> {i, min(i + limit, n)}
        end

      true ->
        {max(n - limit, 0), n}
    end
  end

  # A message id lands on the prompt of the turn that produced it (the
  # nearest row before it that starts a turn); a time lands on the first row
  # at or after it. An unknown message id falls back to `fallback_at`.
  defp anchor({:message_id, id}, find, opts) do
    case find.message_id.(id) do
      nil ->
        if at = opts[:fallback_at], do: find.at.(at)

      i ->
        Enum.find(i..0//-1, i, find.prompt?)
    end
  end

  defp anchor({:at, %DateTime{} = at}, find, _opts), do: find.at.(at)
  defp anchor(_around, _find, _opts), do: nil
end
