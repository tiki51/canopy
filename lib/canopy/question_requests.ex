defmodule Canopy.QuestionRequests do
  @moduledoc """
  Questions agents ask through OpenCode's `question` tool, surfaced in the
  channel feed.

  A pending question blocks the agent's turn: OpenCode holds the tool call open
  until someone replies or rejects it. Nothing else in the channel can answer
  one, so an unanswered question would wedge the agent were it not for the
  runtime's turn watchdog.
  """

  import Ecto.Query, warn: false

  alias Canopy.QuestionRequests.QuestionRequest
  alias Canopy.Repo
  alias Canopy.Timeline
  alias Ecto.Multi

  @preloads [agent_session: [:agent]]

  def get!(id), do: QuestionRequest |> Repo.get!(id) |> Repo.preload(@preloads)

  def get_by_opencode_id(opencode_question_id) when is_binary(opencode_question_id) do
    QuestionRequest
    |> Repo.get_by(opencode_question_id: opencode_question_id)
    |> Repo.preload(@preloads)
  end

  @doc """
  Stores a `question.asked` payload and records `question_requested`. Recording
  the same OpenCode question id twice returns the existing row, so
  reconciliation after a reconnect is safe.
  """
  def record(attrs) do
    attrs = Map.new(attrs)

    case attrs[:opencode_question_id] && get_by_opencode_id(attrs[:opencode_question_id]) do
      %QuestionRequest{} = existing ->
        {:ok, existing}

      _ ->
        Multi.new()
        |> Multi.insert(:request, QuestionRequest.changeset(%QuestionRequest{}, attrs))
        |> Timeline.multi_record(:event, fn %{request: r} ->
          %{
            channel_id: r.channel_id,
            agent_id: agent_id_of(r),
            event_type: "question_requested",
            ref_id: r.id,
            payload: %{
              "headers" => headers(r),
              "opencode_question_id" => r.opencode_question_id
            }
          }
        end)
        |> commit()
    end
  end

  @doc """
  Resolves a pending question. `{:answered, answers}` carries one list of chosen
  labels per question, in question order; `:rejected` means the user declined to
  answer.
  """
  def resolve(%QuestionRequest{} = request, outcome) do
    attrs =
      case outcome do
        {:answered, answers} ->
          %{status: "answered", answers: answers, resolved_at: DateTime.utc_now()}

        :rejected ->
          %{status: "rejected", resolved_at: DateTime.utc_now()}
      end

    Multi.new()
    |> Multi.update(:request, QuestionRequest.changeset(request, attrs))
    |> Timeline.multi_record(:event, fn %{request: r} ->
      %{
        channel_id: r.channel_id,
        agent_id: agent_id_of(r),
        event_type: "question_resolved",
        ref_id: r.id,
        payload: %{
          "headers" => headers(r),
          "status" => r.status,
          "answers" => r.answers
        }
      }
    end)
    |> commit()
  end

  def pending_for_channel(channel_id) do
    Repo.all(
      from q in QuestionRequest,
        where: q.channel_id == ^channel_id and q.status == "pending",
        order_by: [asc: q.id],
        preload: ^@preloads
    )
  end

  @doc "The short labels OpenCode attaches to each question, for the feed line."
  def headers(%QuestionRequest{questions: questions}),
    do: Enum.map(questions, &(&1["header"] || &1["question"]))

  defp agent_id_of(request) do
    case Repo.preload(request, :agent_session).agent_session do
      %{agent_id: agent_id} -> agent_id
      _ -> nil
    end
  end

  defp commit(multi) do
    case Repo.transaction(multi) do
      {:ok, %{request: request, event: event}} ->
        Timeline.broadcast(event)
        {:ok, Repo.preload(request, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end
end
