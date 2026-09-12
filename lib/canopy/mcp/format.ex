defmodule Canopy.MCP.Format do
  @moduledoc """
  Compact plain-text rendering for tool results. Models read these, so every
  line is short, prefixed with the id an agent can quote back, and free of
  JSON noise.
  """

  alias Canopy.Messages.Message

  @doc "`@name` for an agent, the display name for the user, `unknown` otherwise."
  def sender(%Message{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  def sender(%Message{user: %{display_name: name}}) when is_binary(name), do: name
  def sender(%Message{agent_id: id}) when is_binary(id), do: id
  def sender(_), do: "unknown"

  def agent_ref(nil), do: "nobody"
  def agent_ref(%Ecto.Association.NotLoaded{}), do: "unknown"
  def agent_ref(%{name: name}) when is_binary(name), do: "@" <> name
  def agent_ref(id) when is_binary(id), do: id

  @doc """
  `[msg_01…] @backend (2m ago): body`, with a thread marker for replies and
  the attached documents, if any, after the body.
  """
  def message_line(%Message{} = message, opts \\ []) do
    body =
      if Keyword.get(opts, :bodies, true) do
        ": " <>
          shortened(body_or_placeholder(message), Keyword.get(opts, :truncate, nil)) <>
          attachments_suffix(message)
      else
        ""
      end

    thread =
      case message.thread_id do
        nil -> ""
        thread_id -> " (in thread #{thread_id})"
      end

    "[#{message.id}] #{sender(message)} (#{relative_time(message.inserted_at)})#{thread}#{body}"
  end

  defp body_or_placeholder(%Message{body: body}) do
    case single_line(body) do
      "" -> "(no text)"
      text -> text
    end
  end

  @max_listed_attachments 5

  @doc "` [attachments: doc_… shot.png (image, 240 KB); …]` or an empty string."
  def attachments_suffix(%Message{documents: docs}) when is_list(docs) and docs != [] do
    {shown, rest} = Enum.split(docs, @max_listed_attachments)
    more = if rest == [], do: "", else: "; +#{length(rest)} more"
    " [attachments: " <> Enum.map_join(shown, "; ", &document_ref/1) <> more <> "]"
  end

  def attachments_suffix(_), do: ""

  @doc "`doc_… report.md (text, 12 KB)`."
  def document_ref(document) do
    "#{document.id} #{document.filename} (#{document.kind}, #{Canopy.Documents.size_label(document.byte_size)})"
  end

  @doc "Renders messages one per line, or a placeholder when there are none."
  def message_lines([], _opts), do: "(no messages)"

  def message_lines(messages, opts) do
    Enum.map_join(messages, "\n", &message_line(&1, opts))
  end

  # Long bodies are cut with a pointer to the full text; every character a
  # tool returns stays in the agent's context for the rest of its session.
  defp shortened(text, max) when is_integer(max) and byte_size(text) > max do
    kept = String.slice(text, 0, max)

    "#{kept}… (+#{String.length(text) - String.length(kept)} chars; canopy_message_get for the full text)"
  end

  defp shortened(text, _max), do: text

  @doc "`2m ago`, `3h ago`, `5d ago`, or `just now`."
  def relative_time(nil), do: "unknown time"

  def relative_time(%DateTime{} = at) do
    relative_time(at, DateTime.utc_now())
  end

  def relative_time(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 45 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @doc "Collapses whitespace and newlines so a message fits on one line."
  def single_line(nil), do: ""

  def single_line(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")
  end

  @doc "Truncates long text with an ellipsis."
  def truncate(text, max \\ 200)
  def truncate(nil, _max), do: ""

  def truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  @doc "A short task block: status, title, owner, description, result."
  def task_block(nil), do: "Task: none"

  def task_block(task) do
    owner =
      if Ecto.assoc_loaded?(task.owner),
        do: agent_ref(task.owner),
        else: agent_ref(task.owner_agent_id)

    [
      "Task: [#{task.id}] #{task.status} — #{task.title} (owner #{owner})",
      optional_line("  Description: ", task.description),
      optional_line("  Result: ", task.result)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "`prefix <text>` or nil when the text is blank."
  def optional_line(_prefix, nil), do: nil
  def optional_line(_prefix, ""), do: nil
  def optional_line(prefix, text) when is_binary(text), do: prefix <> single_line(text)

  @doc "Renders a handoff in full, including the packet."
  def handoff_block(handoff) do
    packet = handoff.packet || %{}

    [
      "Handoff [#{handoff.id}] #{handoff.status}: #{agent_ref(handoff.from_agent)} → #{agent_ref(handoff.to_agent)}",
      "Summary: #{handoff.summary}",
      optional_line("Reason: ", handoff.reason),
      optional_line("Suggested next step: ", handoff.suggested_next_step),
      optional_line("Rejection reason: ", handoff.rejection_reason),
      optional_line("Branch: ", packet["branch"]),
      list_line("Changed files: ", packet["changed_files"]),
      list_line("Git status: ", packet["status"]),
      optional_line("Diff stat: ", packet["diff_stat"]),
      list_line("Recent message ids: ", packet["recent_message_ids"]),
      packet_task_line(packet["task"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp list_line(_prefix, nil), do: nil
  defp list_line(_prefix, []), do: nil
  defp list_line(prefix, items) when is_list(items), do: prefix <> Enum.join(items, ", ")
  defp list_line(prefix, other), do: optional_line(prefix, to_string(other))

  defp packet_task_line(%{} = task) when map_size(task) > 0 do
    "Task at handoff: #{task["status"]} — #{task["title"]}"
  end

  defp packet_task_line(_), do: nil
end
