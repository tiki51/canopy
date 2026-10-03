defmodule Canopy.MCP.Tools.Permission do
  @moduledoc """
  Internal: Claude Code's permission prompt. Canopy answers it from the channel
  (Once / Always / Reject on the permission card, or the answers on a question
  card). Agents never call this themselves.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.ClaudeCode.Prompts
  alias Canopy.Engine.Event
  alias Canopy.MCP.{Identity, Tool}

  @diff_max 4_000

  schema do
    field :tool_name, :string, description: "The tool Claude Code wants to run."
    field :input, :map, description: "The tool's input."
    field :tool_use_id, :string, description: "Claude Code's id for the call."
  end

  @impl true
  def execute(params, frame) do
    case Identity.from_frame(frame) do
      {:ok, ctx} ->
        reply = prompt(ctx, params)
        Tool.reply(JSON.encode!(reply), frame)

      {:error, _} ->
        Tool.error("the permission tool is for Claude Code sessions only", frame)
    end
  end

  # -- Questions ------------------------------------------------------------------

  # An AskUserQuestion blocks the turn for the question wait (Settings, 10
  # minutes by default), not the full prompt timeout: a user who is away must
  # not pin the agent. When the wait runs out the agent is told to end its
  # turn; the card stays open, detached, and the answer reaches the agent later
  # as a new message.
  defp prompt(ctx, %{tool_name: "AskUserQuestion"} = params) do
    input = params[:input] || %{}
    id = params[:tool_use_id] || "q-" <> unique()

    case input |> Map.get("questions") |> List.wrap() |> Enum.map(&question_info/1) do
      # nothing to show and nothing to answer: a card would wait forever
      [] ->
        deny("AskUserQuestion needs at least one question")

      questions ->
        ask(ctx, id, input, questions)
    end
  end

  # -- Tool permissions ----------------------------------------------------------

  defp prompt(ctx, params) do
    tool = params[:tool_name] || "tool"
    input = params[:input] || %{}
    id = params[:tool_use_id] || "perm-" <> unique()
    sid = ctx.session.engine_session_id

    if tool in Prompts.always_list(sid) do
      %{behavior: "allow", updatedInput: input}
    else
      request = %{
        "id" => id,
        "permission" => tool,
        "patterns" => patterns(tool, input, ctx.repository.path),
        "metadata" => %{"input" => input, "diff" => diff(tool, input)},
        "tool" => %{"callID" => id}
      }

      :ok = Prompts.open(id, :permission, sid, request)
      broadcast(ctx, :approval_required, %{request: request})

      case Prompts.await(id) do
        {:ok, :once} ->
          %{behavior: "allow", updatedInput: input}

        {:ok, :always} ->
          :ok = Prompts.allow_always(sid, tool)
          %{behavior: "allow", updatedInput: input}

        {:ok, :reject} ->
          deny("the user rejected #{tool}")

        {:error, :timeout} ->
          broadcast(ctx, :approval_expired, %{request_id: id})

          deny(
            "Nobody approved #{tool} in time. The request stays open in the channel; " <>
              "if the user approves it later, you will be told in a new message."
          )

        _ ->
          deny("nobody approved #{tool} in time")
      end
    end
  end

  defp ask(ctx, id, input, questions) do
    request = %{
      "id" => id,
      "questions" => questions,
      "tool" => %{"callID" => id}
    }

    :ok = Prompts.open(id, :question, ctx.session.engine_session_id, request)
    broadcast(ctx, :question_required, %{request: request})

    case Prompts.await(id, Prompts.question_timeout_ms()) do
      {:ok, {:answered, answers}} ->
        answers_map =
          questions
          |> Enum.zip(List.wrap(answers))
          |> Map.new(fn {q, labels} -> {q["question"], Enum.join(List.wrap(labels), ", ")} end)

        %{behavior: "allow", updatedInput: Map.put(input, "answers", answers_map)}

      {:ok, :rejected} ->
        deny("the user declined to answer")

      {:error, :timeout} ->
        broadcast(ctx, :question_expired, %{request_id: id})

        deny(
          "The user hasn't answered yet. The question stays open in the channel. " <>
            "End your turn now; their answer will reach you as a new message."
        )

      _ ->
        deny("nobody answered the question in time")
    end
  end

  defp deny(message), do: %{behavior: "deny", message: message}

  defp broadcast(ctx, type, data) do
    Canopy.Engine.broadcast_event(ctx.repository.id, %Event{
      type: type,
      session_id: ctx.session.engine_session_id,
      data: data,
      raw_type: "claude:permission"
    })
  end

  # What the card names: the command, or the file, relative to the repository.
  defp patterns("Bash", %{"command" => command}, _cwd) when is_binary(command), do: [command]

  defp patterns(_tool, %{"file_path" => path}, cwd) when is_binary(path),
    do: [Path.relative_to(path, cwd)]

  defp patterns(_tool, _input, _cwd), do: []

  defp diff("Edit", %{"old_string" => old, "new_string" => new})
       when is_binary(old) and is_binary(new) do
    (lines(old, "-") ++ lines(new, "+")) |> Enum.join("\n") |> String.slice(0, @diff_max)
  end

  defp diff("Write", %{"content" => content}) when is_binary(content),
    do: content |> lines("+") |> Enum.join("\n") |> String.slice(0, @diff_max)

  defp diff(_tool, _input), do: nil

  defp lines(text, prefix), do: text |> String.split("\n") |> Enum.map(&(prefix <> &1))

  # Claude Code's question shape into the card's (`multiple` instead of
  # `multiSelect`). AskUserQuestion always takes an answer in the user's own
  # words ("Other"), so every question allows one (`custom`).
  defp question_info(%{} = q) do
    %{
      "question" => q["question"] || "",
      "header" => q["header"],
      "options" =>
        Enum.map(List.wrap(q["options"]), fn o ->
          %{"label" => o["label"] || "", "description" => o["description"]}
        end),
      "multiple" => q["multiSelect"] == true,
      "custom" => true
    }
  end

  defp question_info(other),
    do: %{"question" => to_string(other), "options" => [], "multiple" => false, "custom" => true}

  defp unique, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
