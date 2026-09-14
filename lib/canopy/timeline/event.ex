defmodule Canopy.Timeline.Event do
  @moduledoc """
  One row of the channel feed. Messages appear here as `event_type: "message"`
  with `ref_id` pointing at the message; other rows describe collaboration
  events and carry their details in `payload`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["evt"]}}
  @foreign_key_type :string

  @event_types ~w(
    message
    agent_started agent_turn_completed agent_error session_reset session_compacted
    delegation_created delegation_completed delegation_failed
    handoff_requested handoff_accepted handoff_rejected
    task_updated owner_changed
    member_added member_removed channel_archived channel_reopened repository_switched
    spend_limit_changed spend_limit_reached
    schedule_created schedule_fired schedule_skipped schedule_cancelled schedule_paused schedule_resumed
    permission_requested permission_resolved
    question_requested question_resolved
  )

  schema "timeline_events" do
    field :event_type, :string
    field :ref_id, :string
    field :payload, :map, default: %{}

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :agent, Canopy.Agents.Agent

    # Only populated for `message` events; other event types preload as nil.
    belongs_to :message, Canopy.Messages.Message, foreign_key: :ref_id, define_field: false

    timestamps(type: :utc_datetime_usec)
  end

  def event_types, do: @event_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:channel_id, :agent_id, :event_type, :ref_id, :payload])
    |> validate_required([:channel_id, :event_type, :payload])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:agent_id)
  end
end
