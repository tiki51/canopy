defmodule Canopy.QuestionRequests.QuestionRequest do
  @moduledoc """
  A question an agent asked through OpenCode's `question` tool, stored with the
  event payload as received.

  `questions` is OpenCode's list of `QuestionInfo` maps (`"question"`, `"header"`,
  `"options"`, and the optional `"multiple"` / `"custom"` flags). `answers` is one
  list of chosen labels per question, in the same order, as OpenCode's reply
  endpoint expects.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["qr"]}}
  @foreign_key_type :string

  @statuses ~w(pending answered rejected)

  schema "question_requests" do
    field :opencode_question_id, :string
    field :questions, {:array, :map}, default: []
    field :answers, {:array, {:array, :string}}, default: []
    field :tool_call_id, :string
    field :status, :string, default: "pending"
    field :resolved_at, :utc_datetime_usec
    # set when the agent stopped waiting (its turn ended, or the wait ran out);
    # the card stays answerable and an answer then wakes the agent
    field :detached_at, :utc_datetime_usec

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent_session, Canopy.AgentSessions.AgentSession

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :channel_id,
      :agent_session_id,
      :opencode_question_id,
      :questions,
      :answers,
      :tool_call_id,
      :status,
      :resolved_at,
      :detached_at
    ])
    |> validate_required([
      :channel_id,
      :agent_session_id,
      :opencode_question_id,
      :status
    ])
    |> validate_questions()
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_session_id)
    |> unique_constraint(:opencode_question_id)
  end

  # An empty list is the field's default, so validate_length would never see it
  # as a change: a question card with nothing to answer would be stored.
  defp validate_questions(changeset) do
    if get_field(changeset, :questions) in [nil, []],
      do: add_error(changeset, :questions, "must hold at least one question"),
      else: changeset
  end
end
