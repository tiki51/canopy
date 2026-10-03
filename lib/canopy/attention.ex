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

  import Ecto.Query, only: [from: 2]

  alias Canopy.{PermissionRequests, QuestionRequests, Repo}
  alias Canopy.Channels.Channel
  alias Canopy.PermissionRequests.PermissionRequest
  alias Canopy.Playbooks.Runs
  alias Canopy.QuestionRequests.QuestionRequest
  alias Canopy.Timeline.Event

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

  @doc """
  The `question_requested` and `permission_requested` events of the cards
  still waiting on the user that were raised (or raised again) since
  `since`, in open channels, oldest first, with the asking agent. Desktop
  notifications use them to catch up after a page reconnects.
  """
  def pending_card_events(%DateTime{} = since) do
    [{QuestionRequest, "question_requested"}, {PermissionRequest, "permission_requested"}]
    |> Enum.flat_map(fn {schema, type} ->
      Repo.all(
        from e in Event,
          join: r in ^schema,
          on: r.id == e.ref_id,
          join: c in Channel,
          on: c.id == r.channel_id,
          where: e.event_type == ^type and r.status == "pending" and c.status == "open",
          where: e.inserted_at > ^since
      )
    end)
    # a card raised again (reopened on replay) has one event per raise
    |> Enum.sort_by(& &1.id)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.ref_id)
    |> Enum.reverse()
    |> Repo.preload(:agent)
  end

  @doc "How many things in the summary entry wait on the user."
  def total(%{questions: q, permissions: p} = entry), do: q + p + Map.get(entry, :approvals, 0)
  def total(_), do: 0

  @doc "Whether the channel has a playbook run in progress."
  def playbook?(%{playbook: true}), do: true
  def playbook?(_), do: false
end
