defmodule Canopy.Runtime.Activity do
  @moduledoc """
  Folds an agent's execution events into the activity card shown in a channel:
  one entry per tool call, edited file, step, or patch, plus a streaming text
  preview and running totals.

  The channel view folds live events with `fold/2`; the channel runtime folds
  the buffered events of a finished turn and stores them on the
  `agent_turn_completed` timeline event with `to_payload/1`, so the same card
  can be reopened later.
  """

  alias Canopy.Engine.Event

  @max_entries 80
  @preview_chars 1_500
  @kinds ~w(tool file step diff)a
  @statuses ~w(running ok error)a

  @type entry :: %{
          key: String.t(),
          kind: :tool | :file | :step | :diff,
          status: :running | :ok | :error,
          label: String.t(),
          detail: String.t() | nil
        }

  @type card :: %{entries: [entry], preview: String.t(), tool_count: non_neg_integer, cost: float}

  @spec new() :: card
  def new, do: %{entries: [], preview: "", tool_count: 0, cost: 0.0}

  @doc "Folds a list of events, oldest first, into a card."
  @spec fold_all([Event.t()]) :: card
  def fold_all(events), do: Enum.reduce(events, new(), &fold/2)

  @spec fold(Event.t(), card) :: card
  def fold(%Event{type: :tool_started, data: data}, card) do
    put_entry(card, %{
      key: data[:call_id] || data[:part_id] || unique_key(),
      kind: :tool,
      status: :running,
      label: present(data[:title]) || present(data[:tool]) || "tool",
      detail: short_input(data[:input]),
      tool: present(data[:tool]),
      command: command_of(data[:input])
    })
  end

  def fold(%Event{type: :tool_completed, data: data}, card) do
    entry = %{
      key: data[:call_id] || data[:part_id] || unique_key(),
      kind: :tool,
      status: if(data[:status] == :error, do: :error, else: :ok),
      label: present(data[:title]) || present(data[:tool]) || "tool",
      detail: present(data[:error]) || short_input(data[:input]),
      tool: present(data[:tool]),
      command: command_of(data[:input])
    }

    card = put_entry(card, entry)
    %{card | tool_count: card.tool_count + 1}
  end

  def fold(%Event{type: :file_changed, data: %{path: path}}, card) do
    put_entry(card, %{
      key: "file-" <> path,
      kind: :file,
      status: :ok,
      label: Path.basename(path),
      detail: path,
      tool: nil,
      command: nil
    })
  end

  # OpenCode sends the same step-finish part more than once; the part id keeps
  # it to one row.
  def fold(%Event{type: :step_completed, data: data}, card) do
    cost = if is_number(data[:cost]), do: data[:cost], else: 0.0
    key = "step-" <> (data[:part_id] || unique_key())
    seen? = Enum.any?(card.entries, &(&1.key == key))

    card =
      put_entry(card, %{
        key: key,
        kind: :step,
        status: :ok,
        label: "step #{data[:reason] || "completed"}",
        detail: step_detail(data[:tokens], cost),
        tool: nil,
        command: nil
      })

    if seen?, do: card, else: %{card | cost: card.cost + cost}
  end

  def fold(%Event{type: :text_delta, data: %{delta: delta}}, card) when is_binary(delta) do
    %{card | preview: tail(card.preview <> delta, @preview_chars)}
  end

  def fold(%Event{type: :text_done, data: %{text: text}}, card) when is_binary(text) do
    %{card | preview: tail(text, @preview_chars)}
  end

  def fold(%Event{type: :diff, data: %{files: files}}, card) when is_list(files) do
    put_entry(card, %{
      key: "diff-" <> unique_key(),
      kind: :diff,
      status: :ok,
      label: "#{length(files)} changed #{if(length(files) == 1, do: "file", else: "files")}",
      detail: Enum.map_join(files, ", ", &diff_file/1),
      tool: nil,
      command: nil
    })
  end

  def fold(%Event{type: :patch, data: data}, card) do
    files = List.wrap(data[:files])

    put_entry(card, %{
      key: "patch-" <> (data[:part_id] || data[:hash] || unique_key()),
      kind: :diff,
      status: :ok,
      label: "patch",
      detail: Enum.map_join(files, ", ", &diff_file/1),
      tool: nil,
      command: nil
    })
  end

  def fold(_event, card), do: card

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
      %{tool: tool, command: command} -> verb_for(tool || "", command || "")
    end
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
        ~w(messages_read messages_search channel_get channels_list agents_list schedules_list handoff_get task_get)
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
        ~w(delegate handoff channel_create channel_add dm_start schedule_create)
      ) ->
        "coordinating"

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

  defp command_of(%{"command" => c}) when is_binary(c), do: String.slice(c, 0, 200)
  defp command_of(%{command: c}) when is_binary(c), do: String.slice(c, 0, 200)
  defp command_of(_), do: nil

  @doc "The entries of a card as JSON-safe maps, for a timeline payload."
  @spec to_payload(card) :: [map]
  def to_payload(%{entries: entries}) do
    Enum.map(entries, fn e ->
      %{
        "key" => e.key,
        "kind" => Atom.to_string(e.kind),
        "status" => Atom.to_string(e.status),
        "label" => e.label,
        "detail" => e.detail
      }
    end)
  end

  @doc "Entries back from a timeline payload; unknown kinds and statuses are normalised."
  @spec from_payload(term) :: [entry]
  def from_payload(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.map(fn {e, i} ->
      %{
        key: to_string(e["key"] || i),
        kind: atom_in(e["kind"], @kinds, :tool),
        status: atom_in(e["status"], @statuses, :ok),
        label: to_string(e["label"] || ""),
        detail: e["detail"] && to_string(e["detail"]),
        tool: nil,
        command: nil
      }
    end)
  end

  def from_payload(_), do: []

  defp atom_in(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp atom_in(_, _, default), do: default

  defp put_entry(card, %{key: key} = entry) do
    entries =
      if Enum.any?(card.entries, &(&1.key == key)),
        do: Enum.map(card.entries, fn e -> if e.key == key, do: entry, else: e end),
        else: Enum.take(card.entries ++ [entry], -@max_entries)

    %{card | entries: entries}
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp short_input(input) when is_map(input) do
    value =
      Enum.find_value(~w(filePath path command pattern description query url), fn key ->
        case Map.get(input, key) do
          v when is_binary(v) and v != "" -> v
          _ -> nil
        end
      end) ||
        case Map.values(input) do
          [v | _] when is_binary(v) -> v
          _ -> nil
        end

    value && truncate(value, 80)
  end

  defp short_input(_), do: nil

  defp step_detail(tokens, cost) do
    total =
      case tokens do
        %{} -> tokens |> Map.values() |> Enum.filter(&is_number/1) |> Enum.sum()
        _ -> 0
      end

    [
      if(total > 0, do: "#{total} tokens"),
      if(cost > 0, do: format_cost(cost))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      detail -> detail
    end
  end

  @doc "A dollar amount with four decimals."
  def format_cost(cost) when is_number(cost),
    do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 4)

  def format_cost(_), do: "$0.0000"

  defp diff_file(%{} = file) do
    name = file["file"] || file["path"] || file[:file] || file[:path] || "?"
    adds = file["additions"] || file[:additions]
    dels = file["deletions"] || file[:deletions]

    if is_integer(adds) or is_integer(dels),
      do: "#{name} (+#{adds || 0}/-#{dels || 0})",
      else: to_string(name)
  end

  defp diff_file(other), do: to_string(other)

  defp tail(text, max) do
    if String.length(text) > max, do: "…" <> String.slice(text, -max, max), else: text
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp unique_key, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
