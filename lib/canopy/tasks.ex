defmodule Canopy.Tasks do
  @moduledoc "The one task per channel. Updates record a `task_updated` event."

  import Ecto.Query, warn: false

  alias Canopy.Repo
  alias Canopy.Tasks.Task
  alias Canopy.Timeline
  alias Ecto.Multi

  @preloads [:owner]

  def for_channel(channel_id) do
    Task |> Repo.get_by(channel_id: channel_id) |> Repo.preload(@preloads)
  end

  def get!(id), do: Task |> Repo.get!(id) |> Repo.preload(@preloads)

  @doc """
  Updates a task and records `task_updated` with the changed fields. Options:
  `:agent_id` — the agent making the change, stored on the event. A status
  moving into or out of `completed` also broadcasts `{:channels, :changed}`,
  so every sidebar's done mark follows.
  """
  def update(%Task{} = task, attrs, opts \\ []) do
    changeset = Task.update_changeset(task, attrs)
    changes = changeset.changes |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    Multi.new()
    |> Multi.update(:task, changeset)
    |> Timeline.multi_record(:event, fn %{task: task} ->
      %{
        channel_id: task.channel_id,
        agent_id: Keyword.get(opts, :agent_id),
        event_type: "task_updated",
        ref_id: task.id,
        payload: %{"changes" => changes, "status" => task.status, "title" => task.title}
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{task: updated, event: event}} ->
        Timeline.broadcast(event)
        # the sidebar's done mark follows the task into and out of completed
        if Map.has_key?(changes, "status") and "completed" in [task.status, updated.status],
          do: Canopy.Channels.notify_changed()

        {:ok, Repo.preload(updated, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  def change(%Task{} = task, attrs \\ %{}), do: Task.update_changeset(task, attrs)
end
