defmodule Canopy.QuestionRequests do
  @moduledoc """
  Questions agents ask through their engine's question tool (OpenCode's
  `question`, Claude Code's `AskUserQuestion`), surfaced in the channel feed.

  A pending question blocks the agent's turn while the engine holds the tool
  call open. When the agent stops waiting (its turn ended, or the wait ran
  out) the card is *detached*: it stays pending and answerable, and the
  runtime delivers a late answer to the agent as a new message.
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
  Stores a question payload and records `question_requested`. Recording the
  same engine question id twice returns the existing row, so reconciliation
  after a reconnect is safe.

  With `reopen: true` (the engine lists the question as still pending on
  replay), a row that was resolved or detached locally is set back to a
  pending, attached card and `question_requested` is recorded again, so the
  question never waits without a way to answer it.
  """
  def record(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    case attrs[:opencode_question_id] && get_by_opencode_id(attrs[:opencode_question_id]) do
      %QuestionRequest{} = existing ->
        if opts[:reopen] && (existing.status != "pending" or existing.detached_at),
          do: reopen(existing),
          else: {:ok, existing}

      _ ->
        Multi.new()
        |> Multi.insert(:request, QuestionRequest.changeset(%QuestionRequest{}, attrs))
        |> Timeline.multi_record(:event, &requested_event/1)
        |> commit()
    end
  end

  defp reopen(request) do
    Multi.new()
    |> Multi.update(
      :request,
      QuestionRequest.changeset(request, %{
        status: "pending",
        answers: [],
        resolved_at: nil,
        detached_at: nil
      })
    )
    |> Timeline.multi_record(:event, &requested_event/1)
    |> commit()
  end

  defp requested_event(%{request: r}) do
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
  end

  @doc """
  Resolves a pending question. `{:answered, answers}` carries one list of chosen
  labels per question, in question order; `:rejected` means the user declined to
  answer. `by: "user"` records that the local user answered it from the card;
  `delivered: "message"` with `message_id:` that the answer was posted to the
  channel as a message mentioning the agent, because it had stopped waiting.
  """
  def resolve(%QuestionRequest{} = request, outcome, opts \\ []) do
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
        payload:
          %{
            "headers" => headers(r),
            "status" => r.status,
            "answers" => r.answers,
            "by" => opts[:by]
          }
          |> put_present("delivered", opts[:delivered])
          |> put_present("message_id", opts[:message_id])
      }
    end)
    |> commit()
  end

  @doc """
  Marks a pending question as no longer waited on and records
  `question_detached`. The card stays pending; a request that is already
  detached or resolved is returned unchanged.
  """
  def detach(%QuestionRequest{status: "pending", detached_at: nil} = request) do
    Multi.new()
    |> Multi.update(
      :request,
      QuestionRequest.changeset(request, %{detached_at: DateTime.utc_now()})
    )
    |> Timeline.multi_record(:event, fn %{request: r} ->
      %{
        channel_id: r.channel_id,
        agent_id: agent_id_of(r),
        event_type: "question_detached",
        ref_id: r.id,
        payload: %{"headers" => headers(r)}
      }
    end)
    |> commit()
  end

  def detach(%QuestionRequest{} = request), do: {:ok, request}

  def pending_for_channel(channel_id) do
    Repo.all(
      from q in QuestionRequest,
        where: q.channel_id == ^channel_id and q.status == "pending",
        order_by: [asc: q.id],
        preload: ^@preloads
    )
  end

  @doc "Pending questions an agent session is still waiting on (not detached)."
  def waiting_for_session(agent_session_id) do
    Repo.all(
      from q in QuestionRequest,
        where:
          q.agent_session_id == ^agent_session_id and q.status == "pending" and
            is_nil(q.detached_at),
        order_by: [asc: q.id],
        preload: ^@preloads
    )
  end

  @doc """
  Pending questions agents on `engine` still wait on (not detached), in every
  channel of the repository, with their sessions preloaded.
  """
  def waiting_in_repository(repository_id, engine) do
    Repo.all(
      from q in QuestionRequest,
        join: c in assoc(q, :channel),
        join: s in assoc(q, :agent_session),
        where: c.repository_id == ^repository_id and s.engine == ^engine,
        where: q.status == "pending" and is_nil(q.detached_at),
        order_by: [asc: q.id],
        preload: ^@preloads
    )
  end

  @doc """
  Pending questions per open channel id that still need the user, for the
  sidebar: every attached card, and detached ones younger than `fresh_since`.
  """
  def pending_counts(%DateTime{} = fresh_since) do
    from(q in QuestionRequest,
      join: c in assoc(q, :channel),
      where: q.status == "pending" and c.status != "archived",
      where: is_nil(q.detached_at) or q.detached_at > ^fresh_since,
      group_by: q.channel_id,
      select: {q.channel_id, count(q.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The short labels the agent attaches to each question, for the feed line."
  def headers(%QuestionRequest{questions: questions}),
    do: Enum.map(questions, &(&1["header"] || &1["question"]))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
