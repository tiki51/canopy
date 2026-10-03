defmodule Canopy.ClaudeCode.Events do
  @moduledoc """
  Normalizes Claude Code stream-json lines (decoded JSON maps) into
  `Canopy.Engine.Event`s.

  Line shapes are represented by an anonymized synthetic fixture in
  `test/support/claude_code_fixtures/events-capture.jsonl`. The normalizer is
  stateful across one turn: it remembers each tool call's input
  until its result arrives, and folds the streaming usage of each model call
  into one `:step_completed`.

  Tool results carry what the activity card shows per call: the line
  `timestamp`s of the tool_use and tool_result give its `time`, and the
  structured `tool_use_result` gives Bash's stdout, stderr and interrupted
  flag, an edit's patch and line counts, and a search's match count. A failed
  Bash call's exit code is read from an `Exit code N` prefix on its result;
  that format is not in a capture yet, so anything else leaves the code unset.

  ## Cost

  A `result`'s `total_cost_usd` is not the turn's cost: Claude Code keeps a
  running total per session, saves it in the transcript (a `cost-state` line,
  seen in 2.1.283) and restores it when the session is resumed, so every
  result reports what the whole session has cost so far. Within one process
  several results (steered turns) are cumulative too. The accumulator
  therefore carries `cost_bases`, the totals this process may have started
  from (see `Canopy.ClaudeCode.Cost`), and a result's cost is its total minus
  the largest base not above it (zero is always a base, for a process that
  started over). After a result its own total is the base for the next one.
  """

  alias Canopy.Engine.Event

  @edit_tools ~w(Edit Write MultiEdit NotebookEdit)
  @file_tools ~w(Edit Write MultiEdit NotebookEdit Read)

  @type acc :: %{
          cwd: String.t() | nil,
          inputs: map(),
          step: map() | nil,
          steps: non_neg_integer(),
          cost_bases: [number()]
        }

  @doc """
  A fresh accumulator; `cwd` shortens file paths in tool titles. Options:
  `:cost_bases`, the session totals the process may resume from (default
  none: the process starts at zero).
  """
  def new(cwd \\ nil, opts \\ []) do
    bases = for b <- Keyword.get(opts, :cost_bases, []), is_number(b), do: b
    %{cwd: cwd, inputs: %{}, step: nil, steps: 0, cost_bases: bases}
  end

  @doc """
  The turn's own cost from a result's cumulative `total`: the total minus the
  largest of `bases` (and zero) that is not above it.
  """
  @spec turn_cost(number(), [number()]) :: float()
  def turn_cost(total, bases) when is_number(total) do
    base =
      [0 | bases]
      |> Enum.filter(&(is_number(&1) and &1 <= total + 1.0e-9))
      |> Enum.max()

    max(total - base, 0) / 1
  end

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
     ] ++ mcp_servers(line), acc}
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
         denied: true,
         time: line_time(line, "end"),
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

  def normalize(
        %{"type" => "assistant", "message" => %{"content" => blocks} = message} = line,
        acc
      )
      when is_list(blocks) do
    message_id = message["id"] || "assistant-" <> unique()
    started_at = timestamp_ms(line["timestamp"])

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
              time: line_time(line, "start"),
              message_id: message_id,
              part_id: id
            })

          call = %{tool: name, input: input, started_at: started_at}
          {events ++ [started], %{acc | inputs: Map.put(acc.inputs, id, call)}}

        _ ->
          {events, acc}
      end
    end)
  end

  def normalize(%{"type" => "user", "message" => %{"content" => blocks}} = line, acc)
      when is_list(blocks) do
    # The structured result rides on the line, not the block: it can only be
    # told apart when the line carries one result.
    structured =
      if Enum.count(blocks, &match?(%{"type" => "tool_result"}, &1)) == 1,
        do: line["tool_use_result"]

    ended_at = timestamp_ms(line["timestamp"])

    Enum.reduce(blocks, {[], acc}, fn
      %{"type" => "tool_result", "tool_use_id" => id} = block, {events, acc} ->
        {call, inputs} = Map.pop(acc.inputs, id, %{tool: "tool", input: %{}})
        error? = block["is_error"] == true
        output = result_text(block["content"])

        time =
          %{"start" => Map.get(call, :started_at), "end" => ended_at}
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        completed =
          event(
            :tool_completed,
            Map.merge(
              %{
                call_id: id,
                tool: call.tool,
                status: if(error?, do: :error, else: :ok),
                input: call.input,
                title: title(call.tool, call.input, acc.cwd),
                output: output,
                error: if(error?, do: output),
                time: time,
                message_id: nil,
                part_id: id
              },
              result_facts(call, structured, error?, output, acc.cwd)
            )
          )

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
    total = number(line["total_cost_usd"])
    cost = turn_cost(total, acc.cost_bases)

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

    # a later result of this process counts from this one
    {steps ++ [usage_event, outcome], %{acc | cost_bases: [total]}}
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
    do: "#{tool} #{relative(path, cwd)}"

  def title(tool, %{"pattern" => pattern}, _cwd)
      when tool in ~w(Grep Glob) and is_binary(pattern), do: "#{tool} #{pattern}"

  def title("WebFetch", %{"url" => url}, _cwd) when is_binary(url), do: url
  def title("Agent", input, _cwd), do: present(input["description"]) || "Agent"
  def title("mcp__canopy__" <> name, _input, _cwd), do: "canopy " <> name
  def title(tool, _input, _cwd), do: tool

  # What the structured result says about the call, as optional event fields.
  defp result_facts(call, structured, error?, output, cwd) do
    structured = if is_map(structured), do: structured, else: %{}

    %{
      stdout: string_or_nil(structured["stdout"]),
      stderr: string_or_nil(structured["stderr"]),
      interrupted: if(structured["interrupted"] == true, do: true),
      matches: integer_or_nil(structured["totalMatches"] || structured["numFiles"]),
      exit_code: if(call.tool == "Bash" and error?, do: exit_code(output))
    }
    |> Map.merge(patch_facts(structured["structuredPatch"], structured["filePath"], cwd))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Unverified: a failed Bash result is believed to start with `Exit code N`.
  # Nothing else in the text is read, so an unknown format gives no code.
  defp exit_code(output) when is_binary(output) do
    case Regex.run(~r/\AExit code (\d+)/, output) do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  defp exit_code(_output), do: nil

  # An edit's `structuredPatch` hunks as unified diff text, with its counts.
  defp patch_facts(hunks, path, cwd) when is_list(hunks) and hunks != [] do
    name = if is_binary(path), do: relative(path, cwd), else: "file"

    lines =
      Enum.flat_map(hunks, fn hunk ->
        header =
          "@@ -#{hunk["oldStart"]},#{hunk["oldLines"]} +#{hunk["newStart"]},#{hunk["newLines"]} @@"

        [header | for(l <- List.wrap(hunk["lines"]), is_binary(l), do: l)]
      end)

    body = Enum.reject(lines, &String.starts_with?(&1, "@@"))

    %{
      patch: Enum.join(["--- " <> name, "+++ " <> name | lines], "\n"),
      adds: Enum.count(body, &String.starts_with?(&1, "+")),
      dels: Enum.count(body, &String.starts_with?(&1, "-"))
    }
  end

  defp patch_facts(_hunks, _path, _cwd), do: %{}

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_), do: nil

  # The line's `timestamp` as `%{key => ms}` for an event's `time`, or empty.
  defp line_time(line, key) do
    case timestamp_ms(line["timestamp"]) do
      nil -> %{}
      ms -> %{key => ms}
    end
  end

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_ms(_value), do: nil

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

  # The servers this turn loaded, with how many of `init.tools` each one gave
  # (`mcp__<server>__<tool>`).
  defp mcp_servers(%{"mcp_servers" => servers} = line) when is_list(servers) do
    tools = for t <- List.wrap(line["tools"]), is_binary(t), do: t

    list =
      for %{"name" => name} = server <- servers, is_binary(name) do
        prefix = "mcp__" <> name <> "__"

        %{
          name: name,
          status: server["status"],
          tool_count: Enum.count(tools, &String.starts_with?(&1, prefix))
        }
      end

    [event(:mcp_servers, %{servers: list})]
  end

  defp mcp_servers(_line), do: []

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
