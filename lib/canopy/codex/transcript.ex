defmodule Canopy.Codex.Transcript do
  @moduledoc """
  A Codex session's history as transcript pages (§9 of the design).

  Codex keeps each thread as a rollout under `$CODEX_HOME/sessions`, and
  the app-server reads it back without loading the thread:
  `thread/turns/list` with `itemsView: "full"` gives every turn with its
  items. The thread is read newest first, up to the latest `@max_turns`
  turns, put back in order, and paged with `Canopy.Engine.TranscriptEntry.page/2`, so cursors are entry
  ids, as for Claude Code.

  `system_prompts` is empty: Codex does not return a thread's developer
  instructions through the API. Codex reports no usage per turn in its
  history, so there are no `:step` entries.
  """

  alias Canopy.Codex.{Client, Events}
  alias Canopy.Engine.TranscriptEntry, as: Entry

  @max_turns 500
  @page 100

  @doc "`{:ok, page}`, `{:error, :not_found}` or `{:error, :unreachable}`."
  def read(client_opts, %{engine_session_id: sid} = ref, opts) do
    result =
      Client.with_server(Keyword.put_new(client_opts, :cwd, Map.get(ref, :directory)), fn call ->
        fetch_turns(call, sid)
      end)

    case result do
      {:ok, turns} ->
        entries = entries(turns, Map.get(ref, :directory))
        page = Entry.page(entries, opts)

        {:ok,
         Map.merge(page, %{
           system_prompts: [],
           total: length(entries),
           compactions: Enum.count(entries, &(&1.kind == :compaction))
         })}

      {:error, reason} when is_binary(reason) ->
        if reason =~ ~r/no rollout found|thread not found|not found/i,
          do: {:error, :not_found},
          else: {:error, :unreachable}

      _ ->
        {:error, :unreachable}
    end
  end

  @doc """
  The thread's latest `@max_turns` turns, oldest first, through `call`
  (`Canopy.Codex.Client`'s request function). Fetched newest first, so a
  long thread loses its oldest turns, never its newest.
  """
  def fetch_turns(call, sid) do
    with {:ok, newest_first} <- turns(call, sid, nil, []) do
      {:ok, newest_first |> Enum.take(@max_turns) |> Enum.reverse()}
    end
  end

  defp turns(call, sid, cursor, acc) do
    params =
      %{"threadId" => sid, "itemsView" => "full", "sortDirection" => "desc", "limit" => @page}
      |> then(&if(cursor, do: Map.put(&1, "cursor", cursor), else: &1))

    case call.("thread/turns/list", params) do
      {:ok, %{"data" => data} = result} ->
        acc = acc ++ for(t <- List.wrap(data), is_map(t), do: t)

        case result["nextCursor"] do
          next when is_binary(next) and next != cursor and length(acc) < @max_turns ->
            turns(call, sid, next, acc)

          _ ->
            {:ok, acc}
        end

      {:ok, _} ->
        {:ok, acc}

      error ->
        error
    end
  end

  @doc "A thread's turns as transcript entries, oldest first."
  def entries(turns, directory \\ nil) do
    turns
    |> Enum.flat_map(fn turn ->
      at = turn_time(turn["startedAt"])
      turn_id = turn["id"]

      turn["items"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> entry(item, i, turn_id, at, directory) end)
    end)
  end

  defp entry(%{"type" => "userMessage"} = item, i, turn_id, at, _dir) do
    content = List.wrap(item["content"])
    text = for(%{"type" => "text", "text" => t} <- content, do: t) |> Enum.join("\n\n")

    attachments =
      for %{"type" => type} = c <- content, type in ["localImage", "image"] do
        %{kind: :image, name: c["path"] && Path.basename(c["path"]), mime: nil}
      end

    [
      %Entry{
        id: id(turn_id, item, i),
        kind: :prompt,
        at: at,
        message_id: turn_id,
        text: text,
        attachments: attachments,
        steered?: i > 0
      }
    ]
  end

  defp entry(%{"type" => "agentMessage", "text" => text} = item, i, turn_id, at, _dir)
       when is_binary(text) and text != "",
       do: [
         %Entry{id: id(turn_id, item, i), kind: :text, at: at, message_id: turn_id, text: text}
       ]

  defp entry(%{"type" => "reasoning"} = item, i, turn_id, at, _dir) do
    case Enum.join(List.wrap(item["summary"]), "\n\n") do
      "" ->
        [%Entry{id: id(turn_id, item, i), kind: :thinking_hidden, at: at, message_id: turn_id}]

      text ->
        [
          %Entry{
            id: id(turn_id, item, i),
            kind: :reasoning,
            at: at,
            message_id: turn_id,
            text: text
          }
        ]
    end
  end

  defp entry(%{"type" => "contextCompaction"} = item, i, turn_id, at, _dir) do
    [
      %Entry{
        id: id(turn_id, item, i),
        kind: :compaction,
        at: at,
        message_id: turn_id,
        compaction: %{trigger: :auto, pre_tokens: nil, post_tokens: nil, summary: nil}
      }
    ]
  end

  defp entry(%{"type" => "commandExecution"} = item, i, turn_id, at, _dir) do
    command = Events.command_text(item)
    {output, truncated?} = Entry.cap_output(item["aggregatedOutput"])

    tool(item, i, turn_id, at, %{
      name: "bash",
      title: command,
      input: command,
      output: output,
      truncated?: truncated?,
      status: status(item["status"], item["exitCode"]),
      duration_ms: item["durationMs"]
    })
  end

  defp entry(%{"type" => "fileChange"} = item, i, turn_id, at, dir) do
    changes = List.wrap(item["changes"])

    paths =
      for c <- changes,
          is_binary(c["path"]),
          do: Canopy.Codex.Allowance.display_path(c["path"], dir)

    {output, truncated?} = Entry.cap_output(Canopy.Codex.Approvals.diff(changes, dir))

    tool(item, i, turn_id, at, %{
      name: "apply_patch",
      title: Enum.join(paths, ", "),
      input: Enum.join(paths, "\n"),
      output: output,
      truncated?: truncated?,
      status: status(item["status"], nil),
      duration_ms: nil
    })
  end

  defp entry(%{"type" => "mcpToolCall"} = item, i, turn_id, at, _dir) do
    text =
      case item["result"] do
        %{"content" => content} when is_list(content) ->
          for(%{"type" => "text", "text" => t} <- content, do: t) |> Enum.join("\n")

        _ ->
          get_in(item, ["error", "message"])
      end

    {output, truncated?} = Entry.cap_output(text)

    tool(item, i, turn_id, at, %{
      name: "mcp__#{item["server"]}__#{item["tool"]}",
      title: "#{item["server"]} #{item["tool"]}",
      input: Entry.cap_input(item["arguments"]),
      output: output,
      truncated?: truncated?,
      status: status(item["status"], nil),
      duration_ms: item["durationMs"]
    })
  end

  defp entry(%{"type" => "webSearch"} = item, i, turn_id, at, _dir) do
    tool(item, i, turn_id, at, %{
      name: "websearch",
      title: item["query"],
      input: item["query"],
      output: nil,
      truncated?: false,
      status: :ok,
      duration_ms: nil
    })
  end

  defp entry(_item, _i, _turn_id, _at, _dir), do: []

  defp tool(item, i, turn_id, at, tool) do
    [
      %Entry{
        id: id(turn_id, item, i),
        kind: :tool,
        at: at,
        message_id: turn_id,
        tool: Map.put(tool, :call_id, item["id"])
      }
    ]
  end

  defp status("declined", _code), do: :denied
  defp status("completed", code) when code in [0, nil], do: :ok
  defp status("inProgress", _code), do: :running
  defp status(_status, _code), do: :error

  defp id(turn_id, item, i), do: "cx-#{turn_id}-#{item["id"] || i}"

  defp turn_time(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp turn_time(_), do: nil
end
