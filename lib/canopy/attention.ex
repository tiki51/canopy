defmodule Canopy.Attention do
  @moduledoc """
  What is waiting on the user, per channel: pending question and permission
  cards. The sidebar shows it so a question asked in a channel the user is not
  looking at does not go unseen. A detached card (the agent moved on, but the
  answer still reaches it) counts for a day, like its card stays undimmed;
  after that it stays answerable without a badge. Archived channels never
  count.
  """

  alias Canopy.{PermissionRequests, QuestionRequests}

  @type summary :: %{
          optional(String.t()) => %{questions: non_neg_integer, permissions: non_neg_integer}
        }

  @detached_fresh_hours 24

  @doc "Channel id => pending question and permission counts, for channels with any."
  @spec summary() :: summary
  def summary do
    fresh_since = DateTime.add(DateTime.utc_now(), -@detached_fresh_hours, :hour)
    questions = QuestionRequests.pending_counts(fresh_since)
    permissions = PermissionRequests.pending_counts(fresh_since)

    (Map.keys(questions) ++ Map.keys(permissions))
    |> Enum.uniq()
    |> Map.new(fn id ->
      {id, %{questions: Map.get(questions, id, 0), permissions: Map.get(permissions, id, 0)}}
    end)
  end

  @doc "How many cards in the summary entry wait on the user."
  def total(%{questions: q, permissions: p}), do: q + p
  def total(_), do: 0
end
