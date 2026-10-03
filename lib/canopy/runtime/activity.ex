defmodule Canopy.Runtime.Activity do
  @moduledoc """
  Folds an agent's execution events into the activity card shown in a
  channel: one row per tool call, and one per piece of text the agent wrote
  between calls (its narration, streamed as it arrives), in the order they
  happened. Each row remembers the model step (the model call) it came from,
  so the card can group rows under the narration that led to them.

  Around the rows the card keeps what its header shows, counted as events
  arrive so it stays exact when rows are capped: per-category tallies,
  errors, tokens, cost, and the files the turn changed (chips with line
  counts). It also keeps per-row details (the input, an excerpt of the
  output, the error, an edit's patch), shown when a row is opened.

  The channel runtime stamps and slims each event (`slim_event/1`), folds it
  with `fold/2`, and broadcasts the same slim event, so every channel view
  folds the same card. When the turn ends the card is stored: its rows on the
  `agent_turn_completed` timeline event (`to_payload/1`, `meta_payload/1`),
  and its details in `Canopy.Timeline.ActivityDetails` (`details_payload/1`).
  `card_from_payload/1` reads a stored card back, including the first
  version's rows (no categories, durations, or details).
  """

  alias Canopy.Engine.Event

  @max_entries 300
  @text_chars 1_500
  @command_chars 2_000
  @label_chars 200
  @input_chars 4_000
  @error_chars 4_000
  @output_chars 8_000
  @head_lines 40
  @tail_lines 80

  @kinds ~w(tool file step diff text)a
  @statuses ~w(running ok error)a
  @categories ~w(shell read search edit web canopy plan agent other)a

  @type entry :: %{
          required(:key) => String.t(),
          required(:kind) => :tool | :text | :file | :step | :diff,
          required(:status) => :running | :ok | :error,
          required(:label) => String.t(),
          required(:detail) => String.t() | nil,
          optional(atom) => term
        }

  @type card :: %{
          entries: [entry],
          tool_count: non_neg_integer,
          cost: float,
          tallies: %{atom => non_neg_integer},
          dropped: non_neg_integer,
          tokens: non_neg_integer,
          steps: [map],
          files: [map],
          details: %{String.t() => map},
          started_at: integer | nil,
          model: String.t() | nil,
          version: 1 | 2
        }

  @doc "An empty card; `started_at` (wall-clock ms) drives the live elapsed time."
  @spec new(integer | nil) :: card
  def new(started_at \\ nil) do
    %{
      entries: [],
      tool_count: 0,
      cost: 0.0,
      tallies: %{},
      dropped: 0,
      tokens: 0,
      steps: [],
      files: [],
      details: %{},
      started_at: started_at,
      model: nil,
      version: 2
    }
  end

  @doc "Folds a list of events, oldest first, into a card."
  @spec fold_all([Event.t()]) :: card
  def fold_all(events), do: Enum.reduce(events, new(), &fold/2)

  @spec fold(Event.t(), card) :: card
  def fold(%Event{type: type, data: data}, card)
      when type in [:tool_started, :tool_completed] do
    card = stamp_start(card, data)
    key = data[:call_id] || data[:part_id] || unique_key()
    previous = find(card, key)

    status =
      cond do
        type == :tool_started -> :running
        data[:status] == :error -> :error
        true -> :ok
      end

    entry = tool_entry(previous || %{}, key, data, status, card)

    card
    |> count_call(previous, entry)
    |> count_error(previous, entry)
    |> put_details(key, data, entry)
    |> put_entry(entry)
    |> edit_chip(entry)
  end

  # A changed file becomes a chip; the edit call that wrote it is marked.
  def fold(%Event{type: :file_changed, data: %{path: path} = data}, card) when is_binary(path) do
    card = stamp_start(card, data)

    entries =
      Enum.map(card.entries, fn entry ->
        if Map.get(entry, :category) == :edit and Map.get(entry, :path) == path,
          do: Map.put(entry, :changed, true),
          else: entry
      end)

    put_chip(%{card | entries: entries}, path, nil)
  end

  # OpenCode sends the same step-finish part more than once; its part id
  # counts it once.
  def fold(%Event{type: :step_completed, data: data}, card) do
    card = stamp_start(card, data)
    key = "step-" <> (data[:part_id] || unique_key())

    if Enum.any?(card.steps, &(&1.key == key)) do
      card
    else
      cost = if is_number(data[:cost]), do: data[:cost], else: 0.0
      tokens = token_total(data[:tokens])

      %{
        card
        | steps: card.steps ++ [%{key: key, tokens: tokens, cost: cost}],
          tokens: card.tokens + tokens,
          cost: card.cost + cost
      }
    end
  end

  # Text streams into one running entry per part, in its place among the tool
  # rows; the finished part replaces it. Claude Code keys its deltas by block
  # index and the finished text by message, so a finished text also claims the
  # running entry it streamed into when no entry carries its own key.
  def fold(%Event{type: :text_delta, data: %{delta: delta} = data}, card) when is_binary(delta) do
    card = stamp_start(card, data)
    key = "text-" <> (data[:part_id] || "current")
    previous = find(card, key)
    text = if previous, do: Map.get(previous, :text, "") <> delta, else: delta

    put_entry(card, text_entry(previous, key, text, :running, card))
  end

  def fold(%Event{type: :text_done, data: %{text: text} = data}, card) when is_binary(text) do
    card = stamp_start(card, data)
    key = "text-" <> (data[:part_id] || unique_key())

    {claimed, card} =
      case {find(card, key), List.last(card.entries)} do
        {nil, %{kind: :text, status: :running, key: running} = entry} ->
          {entry, %{card | entries: Enum.reject(card.entries, &(&1.key == running))}}

        {previous, _} ->
          {previous, card}
      end

    if String.trim(text) == "",
      do: %{card | entries: Enum.reject(card.entries, &(&1.key == key))},
      else: put_entry(card, text_entry(claimed, key, text, :ok, card))
  end

  # Diff and patch events add no rows: their line counts go to the edit row
  # that wrote the file, and to its chip; a file nothing on the card wrote
  # (an edit made by a shell command) gets a chip of its own.
  def fold(%Event{type: :diff, data: %{files: files}}, card) when is_list(files) do
    Enum.reduce(files, card, fn file, card ->
      case diff_file(file) do
        {nil, _adds, _dels} ->
          card

        {path, adds, dels} ->
          card
          |> stats_to_row(path, adds, dels)
          |> put_chip(path, if(adds || dels, do: {adds || 0, dels || 0}))
      end
    end)
  end

  def fold(%Event{type: :patch, data: data}, card) do
    data
    |> Map.get(:files)
    |> List.wrap()
    |> Enum.reduce(card, fn file, card ->
      case diff_file(file) do
        {nil, _, _} -> card
        {path, _, _} -> put_chip(card, path, nil)
      end
    end)
  end

  def fold(_event, card), do: card

  # -- Slimming --------------------------------------------------------------

  @doc """
  The event as the channel views receive it: outputs, errors and patches cut
  to excerpts (head and tail lines, at most #{@output_chars} characters), long
  input values capped, and the engine's raw metadata dropped (the adapters
  lift what the card reads out of it). A cut output records its full line
  count as `output_lines`.
  """
  @spec slim_event(Event.t()) :: Event.t()
  def slim_event(%Event{type: type, data: data} = event)
      when type in [:tool_started, :tool_completed] do
    data =
      data
      |> slim_text(:output)
      |> slim_text(:stdout)
      |> slim_text(:stderr)
      |> cap_field(:error, @error_chars)
      |> cap_field(:patch, @output_chars)
      |> Map.update(:input, %{}, &cap_input/1)
      |> then(&if(Map.has_key?(&1, :metadata), do: Map.put(&1, :metadata, %{}), else: &1))

    %{event | data: data}
  end

  def slim_event(event), do: event

  defp slim_text(data, field) do
    case Map.get(data, field) do
      text when is_binary(text) ->
        case excerpt(text) do
          {^text, _} ->
            data

          {cut, _} ->
            data
            |> Map.put(field, cut)
            |> Map.put_new(:output_lines, line_count(text))
        end

      _ ->
        data
    end
  end

  defp cap_field(data, field, max) do
    case Map.get(data, field) do
      text when is_binary(text) -> Map.put(data, field, truncate(text, max))
      _ -> data
    end
  end

  defp cap_input(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_binary(v) -> {k, truncate(v, @input_chars)}
      {k, v} when is_map(v) or is_list(v) -> {k, cap_nested(v)}
      other -> other
    end)
  end

  defp cap_input(input), do: input

  defp cap_nested(value) do
    text = inspect(value, limit: 50, printable_limit: @input_chars)
    if String.length(text) > @input_chars, do: truncate(text, @input_chars), else: value
  end

  @doc """
  The head and tail of a long text, with a line saying how much was left out
  between them: the first #{@head_lines} and last #{@tail_lines} lines, then
  at most #{@output_chars} characters. Returns `{excerpt, cut?}`.
  """
  @spec excerpt(String.t()) :: {String.t(), boolean}
  def excerpt(text) when is_binary(text) do
    lines = String.split(text, "\n")
    total = length(lines)

    {lines, cut?} =
      if total > @head_lines + @tail_lines + 1 do
        omitted = total - @head_lines - @tail_lines

        {Enum.take(lines, @head_lines) ++
           ["⋯ #{omitted} lines omitted ⋯"] ++ Enum.take(lines, -@tail_lines), true}
      else
        {lines, false}
      end

    joined = Enum.join(lines, "\n")

    if String.length(joined) > @output_chars do
      head = String.slice(joined, 0, div(@output_chars, 4))
      tail = String.slice(joined, -div(@output_chars * 3, 4), div(@output_chars * 3, 4))
      {head <> "\n⋯ cut ⋯\n" <> tail, true}
    else
      {joined, cut?}
    end
  end

  defp line_count(text), do: text |> String.split("\n") |> length()

  # -- Rows ------------------------------------------------------------------

  defp tool_entry(prev, key, data, status, card) do
    input = if is_map(data[:input]), do: data[:input], else: %{}
    tool = present(data[:tool]) || Map.get(prev, :tool)
    category = category(tool)
    command = command_of(input) || Map.get(prev, :command)
    path = path_of(input) || Map.get(prev, :path)
    description = present(input["description"]) || Map.get(prev, :description)

    started_at = time_of(data, "start") || Map.get(prev, :started_at) || data[:at]
    ended_at = if status != :running, do: time_of(data, "end") || data[:at]

    duration =
      if is_integer(started_at) and is_integer(ended_at) and ended_at >= started_at,
        do: ended_at - started_at,
        else: Map.get(prev, :duration_ms)

    exit_code = integer(data[:exit_code]) || Map.get(prev, :exit_code)

    # OpenCode reports a command that exited non-zero as completed; it failed
    status =
      if status == :ok and category == :shell and is_integer(exit_code) and exit_code != 0,
        do: :error,
        else: status

    adds = integer(data[:adds]) || Map.get(prev, :adds)
    dels = integer(data[:dels]) || Map.get(prev, :dels)
    denied = data[:denied] == true or Map.get(prev, :denied) == true

    label =
      primary_label(category, tool, input, command, path) || present(data[:title]) ||
        Map.get(prev, :label) || tool || "tool"

    %{
      key: key,
      kind: Map.get(prev, :kind, :tool),
      status: status,
      label: truncate(label, @label_chars),
      detail: if(status == :error, do: first_line(present(data[:error])), else: nil),
      tool: tool,
      category: category,
      command: command,
      path: path,
      description: description,
      step: Map.get(prev, :step, current_step(card)),
      started_at: started_at,
      duration_ms: duration,
      exit_code: exit_code,
      adds: adds,
      dels: dels,
      denied: denied,
      changed: Map.get(prev, :changed, false),
      fact: fact(category, exit_code, adds, dels, integer(data[:matches]), input) || prev[:fact]
    }
  end

  defp text_entry(previous, key, text, status, card) do
    %{
      key: key,
      kind: :text,
      status: status,
      label: truncate(String.trim_leading(text), @text_chars),
      detail: nil,
      category: :note,
      step:
        if(previous, do: Map.get(previous, :step, current_step(card)), else: current_step(card)),
      text: text
    }
  end

  # What a row is about, by category: the command, the path, the pattern.
  defp primary_label(:shell, _tool, _input, command, _path) when is_binary(command),
    do: first_line(command)

  defp primary_label(category, _tool, _input, _command, path)
       when category in [:read, :edit] and is_binary(path),
       do: path

  defp primary_label(:search, _tool, input, _command, _path),
    do: present(input["pattern"]) || present(input["query"])

  defp primary_label(:web, _tool, input, _command, _path),
    do: present(input["url"]) || present(input["query"])

  defp primary_label(:agent, _tool, input, _command, _path), do: present(input["description"])

  defp primary_label(:canopy, tool, _input, _command, _path) when is_binary(tool),
    do: "canopy " <> canopy_name(tool)

  defp primary_label(_category, _tool, _input, _command, _path), do: nil

  # A short fact for the row: the exit code, line counts, matches, a target.
  defp fact(:shell, code, _adds, _dels, _matches, _input) when is_integer(code),
    do: "exit #{code}"

  defp fact(_category, _code, adds, dels, _matches, _input)
       when is_integer(adds) or is_integer(dels),
       do: "+#{adds || 0} −#{dels || 0}"

  defp fact(_category, _code, _adds, _dels, 1, _input), do: "1 match"
  defp fact(_category, _code, _adds, _dels, n, _input) when is_integer(n), do: "#{n} matches"

  defp fact(:canopy, _code, _adds, _dels, _matches, input) do
    case present(input["channel"]) || present(input["channel_name"]) do
      nil -> nil
      "#" <> _ = name -> "→ " <> name
      name -> "→ #" <> name
    end
  end

  defp fact(_category, _code, _adds, _dels, _matches, _input), do: nil

  @doc """
  The family a tool belongs to, for the row's icon and colour and the
  card's filters: shell, read, search, edit, web, canopy (Canopy's own
  tools), plan, agent, or other.
  """
  @spec category(String.t() | nil) :: atom
  def category(nil), do: :other

  def category(tool) when is_binary(tool) do
    name = String.downcase(tool)

    cond do
      String.starts_with?(name, "mcp__canopy__") or String.starts_with?(name, "canopy") -> :canopy
      name in ~w(bash shell) -> :shell
      name in ~w(read ls list notebookread view) -> :read
      name in ~w(grep glob find codesearch toolsearch) -> :search
      name in ~w(edit write multiedit notebookedit patch apply_patch) -> :edit
      name in ~w(webfetch websearch fetch) -> :web
      name in ~w(todowrite todoread exitplanmode) -> :plan
      name in ~w(task agent) -> :agent
      true -> :other
    end
  end

  defp canopy_name("mcp__canopy__" <> name), do: name
  defp canopy_name("canopy_" <> name), do: name
  defp canopy_name(other), do: other

  defp command_of(%{"command" => c}) when is_binary(c), do: truncate(c, @command_chars)
  defp command_of(%{command: c}) when is_binary(c), do: truncate(c, @command_chars)
  defp command_of(_), do: nil

  # The file an edit or read call is about, so a file change can mark the row
  # that wrote it (which keeps the mark, and the path, through later updates).
  defp path_of(input) when is_map(input) do
    Enum.find_value(~w(file_path filePath path notebook_path), fn key ->
      case Map.get(input, key) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end

  defp time_of(data, key) do
    case data[:time] do
      %{} = time -> integer(Map.get(time, key) || Map.get(time, String.to_existing_atom(key)))
      _ -> nil
    end
  end

  # The card's start is its first event, unless the runtime set it.
  defp stamp_start(%{started_at: nil} = card, %{at: at}) when is_integer(at),
    do: %{card | started_at: at}

  defp stamp_start(card, _data), do: card

  defp current_step(card), do: length(card.steps)

  # A call counts from its first event, so the header matches the rows while
  # one is still running; its later updates don't count again.
  defp count_call(card, nil, entry) do
    %{
      card
      | tool_count: card.tool_count + 1,
        tallies: Map.update(card.tallies, entry.category, 1, &(&1 + 1))
    }
  end

  defp count_call(card, _previous, _entry), do: card

  defp count_error(card, previous, %{status: :error})
       when previous == nil or previous.status != :error,
       do: %{card | tallies: Map.update(card.tallies, :errors, 1, &(&1 + 1))}

  defp count_error(card, _previous, _entry), do: card

  # What opening the row shows; later events add to what earlier ones gave.
  defp put_details(card, key, data, entry) do
    input = if is_map(data[:input]), do: data[:input], else: %{}
    error = if is_binary(data[:error]), do: truncate(data[:error], @error_chars)
    stdout = data[:stdout]
    output = if is_binary(stdout), do: stdout, else: data[:output]
    output = if is_binary(output) and output != error, do: output

    {output_text, cut?} =
      if is_binary(output) and String.trim(output) != "", do: excerpt(output), else: {nil, false}

    stderr =
      if is_binary(data[:stderr]) and String.trim(data[:stderr]) != "",
        do: elem(excerpt(data[:stderr]), 0)

    new =
      %{
        "input" => input_text(entry, input),
        "output" => output_text,
        "output_lines" => if(output_text, do: data[:output_lines] || line_count(output)),
        "truncated" =>
          if(cut? or data[:truncated] == true or is_integer(data[:output_lines]), do: true),
        "stderr" => stderr,
        "error" => error,
        "patch" => if(is_binary(data[:patch]), do: truncate(data[:patch], @output_chars)),
        "interrupted" => if(data[:interrupted] == true, do: true)
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    if new == %{},
      do: card,
      else: %{card | details: Map.update(card.details, key, new, &Map.merge(&1, new))}
  end

  defp input_text(%{category: :shell, command: command}, _input) when is_binary(command),
    do: command

  defp input_text(_entry, input) when map_size(input) == 0, do: nil

  defp input_text(_entry, input) do
    case Jason.encode(input, pretty: true) do
      {:ok, json} -> truncate(json, @input_chars)
      _ -> truncate(inspect(input), @input_chars)
    end
  end

  # A finished edit's line counts go to its file's chip.
  defp edit_chip(card, %{category: :edit, path: path, status: :ok} = entry)
       when is_binary(path) do
    stats = if entry.adds || entry.dels, do: {entry.key, {entry.adds || 0, entry.dels || 0}}
    put_chip(card, path, stats)
  end

  defp edit_chip(card, _entry), do: card

  # One chip per file, in the order they first changed. Line counts come from
  # the edits that wrote it (summed, one per call) or, failing those, from a
  # diff event. Memory under .canopy/ is not work, and gets no chip.
  defp put_chip(card, path, stats) do
    if String.contains?(path, "/.canopy/") or String.starts_with?(path, ".canopy/") do
      card
    else
      chip =
        Enum.find(card.files, &(&1.path == path)) || %{path: path, edits: %{}, diff: nil}

      chip =
        case stats do
          {key, {_a, _d} = counts} when is_binary(key) ->
            %{chip | edits: Map.put(chip.edits, key, counts)}

          {_a, _d} = counts ->
            %{chip | diff: counts}

          nil ->
            chip
        end

      files =
        if Enum.any?(card.files, &(&1.path == path)),
          do: Enum.map(card.files, &if(&1.path == path, do: chip, else: &1)),
          else: card.files ++ [chip]

      %{card | files: files}
    end
  end

  @doc "A chip's `{adds, dels}`, or nil when nothing counted its lines."
  def chip_stats(%{edits: edits}) when map_size(edits) > 0 do
    Enum.reduce(Map.values(edits), {0, 0}, fn {a, d}, {sa, sd} -> {sa + a, sd + d} end)
  end

  def chip_stats(%{diff: {_a, _d} = diff}), do: diff
  def chip_stats(_chip), do: nil

  defp stats_to_row(card, path, adds, dels) when is_integer(adds) or is_integer(dels) do
    entries =
      Enum.map(card.entries, fn entry ->
        if Map.get(entry, :category) == :edit and is_nil(Map.get(entry, :adds)) and
             same_file?(Map.get(entry, :path), path),
           do: %{entry | adds: adds || 0, dels: dels || 0, fact: "+#{adds || 0} −#{dels || 0}"},
           else: entry
      end)

    %{card | entries: entries}
  end

  defp stats_to_row(card, _path, _adds, _dels), do: card

  defp same_file?(a, b) when is_binary(a) and is_binary(b),
    do: a == b or String.ends_with?(a, "/" <> b) or String.ends_with?(b, "/" <> a)

  defp same_file?(_a, _b), do: false

  defp diff_file(%{} = file) do
    path = file["file"] || file["path"] || file["filePath"] || file[:file] || file[:path]

    {if(is_binary(path), do: path), integer(file["additions"] || file[:additions]),
     integer(file["deletions"] || file[:deletions])}
  end

  defp diff_file(path) when is_binary(path), do: {path, nil, nil}
  defp diff_file(_), do: {nil, nil, nil}

  # New rows go at the end; past the cap the oldest finished row goes, and
  # the card counts it so it can say how many it no longer shows.
  defp put_entry(card, %{key: key} = entry) do
    if Enum.any?(card.entries, &(&1.key == key)) do
      %{card | entries: Enum.map(card.entries, &if(&1.key == key, do: entry, else: &1))}
    else
      evict(%{card | entries: card.entries ++ [entry]})
    end
  end

  defp evict(%{entries: entries} = card) when length(entries) <= @max_entries, do: card

  defp evict(card) do
    victim = Enum.find(card.entries, &(&1.status != :running)) || hd(card.entries)

    %{
      card
      | entries: Enum.reject(card.entries, &(&1.key == victim.key)),
        details: Map.delete(card.details, victim.key),
        dropped: card.dropped + 1
    }
  end

  defp find(card, key), do: Enum.find(card.entries, &(&1.key == key))

  @doc """
  The card without a closing text entry. A turn's final text is posted as the
  agent's reply, or kept on the turn card as its recap, so on the finished
  card it would show twice. Step rows after it (the model call that wrote it)
  don't count as coming after it.
  """
  @spec drop_trailing_text(card) :: card
  def drop_trailing_text(%{entries: entries} = card) do
    {steps, rest} = entries |> Enum.reverse() |> Enum.split_while(&(&1.kind == :step))

    case rest do
      [%{kind: :text} | earlier] -> %{card | entries: Enum.reverse(earlier, Enum.reverse(steps))}
      _ -> card
    end
  end

  @doc """
  What the agent is doing right now, as a verb for the live card: "thinking"
  before any tool call or while only text streams, otherwise from the most
  recent tool: researching (reading, searching, fetching), building (editing),
  testing (a test command), running commands, planning, writing, coordinating.
  """
  @spec verb(card) :: String.t()
  def verb(%{entries: entries}) do
    case Enum.reverse(entries) |> Enum.find(&(&1.kind == :tool)) do
      nil -> "thinking"
      %{status: status} when status != :running -> "thinking"
      entry -> verb_for(Map.get(entry, :tool) || "", Map.get(entry, :command) || "")
    end
  end

  @doc "The newest call still running, for the live card's header; nil when none."
  @spec current(card) :: entry | nil
  def current(%{entries: entries}) do
    entries |> Enum.reverse() |> Enum.find(&(&1.kind == :tool and &1.status == :running))
  end

  @doc false
  def verb_for(tool, command) do
    tool = String.downcase(tool)

    cond do
      tool == "bash" and test_command?(command) ->
        "testing"

      tool == "bash" and install_command?(command) ->
        "installing"

      tool == "bash" ->
        "running commands"

      tool in ~w(read glob grep list ls) ->
        "researching"

      tool in ~w(webfetch websearch) ->
        "researching the web"

      String.contains?(
        tool,
        ~w(messages_read messages_search channel_get channels_list agents_list schedules_list locks_list handoff_get task_get)
      ) ->
        "catching up"

      tool in ~w(edit write patch apply_patch multiedit) ->
        "building"

      tool in ~w(todowrite todoread task) ->
        "planning"

      String.contains?(tool, ~w(message_send thread_reply)) ->
        "writing"

      String.contains?(
        tool,
        ~w(delegate handoff channel_create channel_add dm_start schedule_create lock_acquire lock_release)
      ) ->
        "coordinating"

      String.contains?(tool, "react") ->
        "acknowledging"

      String.contains?(tool, "pass") ->
        "wrapping up"

      true ->
        "working"
    end
  end

  defp test_command?(command),
    do:
      Regex.match?(
        ~r/\b(mix test|pytest|npm test|yarn test|pnpm test|go test|cargo test|rspec|jest|vitest|unittest|phpunit|bundle exec rspec)\b/,
        command
      )

  defp install_command?(command),
    do:
      Regex.match?(
        ~r/\b(mix deps\.get|npm (install|ci)|yarn( install)?|pnpm install|pip install|bundle install|cargo build|go mod)\b/,
        command
      )

  # -- Payloads --------------------------------------------------------------

  @payload_fields ~w(category step started_at duration_ms exit_code fact command description path adds dels denied changed)a

  @doc "The rows of a card as JSON-safe maps, for a timeline payload; details stay out."
  @spec to_payload(card) :: [map]
  def to_payload(%{entries: entries}) do
    Enum.map(entries, fn e ->
      base = %{
        "key" => e.key,
        "kind" => Atom.to_string(e.kind),
        "status" => Atom.to_string(e.status),
        "label" => e.label,
        "detail" => e.detail
      }

      Enum.reduce(@payload_fields, base, fn field, acc ->
        case Map.get(e, field) do
          nil ->
            acc

          false ->
            acc

          value when is_atom(value) and value != true ->
            Map.put(acc, Atom.to_string(field), Atom.to_string(value))

          value ->
            Map.put(acc, Atom.to_string(field), value)
        end
      end)
    end)
  end

  @doc """
  What the card knows beyond its rows, for `payload["activity_meta"]`: exact
  tallies, how many rows the cap dropped, each step's tokens, and the files
  the turn changed with their line counts.
  """
  @spec meta_payload(card) :: map
  def meta_payload(card) do
    %{
      "v" => 2,
      "tallies" => Map.new(card.tallies, fn {k, v} -> {Atom.to_string(k), v} end),
      "dropped" => card.dropped,
      "steps" => Enum.map(card.steps, & &1.tokens),
      "tokens" => card.tokens,
      "files" =>
        Enum.map(card.files, fn chip ->
          case chip_stats(chip) do
            {a, d} -> %{"path" => chip.path, "adds" => a, "dels" => d}
            nil -> %{"path" => chip.path}
          end
        end)
    }
  end

  @doc "The details of the rows still on the card, keyed by row key."
  @spec details_payload(card) :: map
  def details_payload(%{entries: entries, details: details}) do
    keys = MapSet.new(entries, & &1.key)
    Map.filter(details, fn {key, _} -> MapSet.member?(keys, key) end)
  end

  @doc "Entries back from a timeline payload; unknown kinds and statuses are normalised."
  @spec from_payload(term) :: [entry]
  def from_payload(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.map(fn {e, i} ->
      kind = atom_in(e["kind"], @kinds, :tool)
      label = to_string(e["label"] || "")

      %{
        key: to_string(e["key"] || i),
        kind: kind,
        status: atom_in(e["status"], @statuses, :ok),
        label: label,
        detail: e["detail"] && to_string(e["detail"]),
        tool: nil,
        category: stored_category(e["category"], kind, label),
        command: string(e["command"]),
        path: string(e["path"]),
        description: string(e["description"]),
        step: integer(e["step"]) || 0,
        started_at: integer(e["started_at"]),
        duration_ms: integer(e["duration_ms"]),
        exit_code: integer(e["exit_code"]),
        fact: string(e["fact"]),
        adds: integer(e["adds"]),
        dels: integer(e["dels"]),
        denied: e["denied"] == true,
        changed: e["changed"] == true
      }
    end)
  end

  def from_payload(_), do: []

  @doc """
  A finished turn's card from its `agent_turn_completed` payload. A payload
  from before details were kept (no `activity_meta`) has its tallies counted
  from its rows, and its changed files from the turn's file list.
  """
  @spec card_from_payload(map) :: card
  def card_from_payload(payload) when is_map(payload) do
    entries = from_payload(payload["activity"])
    meta = if is_map(payload["activity_meta"]), do: payload["activity_meta"], else: %{}
    stored = if is_map(meta["tallies"]), do: meta["tallies"], else: nil

    tallies =
      if stored do
        for {k, v} <- stored,
            is_integer(v),
            cat = atom_in(k, [:errors | @categories], nil),
            cat,
            into: %{},
            do: {cat, v}
      else
        Enum.reduce(entries, %{}, fn
          %{kind: :tool} = e, acc ->
            acc
            |> Map.update(e.category, 1, &(&1 + 1))
            |> then(
              &if(e.status == :error, do: Map.update(&1, :errors, 1, fn n -> n + 1 end), else: &1)
            )

          _e, acc ->
            acc
        end)
      end

    files =
      case meta["files"] do
        files when is_list(files) ->
          for %{"path" => path} = f <- files, is_binary(path) do
            diff = if is_integer(f["adds"]), do: {f["adds"], integer(f["dels"]) || 0}
            %{path: path, edits: %{}, diff: diff}
          end

        _ ->
          for path <- List.wrap(payload["files"]),
              is_binary(path),
              do: %{path: path, edits: %{}, diff: nil}
      end

    %{
      new()
      | entries: entries,
        tool_count: integer(payload["tools"]) || Enum.count(entries, &(&1.kind == :tool)),
        cost: if(is_number(payload["cost"]), do: payload["cost"], else: 0.0),
        tallies: tallies,
        dropped: integer(meta["dropped"]) || 0,
        tokens: integer(meta["tokens"]) || 0,
        steps:
          for(
            {tokens, i} <- Enum.with_index(List.wrap(meta["steps"])),
            do: %{key: "step-#{i}", tokens: integer(tokens) || 0, cost: 0.0}
          ),
        files: files,
        model: string(payload["model"]),
        version: if(meta["v"] == 2, do: 2, else: 1)
    }
  end

  # A first-version row has no category: its label's first word ("Read
  # lib/a.ex", "Edit a.py") is the tool, when it names one.
  defp stored_category(value, kind, label) do
    case atom_in(value, [:note | @categories], nil) do
      nil when kind == :text -> :note
      nil when kind in [:file, :diff] -> :edit
      nil -> label |> String.split(" ", parts: 2) |> hd() |> category()
      category -> category
    end
  end

  defp atom_in(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp atom_in(_, _, default), do: default

  # -- Helpers ---------------------------------------------------------------

  defp token_total(%{} = tokens),
    do: tokens |> Map.values() |> Enum.filter(&is_number/1) |> Enum.sum() |> round()

  defp token_total(_), do: 0

  @doc "A dollar amount with four decimals."
  def format_cost(cost) when is_number(cost),
    do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 4)

  def format_cost(_), do: "$0.0000"

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp first_line(nil), do: nil

  defp first_line(text),
    do: text |> String.split("\n", parts: 2) |> hd() |> truncate(@label_chars)

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp unique_key, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
