defmodule Canopy.ClaudeCode.Events do
  @moduledoc """
  Normalizes Claude Code stream-json lines (decoded JSON maps) into
  `Canopy.Engine.Event`s.

  Line shapes are represented by an anonymized synthetic fixture in
  `test/support/claude_code_fixtures/events-capture.jsonl`. The normalizer is
  stateful across one turn: it remembers each tool call's input
  until its result arrives, and folds the streaming usage of each model call
  into one `:step_completed`.
  """

  alias Canopy.Engine.Event

  @edit_tools ~w(Edit Write MultiEdit NotebookEdit)
  @file_tools ~w(Edit Write MultiEdit NotebookEdit Read)

  @type acc :: %{
          cwd: String.t() | nil,
          inputs: map(),
          step: map() | nil,
          steps: non_neg_integer()
        }

  @doc "A fresh accumulator; `cwd` shortens file paths in tool titles."
  def new(cwd \\ nil), do: %{cwd: cwd, inputs: %{}, step: nil, steps: 0}

  @spec normalize(map(), acc) :: {[Event.t()], acc}
  def normalize(line, acc)

  def normalize(%{"type" => "system", "subtype" => "init"} = line, acc) do
    session = %{
      "model" => line["model"],
      "mcp_servers" => line["mcp_servers"],
      "version" => line["claude_code_version"],
      "permission_mode" => line["permissionMode"]
    }

    {[
       event(:agent_status, %{status: :busy, raw: line}),
       event(:session_updated, %{session: session})
     ], acc}
  end

  def normalize(%{"type" => "system", "subtype" => "status"} = line, acc),
    do: {[event(:agent_status, %{status: :busy, raw: line})], acc}

  def normalize(%{"type" => "system", "subtype" => "api_retry"} = line, acc),
    do: {[event(:agent_status, %{status: :retry, raw: line})], acc}

  def normalize(%{"type" => "system", "subtype" => "compact_boundary"} = line, acc) do
    meta = line["compact_metadata"] || line["compactMetadata"] || %{}
    {[event(:message_updated, %{message: %{"compact" => meta}})], acc}
  end

  # Claude Code denied a tool itself (unattended run, nothing could approve it).
  def normalize(%{"type" => "system", "subtype" => "permission_denied"} = line, acc) do
    tool = line["tool_name"] || "tool"

    {[
       event(:tool_completed, %{
         call_id: "denied-" <> unique(),
         tool: tool,
         status: :error,
         input: line["tool_input"] || %{},
         title: tool,
         error: line["reason"] || "permission denied",
         output: nil,
         message_id: nil,
         part_id: nil
       })
     ], acc}
  end

  def normalize(%{"type" => "system"}, acc), do: {[], acc}

  def normalize(%{"type" => "rate_limit_event"} = line, acc) do
    case get_in(line, ["rate_limit_info", "status"]) do
      "allowed" -> {[], acc}
      nil -> {[], acc}
      _ -> {[event(:agent_status, %{status: :retry, raw: line})], acc}
    end
  end

  # One model call: message_start carries the input side of usage, message_delta the output.
  def normalize(%{"type" => "stream_event", "event" => %{"type" => "message_start"} = ev}, acc) do
    usage = get_in(ev, ["message", "usage"]) || %{}
    id = get_in(ev, ["message", "id"]) || "step-" <> unique()
    {[], %{acc | step: %{id: id, usage: usage}}}
  end

  def normalize(%{"type" => "stream_event", "event" => %{"type" => "message_delta"} = ev}, acc) do
    case acc.step do
      nil ->
        {[], acc}

      %{id: id, usage: started} ->
        usage = Map.merge(started, ev["usage"] || %{})

        {[step_event(id, usage, ev["delta"] && ev["delta"]["stop_reason"])],
         %{acc | step: nil, steps: acc.steps + 1}}
    end
  end

  def normalize(
        %{"type" => "stream_event", "event" => %{"type" => "content_block_delta"} = ev} = line,
        acc
      ) do
    case ev["delta"] do
      %{"type" => "text_delta", "text" => text} ->
        message_id = line["parent_tool_use_id"] || "main"

        {[
           event(:text_delta, %{
             message_id: message_id,
             part_id: to_string(ev["index"]),
             delta: text
           })
         ], acc}

      _ ->
        {[], acc}
    end
  end

  def normalize(%{"type" => "stream_event"}, acc), do: {[], acc}

  def normalize(%{"type" => "assistant", "message" => %{"content" => blocks} = message}, acc)
      when is_list(blocks) do
    message_id = message["id"] || "assistant-" <> unique()

    Enum.reduce(blocks, {[], acc}, fn block, {events, acc} ->
      case block do
        %{"type" => "text", "text" => text} ->
          {events ++
             [
               event(:text_done, %{
                 message_id: message_id,
                 part_id: message_id <> "-text",
                 text: text
               })
             ], acc}

        %{"type" => "tool_use", "id" => id, "name" => name} = block ->
          input = block["input"] || %{}

          started =
            event(:tool_started, %{
              call_id: id,
              tool: name,
              status: :running,
              input: input,
              title: title(name, input, acc.cwd),
              message_id: message_id,
              part_id: id
            })

          {events ++ [started],
           %{acc | inputs: Map.put(acc.inputs, id, %{tool: name, input: input})}}

        _ ->
          {events, acc}
      end
    end)
  end

  def normalize(%{"type" => "user", "message" => %{"content" => blocks}}, acc)
      when is_list(blocks) do
    Enum.reduce(blocks, {[], acc}, fn
      %{"type" => "tool_result", "tool_use_id" => id} = block, {events, acc} ->
        {call, inputs} = Map.pop(acc.inputs, id, %{tool: "tool", input: %{}})
        error? = block["is_error"] == true
        output = result_text(block["content"])

        completed =
          event(:tool_completed, %{
            call_id: id,
            tool: call.tool,
            status: if(error?, do: :error, else: :ok),
            input: call.input,
            title: title(call.tool, call.input, acc.cwd),
            output: output,
            error: if(error?, do: output),
            message_id: nil,
            part_id: id
          })

        changed =
          if not error? and call.tool in @edit_tools and is_binary(call.input["file_path"]),
            do: [event(:file_changed, %{path: call.input["file_path"]})],
            else: []

        {events ++ [completed | changed], %{acc | inputs: inputs}}

      _block, state ->
        state
    end)
  end

  def normalize(%{"type" => "user"}, acc), do: {[], acc}

  def normalize(%{"type" => "result"} = line, acc) do
    usage = tokens(line["usage"] || %{})
    cost = number(line["total_cost_usd"])

    # Without partial messages no step was folded; the result's usage is the turn's.
    steps =
      if acc.steps == 0 and usage_present?(line["usage"]),
        do: [step_event("result", line["usage"] || %{}, line["stop_reason"])],
        else: []

    usage_event =
      event(:turn_usage, %{message_id: nil, cost: cost, tokens: usage, finish: line["subtype"]})

    outcome =
      if line["is_error"] == true or line["subtype"] != "success" do
        text = present(line["result"]) || line["subtype"] || "error"

        event(:agent_error, %{
          error: %{"name" => line["subtype"] || "error", "data" => %{"message" => text}}
        })
      else
        event(:agent_completed, %{})
      end

    {steps ++ [usage_event, outcome], acc}
  end

  def normalize(_line, acc), do: {[], acc}

  @doc "Token buckets in Canopy's shape, from a stream-json `usage` map."
  def tokens(usage) when is_map(usage) do
    %{
      "input" => number(usage["input_tokens"]),
      "output" => number(usage["output_tokens"]),
      "reasoning" => 0,
      "cache" => %{
        "read" => number(usage["cache_read_input_tokens"]),
        "write" => number(usage["cache_creation_input_tokens"])
      }
    }
  end

  def tokens(_), do: tokens(%{})

  # The label an activity card shows for a tool call.
  @doc false
  def title("Bash", input, _cwd),
    do: present(input["description"]) || present(input["command"]) || "Bash"

  def title(tool, %{"file_path" => path}, cwd) when tool in @file_tools and is_binary(path),
    do: relative(path, cwd)

  def title(tool, %{"pattern" => pattern}, _cwd)
      when tool in ~w(Grep Glob) and is_binary(pattern), do: "#{tool} #{pattern}"

  def title("WebFetch", %{"url" => url}, _cwd) when is_binary(url), do: url
  def title("Agent", input, _cwd), do: present(input["description"]) || "Agent"
  def title("mcp__canopy__" <> name, _input, _cwd), do: "canopy " <> name
  def title(tool, _input, _cwd), do: tool

  defp step_event(id, usage, reason) do
    event(:step_completed, %{
      message_id: id,
      part_id: id,
      reason: reason || "completed",
      cost: 0.0,
      tokens: tokens(usage),
      snapshot: nil
    })
  end

  defp usage_present?(%{} = usage),
    do: number(usage["input_tokens"]) + number(usage["output_tokens"]) > 0

  defp usage_present?(_), do: false

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp result_text(nil), do: nil
  defp result_text(other), do: inspect(other)

  defp relative(path, cwd) when is_binary(cwd) and cwd != "" do
    case Path.relative_to(path, cwd) do
      ^path -> path
      rel -> rel
    end
  end

  defp relative(path, _cwd), do: path

  defp event(type, data),
    do: %Event{type: type, data: data, raw_type: "claude:" <> Atom.to_string(type)}

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0

  defp unique, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
