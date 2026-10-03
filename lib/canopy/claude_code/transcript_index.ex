defmodule Canopy.ClaudeCode.TranscriptIndex do
  @moduledoc """
  A line index of Claude Code transcript files
  (`<config dir>/projects/<cwd>/<session id>.jsonl`), so the transcript page
  reads only the lines it shows (`Canopy.ClaudeCode.Transcript`).

  One pass over a file records, for each line the page can show (a prompt,
  an assistant content block, an engine note, a compaction boundary), its
  byte offset and length, kind, engine message id and time. Lines it never
  shows on their own are indexed by what points at them: tool results by
  `tool_use_id`, compaction summaries by their boundary, `prompt_snapshot`
  attachments (the system text) by offset. Everything else (the
  `session_context` attachment with the user's email, environment, skill
  listings, bookkeeping lines) is never kept.

  Files are append-only (Phase 0), so a file that grew is indexed from where
  the last pass stopped, and a partial last line (a turn still writing) is
  left for the next pass. A file that shrank is indexed again. The indexes of
  the 8 most recently used files are kept in ETS; reads go through this
  process so a file is only indexed once at a time.
  """

  use GenServer

  @table __MODULE__
  @max_files 8
  @chunk 1_048_576

  @typedoc "A line the page can show."
  @type line :: %{
          offset: non_neg_integer(),
          length: pos_integer(),
          kind: :prompt | :assistant | :note | :compaction,
          uuid: String.t() | nil,
          message_id: String.t() | nil,
          at: DateTime.t() | nil
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The index of `path`, brought up to date with the file. `{:ok, index}` or
  `{:error, :not_found}`.
  """
  def fetch(path), do: GenServer.call(__MODULE__, {:fetch, path}, :timer.minutes(2))

  @doc "The cached index of `path` as it stands, without touching the file; nil when not cached."
  def cached(path) do
    case :ets.lookup(@table, path) do
      [{^path, index}] -> index
      [] -> nil
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{used: %{}, tick: 0}}
  end

  @impl true
  def handle_call({:fetch, path}, _from, state) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        index =
          case cached(path) do
            %{file_size: ^size, mtime: ^mtime} = index -> index
            %{offset: offset} = index when size >= offset -> extend(index, size, mtime)
            _ -> extend(new(path), size, mtime)
          end

        :ets.insert(@table, {path, index})
        {:reply, {:ok, index}, remember(state, path)}

      {:ok, _} ->
        {:reply, {:error, :not_found}, state}

      {:error, _} ->
        :ets.delete(@table, path)
        {:reply, {:error, :not_found}, %{state | used: Map.delete(state.used, path)}}
    end
  end

  # Least recently used goes first once more than @max_files are cached.
  defp remember(state, path) do
    tick = state.tick + 1
    used = Map.put(state.used, path, tick)

    used =
      if map_size(used) > @max_files do
        {oldest, _} = Enum.min_by(used, &elem(&1, 1))
        :ets.delete(@table, oldest)
        Map.delete(used, oldest)
      else
        used
      end

    %{state | used: used, tick: tick}
  end

  defp new(path) do
    %{
      path: path,
      offset: 0,
      file_size: 0,
      mtime: nil,
      lines: {},
      results: %{},
      summaries: %{},
      snapshots: [],
      last_of: %{},
      compactions: 0
    }
  end

  # Reads from the index's offset to the end, one chunk at a time; a line
  # cut by the end of the file is left for the next pass.
  defp extend(index, size, mtime) do
    {:ok, fd} = :file.open(index.path, [:read, :raw, :binary])

    try do
      acc = %{
        index
        | lines: [],
          snapshots: Enum.reverse(index.snapshots)
      }

      acc = read_from(fd, index.offset, "", index.offset, tuple_size(index.lines), acc)

      %{
        acc
        | lines: List.to_tuple(Tuple.to_list(index.lines) ++ Enum.reverse(acc.lines)),
          snapshots: Enum.reverse(acc.snapshots),
          file_size: size,
          mtime: mtime
      }
    after
      :file.close(fd)
    end
  end

  # `pending` is the start of a line whose end is not read yet, beginning at
  # byte `line_start`; `n` is the position the next kept line takes.
  defp read_from(fd, position, pending, line_start, n, acc) do
    case :file.pread(fd, position, @chunk) do
      {:ok, data} ->
        {pending, line_start, n, acc} = lines(pending <> data, line_start, n, acc)
        read_from(fd, position + byte_size(data), pending, line_start, n, acc)

      :eof ->
        %{acc | offset: line_start}
    end
  end

  defp lines(data, line_start, n, acc) do
    case :binary.match(data, "\n") do
      {at, 1} ->
        line = binary_part(data, 0, at)
        rest = binary_part(data, at + 1, byte_size(data) - at - 1)
        {n, acc} = line(line, line_start, n, acc)
        lines(rest, line_start + at + 1, n, acc)

      :nomatch ->
        {data, line_start, n, acc}
    end
  end

  defp line("", _offset, n, acc), do: {n, acc}

  defp line(bytes, offset, n, acc) do
    case JSON.decode(bytes) do
      {:ok, %{"isSidechain" => true}} -> {n, acc}
      {:ok, %{} = line} -> classify(line, {offset, byte_size(bytes)}, n, acc)
      _ -> {n, acc}
    end
  end

  defp classify(%{"type" => "assistant", "message" => %{} = message} = line, span, n, acc) do
    acc = keep(acc, span, :assistant, line, message["id"])
    acc = if id = message["id"], do: %{acc | last_of: Map.put(acc.last_of, id, n)}, else: acc
    {n + 1, acc}
  end

  defp classify(%{"type" => "user", "isCompactSummary" => true} = line, span, n, acc),
    do: {n, %{acc | summaries: Map.put(acc.summaries, line["parentUuid"], span)}}

  defp classify(%{"type" => "user", "message" => %{"content" => content}} = line, span, n, acc) do
    blocks = if is_list(content), do: content, else: [%{"type" => "text", "text" => content}]

    {results, others} = Enum.split_with(blocks, &match?(%{"type" => "tool_result"}, &1))

    acc =
      Enum.reduce(results, acc, fn %{"tool_use_id" => id}, acc ->
        %{acc | results: Map.put(acc.results, id, span)}
      end)

    cond do
      others == [] -> {n, acc}
      line["isMeta"] == true or command_echo?(others) -> {n + 1, keep(acc, span, :note, line)}
      true -> {n + 1, keep(acc, span, :prompt, line)}
    end
  end

  defp classify(%{"type" => "system", "subtype" => "compact_boundary"} = line, span, n, acc),
    do: {n + 1, %{keep(acc, span, :compaction, line) | compactions: acc.compactions + 1}}

  defp classify(
         %{"type" => "attachment", "attachment" => %{"type" => "prompt_snapshot"}},
         span,
         n,
         acc
       ),
       do: {n, %{acc | snapshots: [span | acc.snapshots]}}

  defp classify(_line, _span, n, acc), do: {n, acc}

  defp keep(acc, {offset, length}, kind, line, message_id \\ nil) do
    rec = %{
      offset: offset,
      length: length,
      kind: kind,
      uuid: line["uuid"],
      message_id: message_id,
      at: Canopy.Engine.TranscriptEntry.time(line["timestamp"])
    }

    %{acc | lines: [rec | acc.lines]}
  end

  # The local command lines `/compact` leaves (`<command-name>`,
  # `<local-command-stdout>`): the engine talking to itself.
  defp command_echo?(blocks) do
    Enum.all?(blocks, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        String.starts_with?(String.trim_leading(text), ["<command-", "<local-command-"])

      _ ->
        false
    end)
  end
end
