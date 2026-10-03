defmodule Canopy.ClaudeCode.Transcript do
  @moduledoc """
  Reads a Claude Code session's transcript from disk for
  `Canopy.Engine.ClaudeCode.transcript/3`, as `Canopy.Engine.TranscriptEntry`s.

  The file is `<config dir>/projects/<encoded cwd>/<session id>.jsonl`. The
  folder name follows the directory's real case, which the repository path
  Canopy stored may not (APFS is case-insensitive), so a miss on the computed
  folder falls back to looking for the session id in every project folder.
  The file found must sit under the config dir and name the session in its
  first message line.

  Pages come from `Canopy.ClaudeCode.TranscriptIndex`: only the lines shown
  are read, plus the results of the tool calls among them (wherever those
  fall). Cursors are byte offsets of lines.

  | Line | Entry |
  |---|---|
  | `user` (a prompt, `promptSource: "sdk"`) | `:prompt`; images become attachments |
  | `assistant` `text` / `thinking` block | `:text`; `:reasoning`, or `:thinking_hidden` when the text is empty |
  | `assistant` `tool_use` + its `tool_result` | `:tool` |
  | last `assistant` line of a `message.id` | then a `:step` with its usage |
  | `system` `compact_boundary` (+ `isCompactSummary`) | `:compaction` with the summary |
  | `isMeta` user lines, `/compact`'s command echoes | `:engine_note`, synthetic |
  | `prompt_snapshot` attachment | `system_prompts` (the last element is Canopy's text) |
  """

  alias Canopy.ClaudeCode.{Events, TranscriptIndex}
  alias Canopy.Engine.TranscriptEntry

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @doc "Reads a page; see `c:Canopy.Engine.transcript/3`."
  def read(config_dir, %{engine_session_id: sid} = ref, opts) do
    with {:ok, path} <- locate(config_dir, sid, Map.get(ref, :directory)),
         {:ok, index} <- TranscriptIndex.fetch(path) do
      {:ok, page(path, index, opts)}
    end
  end

  @doc """
  The transcript file for `sid` under `config_dir`: the folder computed from
  `directory` first, else any project folder. `{:error, :not_found}` for a
  missing file, an id that is not a UUID, or a file that names another session.
  """
  def locate(config_dir, sid, directory \\ nil)

  def locate(config_dir, sid, directory) when is_binary(config_dir) and is_binary(sid) do
    projects = Path.join(Path.expand(config_dir), "projects")

    if Regex.match?(@uuid, sid) do
      file = String.downcase(sid) <> ".jsonl"
      computed = if is_binary(directory), do: Path.join([projects, encode(directory), file])

      others =
        Stream.flat_map([projects], fn dir ->
          Enum.map(list_dir(dir), &Path.join([dir, &1, file]))
        end)

      Stream.concat([computed], others)
      |> Enum.find_value({:error, :not_found}, fn path ->
        if is_binary(path) and inside?(path, projects) and File.regular?(path) and
             session_of(path) == String.downcase(sid),
           do: {:ok, path}
      end)
    else
      {:error, :not_found}
    end
  end

  def locate(_config_dir, _sid, _directory), do: {:error, :not_found}

  @doc "Claude Code's folder name for a working directory: every non-alphanumeric character becomes `-`."
  def encode(directory), do: Regex.replace(~r/[^A-Za-z0-9]/, directory, "-")

  defp list_dir(path) do
    case File.ls(path) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  defp inside?(path, root), do: String.starts_with?(Path.expand(path), root <> "/")

  # The session id of the file's first message line.
  defp session_of(path) do
    with {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(fd, 0, 65_536) do
          {:ok, data} ->
            data
            |> String.split("\n")
            |> Enum.find_value(fn line ->
              case JSON.decode(line) do
                {:ok, %{"sessionId" => sid}} when is_binary(sid) -> String.downcase(sid)
                _ -> nil
              end
            end)

          _ ->
            nil
        end
      after
        :file.close(fd)
      end
    else
      _ -> nil
    end
  end

  # -- Pages --------------------------------------------------------------------

  defp page(path, index, opts) do
    lines = index.lines
    n = tuple_size(lines)

    find = %{
      before: &at_offset(lines, &1, :first_at_or_after),
      after: &at_offset(lines, &1, :last_at_or_before),
      message_id: fn id -> find_index(lines, &(&1.message_id == id)) end,
      at: fn at -> find_index(lines, &(&1.at && DateTime.compare(&1.at, at) != :lt)) end,
      prompt?: fn i -> elem(lines, i).kind == :prompt end
    }

    {start, stop} = TranscriptEntry.window(n, Keyword.get(opts, :limit, 50), opts, find)
    shown = for i <- start..(stop - 1)//1, do: {i, elem(lines, i)}

    {:ok, fd} = :file.open(path, [:read, :raw, :binary])

    try do
      decoded = read_lines(fd, Enum.map(shown, fn {_i, rec} -> {rec.offset, rec.length} end))
      results = tool_results(fd, index, decoded)

      entries =
        shown
        |> Enum.zip(decoded)
        |> Enum.flat_map(fn {{i, rec}, line} -> entries(rec, line, i, index, results, fd) end)

      %{
        entries: entries,
        before: if(start > 0 and shown != [], do: shown |> hd() |> elem(1) |> cursor()),
        after:
          if(shown != [], do: shown |> List.last() |> elem(1) |> cursor(), else: opts[:after]),
        newer?: stop < n,
        system_prompts: system_prompts(fd, index.snapshots),
        total: n,
        compactions: index.compactions
      }
    after
      :file.close(fd)
    end
  end

  defp cursor(rec), do: Integer.to_string(rec.offset)

  defp read_lines(_fd, []), do: []

  defp read_lines(fd, spans) do
    {:ok, chunks} = :file.pread(fd, spans)

    Enum.map(chunks, fn
      bytes when is_binary(bytes) ->
        case JSON.decode(bytes) do
          {:ok, %{} = line} -> line
          _ -> %{}
        end

      _eof ->
        %{}
    end)
  end

  defp at_offset(lines, cursor, mode) do
    case Integer.parse(to_string(cursor)) do
      {offset, ""} -> search(lines, offset, mode, 0, tuple_size(lines) - 1, nil)
      _ -> nil
    end
  end

  # Binary search over the offsets (ascending).
  defp search(_lines, _offset, :first_at_or_after, lo, hi, found) when lo > hi,
    do: found || hi + 1

  defp search(_lines, _offset, :last_at_or_before, lo, hi, found) when lo > hi, do: found

  defp search(lines, offset, mode, lo, hi, found) do
    mid = div(lo + hi, 2)
    at = elem(lines, mid).offset

    case mode do
      :first_at_or_after when at >= offset -> search(lines, offset, mode, lo, mid - 1, mid)
      :first_at_or_after -> search(lines, offset, mode, mid + 1, hi, found)
      :last_at_or_before when at <= offset -> search(lines, offset, mode, mid + 1, hi, mid)
      :last_at_or_before -> search(lines, offset, mode, lo, mid - 1, found)
    end
  end

  defp find_index(tuple, fun) do
    Enum.find(0..(tuple_size(tuple) - 1)//1, fn i -> fun.(elem(tuple, i)) end)
  end

  # tool_use_id => {result block, its line}, for every call on the page.
  defp tool_results(fd, index, decoded) do
    ids =
      for %{"type" => "assistant", "message" => %{"content" => blocks}} <- decoded,
          is_list(blocks),
          %{"type" => "tool_use", "id" => id} <- blocks,
          Map.has_key?(index.results, id),
          uniq: true,
          do: id

    spans = Enum.map(ids, &Map.fetch!(index.results, &1))

    ids
    |> Enum.zip(read_lines(fd, spans))
    |> Map.new(fn {id, line} ->
      blocks = get_in(line, ["message", "content"])
      blocks = if is_list(blocks), do: blocks, else: []
      block = Enum.find(blocks, %{}, &(&1["tool_use_id"] == id))
      {id, {block, line}}
    end)
  end

  # -- Lines to entries -----------------------------------------------------------

  defp entries(%{kind: :prompt} = rec, line, _i, _index, _results, _fd) do
    blocks = content_blocks(line)

    [
      %TranscriptEntry{
        id: rec.uuid || "line-#{rec.offset}",
        kind: :prompt,
        at: rec.at,
        text: blocks |> texts() |> blank_to_nil(),
        attachments: attachments(blocks)
      }
    ]
  end

  defp entries(%{kind: :note} = rec, line, _i, _index, _results, _fd) do
    [
      %TranscriptEntry{
        id: rec.uuid || "line-#{rec.offset}",
        kind: :engine_note,
        at: rec.at,
        text: line |> content_blocks() |> texts(),
        synthetic?: true
      }
    ]
  end

  defp entries(%{kind: :compaction} = rec, line, _i, index, _results, fd) do
    meta = line["compactMetadata"] || line["compact_metadata"] || %{}

    summary =
      case Map.fetch(index.summaries, rec.uuid) do
        {:ok, span} -> fd |> read_lines([span]) |> hd() |> content_blocks() |> texts()
        :error -> nil
      end

    [
      %TranscriptEntry{
        id: rec.uuid || "line-#{rec.offset}",
        kind: :compaction,
        at: rec.at,
        compaction: %{
          trigger: if(meta["trigger"] == "manual", do: :manual, else: :auto),
          pre_tokens: meta["preTokens"],
          post_tokens: meta["postTokens"],
          summary: blank_to_nil(summary)
        }
      }
    ]
  end

  defp entries(%{kind: :assistant} = rec, line, i, index, results, _fd) do
    message = line["message"] || %{}
    blocks = if is_list(message["content"]), do: message["content"], else: []
    base = %{at: rec.at, message_id: rec.message_id}

    rows =
      blocks
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, b} ->
        id = "#{rec.uuid || "line-#{rec.offset}"}-#{b}"
        block_entry(block, id, base, line, results)
      end)

    # the group's last line closes the model call
    if rec.message_id && Map.get(index.last_of, rec.message_id) == i do
      rows ++
        [
          %TranscriptEntry{
            id: "step-" <> rec.message_id,
            kind: :step,
            at: rec.at,
            message_id: rec.message_id,
            step: %{tokens: Events.tokens(message["usage"]), cost: nil, model: message["model"]}
          }
        ]
    else
      rows
    end
  end

  defp block_entry(%{"type" => "text", "text" => text}, id, base, _line, _results) do
    if blank_to_nil(text),
      do: [struct(TranscriptEntry, Map.merge(base, %{id: id, kind: :text, text: text}))],
      else: []
  end

  defp block_entry(%{"type" => "thinking"} = block, id, base, _line, _results) do
    case blank_to_nil(block["thinking"]) do
      nil -> [struct(TranscriptEntry, Map.merge(base, %{id: id, kind: :thinking_hidden}))]
      text -> [struct(TranscriptEntry, Map.merge(base, %{id: id, kind: :reasoning, text: text}))]
    end
  end

  defp block_entry(%{"type" => "redacted_thinking"}, id, base, _line, _results),
    do: [struct(TranscriptEntry, Map.merge(base, %{id: id, kind: :thinking_hidden}))]

  defp block_entry(%{"type" => "tool_use", "id" => call_id} = block, id, base, line, results) do
    name = block["name"] || "tool"
    input = block["input"] || %{}

    {status, output, duration} =
      case Map.fetch(results, call_id) do
        {:ok, {result, result_line}} ->
          ended = TranscriptEntry.time(result_line["timestamp"])

          duration =
            if base.at && ended,
              do: max(DateTime.diff(ended, base.at, :millisecond), 0)

          status = if result["is_error"] == true, do: :error, else: :ok
          {status, result_text(result["content"]), duration}

        :error ->
          {:running, nil, nil}
      end

    {output, truncated?} = TranscriptEntry.cap_output(output)

    tool = %{
      name: name,
      call_id: call_id,
      title: Events.title(name, input, line["cwd"]),
      input: TranscriptEntry.cap_input(input),
      output: output,
      status: status,
      duration_ms: duration,
      truncated?: truncated?
    }

    [struct(TranscriptEntry, Map.merge(base, %{id: id, kind: :tool, tool: tool}))]
  end

  defp block_entry(_block, _id, _base, _line, _results), do: []

  defp content_blocks(line) do
    case get_in(line, ["message", "content"]) do
      text when is_binary(text) -> [%{"type" => "text", "text" => text}]
      blocks when is_list(blocks) -> blocks
      _ -> []
    end
  end

  defp texts(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n\n")
  end

  # Bytes never leave the adapter: an image or document block is its kind and type.
  defp attachments(blocks) do
    for %{"type" => type} = block <- blocks, type in ["image", "document"] do
      %{
        kind: if(type == "image", do: :image, else: :file),
        name: block["title"],
        mime: get_in(block, ["source", "media_type"])
      }
    end
  end

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image"} -> "[image]"
      %{"type" => "tool_reference", "tool_name" => name} -> "[tool #{name}]"
      %{"type" => type} -> "[#{type}]"
      other -> inspect(other)
    end)
  end

  defp result_text(nil), do: nil
  defp result_text(other), do: inspect(other)

  # The system text per snapshot, a new entry each time it changed (Claude
  # Code writes two at each process start, the second with its tool list).
  defp system_prompts(_fd, []), do: []

  defp system_prompts(fd, spans) do
    fd
    |> read_lines(spans)
    |> Enum.flat_map(fn line ->
      case get_in(line, ["attachment", "systemPrompt"]) do
        [_ | _] = parts -> [{TranscriptEntry.time(line["timestamp"]), parts}]
        _ -> []
      end
    end)
    |> Enum.dedup_by(&elem(&1, 1))
    |> Enum.map(fn {at, parts} ->
      %{at: at, canopy: List.last(parts), engine: Enum.drop(parts, -1)}
    end)
  end

  defp blank_to_nil(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp blank_to_nil(_), do: nil
end
