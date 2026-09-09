defmodule Canopy.Tasks.Task do
  @moduledoc "The single current task of a channel (`tasks.channel_id` is unique)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["tsk"]}}
  @foreign_key_type :string

  @statuses ~w(open working blocked completed)

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :result, :string

    belongs_to :channel, Canopy.Channels.Channel
    belongs_to :owner, Canopy.Agents.Agent, foreign_key: :owner_agent_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:channel_id, :owner_agent_id, :title, :description, :status, :result])
    |> validate_required([:channel_id, :title, :status])
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:owner_agent_id)
    |> unique_constraint(:channel_id, message: "already has a task")
  end

  def update_changeset(task, attrs) do
    task
    |> cast(attrs, [:owner_agent_id, :title, :description, :status, :result])
    |> validate_required([:title, :status])
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:owner_agent_id)
  end
end
