defmodule Canopy.Attention do
  @moduledoc """
  What is waiting on the user, per channel: pending question and permission
  cards, and playbook steps held for the user's sign-off. The sidebar shows
  it so a question asked in a channel the user is not looking at does not go
  unseen. A detached card (the agent moved on, but the answer still reaches
  it) counts for a day, like its card stays undimmed; after that it stays
  answerable without a badge. Archived channels never count.

  Each entry also says whether the channel has a playbook run in progress
  (`playbook: true`), for the sidebar's glyph; that alone counts for nothing.
  """

  alias Canopy.{PermissionRequests, QuestionRequests}
  alias Canopy.Playbooks.Runs

  @type entry :: %{
          questions: non_neg_integer,
          permissions: non_neg_integer,
          approvals: non_neg_integer,
          playbook: boolean
        }
  @type summary :: %{optional(String.t()) => entry}

  @detached_fresh_hours 24

  @doc "Channel id => what waits on the user there, for channels with anything."
  @spec summary() :: summary
  def summary do
    fresh_since = DateTime.add(DateTime.utc_now(), -@detached_fresh_hours, :hour)
    questions = QuestionRequests.pending_counts(fresh_since)
    permissions = PermissionRequests.pending_counts(fresh_since)
    runs = Runs.live_by_channel()

    (Map.keys(questions) ++ Map.keys(permissions) ++ Map.keys(runs))
    |> Enum.uniq()
    |> Map.new(fn id ->
      {id,
       %{
         questions: Map.get(questions, id, 0),
         permissions: Map.get(permissions, id, 0),
         approvals: if(Map.get(runs, id) == "awaiting_approval", do: 1, else: 0),
         playbook: Map.has_key?(runs, id)
       }}
    end)
  end

  @doc "How many things in the summary entry wait on the user."
  def total(%{questions: q, permissions: p} = entry), do: q + p + Map.get(entry, :approvals, 0)
  def total(_), do: 0

  @doc "Whether the channel has a playbook run in progress."
  def playbook?(%{playbook: true}), do: true
  def playbook?(_), do: false
end
