defmodule Canopy.OpenCode.Transcript do
  @moduledoc """
  Reads an OpenCode session's history for `Canopy.Engine.OpenCode.transcript/3`,
  from `GET /session/{id}/message` (`[{info, parts}]`), as
  `Canopy.Engine.TranscriptEntry`s.

  How that endpoint pages (`limit`, `before`, and in which order) is not
  verified (Phase 0 was not run live), so the whole history is fetched and
  paged here, with part ids as cursors. Canopy's largest session so far is
  about 1,250 messages.

  | Source | Entry |
  |---|---|
  | user message `text` parts | `:prompt` (`file` parts become attachments, never their bytes) |
  | `info.system` | `system_prompts`, a new one when it changes |
  | `reasoning` | `:reasoning` (empty ones dropped) |
  | `text` | `:text` (`synthetic` flagged) |
  | `tool` | `:tool`, from its `state` |
  | `step-finish` | `:step`, with the files of the `patch` parts before it |
  | `compaction` part + the summary assistant | `:compaction` |
  | assistant `info.error` | `:engine_note` |
  | `step-start` | dropped |
  """

  alias Canopy.Engine.TranscriptEntry
  alias Canopy.OpenCode.Client

  @doc "Reads a page; see `c:Canopy.Engine.transcript/3`."
  def read(%{engine_session_id: sid} = ref, opts, client_opts) do
    case Client.impl().messages(Map.get(ref, :directory), sid, [], client_opts) do
      {:ok, messages} when is_list(messages) ->
        {entries, system_prompts} = normalize(messages)

        page =
          entries
          |> TranscriptEntry.page(opts)
          |> Map.merge(%{
            system_prompts: system_prompts,
            total: length(entries),
            compactions: Enum.count(entries, &(&1.kind == :compaction))
          })

        {:ok, page}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, {:http, 404, _}} ->
        {:error, :not_found}

      {:error, {:transport, _}} ->
        {:error, :unreachable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The whole history as entries, and the system text per change: `{entries, system_prompts}`."
  def normalize(messages) do
    {entries, systems, _} =
      Enum.reduce(messages, {[], [], nil}, fn message, {entries, systems, compacting} ->
        info = message["info"] || %{}
        parts = if is_list(message["parts"]), do: message["parts"], else: []

        case info["role"] do
          "user" ->
            {rows, compacting} = user_entries(info, parts)
            {Enum.reverse(rows, entries), system(systems, info), compacting}

          "assistant" ->
            if compacting && summary?(info) do
              {fill_summary(entries, compacting, parts), systems, nil}
            else
              {Enum.reverse(assistant_entries(info, parts), entries), systems, compacting}
            end

          _ ->
            {entries, systems, compacting}
        end
      end)

    {Enum.reverse(entries), Enum.reverse(systems)}
  end

  defp summary?(info), do: info["summary"] == true or info["mode"] == "compaction"

  # A new system text when it differs from the last one.
  defp system(systems, %{"system" => text} = info) when is_binary(text) and text != "" do
    case systems do
      [%{canopy: ^text} | _] -> systems
      _ -> [%{at: time(info), canopy: text, engine: nil} | systems]
    end
  end

  defp system(systems, _info), do: systems

  # {entries, the id of a compaction waiting for its summary}
  defp user_entries(info, parts) do
    id = info["id"]
    at = time(info)
    {synthetic, typed} = parts |> by_type("text") |> Enum.split_with(&(&1["synthetic"] == true))

    attachments =
      for part <- by_type(parts, "file") do
        %{kind: file_kind(part["mime"]), name: part["filename"], mime: part["mime"]}
      end

    prompt =
      if typed != [] or attachments != [] do
        text = typed |> Enum.map_join("\n\n", &(&1["text"] || "")) |> String.trim()

        [
          %TranscriptEntry{
            id: id || first_id(typed),
            kind: :prompt,
            at: at,
            message_id: id,
            text: if(text == "", do: nil, else: text),
            attachments: attachments
          }
        ]
      else
        []
      end

    notes =
      for part <- synthetic, present?(part["text"]) do
        %TranscriptEntry{
          id: part["id"],
          kind: :engine_note,
          at: part_time(part, info),
          message_id: id,
          text: part["text"],
          synthetic?: true
        }
      end

    compactions =
      for part <- by_type(parts, "compaction") do
        %TranscriptEntry{
          id: part["id"],
          kind: :compaction,
          at: at,
          message_id: id,
          compaction: %{
            trigger: if(part["auto"] == false, do: :manual, else: :auto),
            pre_tokens: nil,
            post_tokens: nil,
            summary: nil
          }
        }
      end

    compacting = if compaction = List.last(compactions), do: compaction.id

    {prompt ++ notes ++ compactions, compacting}
  end

  defp fill_summary(entries, compaction_id, parts) do
    summary = parts |> by_type("text") |> Enum.map_join("\n\n", &(&1["text"] || ""))

    Enum.map(entries, fn
      %TranscriptEntry{id: ^compaction_id, compaction: compaction} = entry ->
        %{entry | compaction: %{compaction | summary: if(present?(summary), do: summary)}}

      entry ->
        entry
    end)
  end

  defp assistant_entries(info, parts) do
    id = info["id"]

    {rows, _patched} =
      Enum.reduce(parts, {[], []}, fn part, {rows, patched} ->
        case part_entry(part, info, patched) do
          {:patch, files} -> {rows, patched ++ files}
          {:step, entry} -> {[entry | rows], []}
          nil -> {rows, patched}
          entry -> {[entry | rows], patched}
        end
      end)

    error =
      case info["error"] do
        %{} = error ->
          message = get_in(error, ["data", "message"]) || error["name"] || "error"

          [
            %TranscriptEntry{
              id: "#{id}-error",
              kind: :engine_note,
              at: time(info),
              message_id: id,
              text: "Error: " <> to_string(message)
            }
          ]

        _ ->
          []
      end

    Enum.reverse(rows) ++ error
  end

  defp part_entry(%{"type" => "reasoning"} = part, info, _patched) do
    if present?(part["text"]),
      do: entry(part, info, :reasoning, text: part["text"])
  end

  defp part_entry(%{"type" => "text"} = part, info, _patched) do
    if present?(part["text"]),
      do: entry(part, info, :text, text: part["text"], synthetic?: part["synthetic"] == true)
  end

  defp part_entry(%{"type" => "tool"} = part, info, _patched) do
    state = part["state"] || %{}
    time = state["time"] || %{}

    status =
      case state["status"] do
        # a command that ran and failed still completes; its exit code says so
        "completed" ->
          case get_in(state, ["metadata", "exit"]) do
            code when is_integer(code) and code != 0 -> :error
            _ -> :ok
          end

        "error" ->
          if String.contains?(to_string(state["error"]), "rejected permission"),
            do: :denied,
            else: :error

        _ ->
          :running
      end

    {output, truncated?} =
      TranscriptEntry.cap_output(state["output"] || state["error"])

    duration =
      case time do
        %{"start" => s, "end" => e} when is_number(s) and is_number(e) -> trunc(max(e - s, 0))
        _ -> nil
      end

    tool = %{
      name: part["tool"] || "tool",
      call_id: part["callID"],
      title: state["title"] || part["tool"],
      input: TranscriptEntry.cap_input(state["input"]),
      output: output,
      status: status,
      duration_ms: duration,
      truncated?: truncated?
    }

    entry(part, info, :tool, tool: tool)
  end

  defp part_entry(%{"type" => "patch"} = part, _info, _patched),
    do: {:patch, List.wrap(part["files"])}

  defp part_entry(%{"type" => "step-finish"} = part, info, patched) do
    step = %{
      tokens: part["tokens"] || %{},
      cost: part["cost"],
      model: info["modelID"],
      files: patched
    }

    {:step, entry(part, info, :step, step: step)}
  end

  defp part_entry(_part, _info, _patched), do: nil

  defp entry(part, info, kind, fields) do
    struct(
      TranscriptEntry,
      [id: part["id"], kind: kind, at: part_time(part, info), message_id: info["id"]] ++ fields
    )
  end

  defp by_type(parts, type), do: Enum.filter(parts, &(&1["type"] == type))

  defp first_id([part | _]), do: part["id"]
  defp first_id([]), do: nil

  defp file_kind("image/" <> _), do: :image
  defp file_kind(_), do: :file

  defp part_time(part, info) do
    TranscriptEntry.time(
      get_in(part, ["time", "start"]) || get_in(part, ["state", "time", "start"])
    ) ||
      time(info)
  end

  defp time(info), do: TranscriptEntry.time(get_in(info, ["time", "created"]))

  defp present?(text), do: is_binary(text) and String.trim(text) != ""
end
