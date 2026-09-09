defmodule Canopy.Handoffs do
  @moduledoc """
  Task ownership transfers. `accept/1` moves the channel owner and task owner to
  the target and records the events, all in one transaction.
  """

  import Ecto.Query, warn: false

  alias Canopy.Channels.Channel
  alias Canopy.Handoffs.Handoff
  alias Canopy.Repo
  alias Canopy.Tasks.Task
  alias Canopy.Timeline
  alias Ecto.Multi

  @preloads [:from_agent, :to_agent, :task, :source_session, :target_session]

  def get!(id), do: Handoff |> Repo.get!(id) |> Repo.preload(@preloads)

  def get(id), do: Handoff |> Repo.get(id) |> Repo.preload(@preloads)

  @doc "Creates a handoff (status `requested`) and records `handoff_requested`."
  def request(attrs) do
    Multi.new()
    |> Multi.insert(:handoff, Handoff.changeset(%Handoff{}, attrs))
    |> Timeline.multi_record(:event, fn %{handoff: h} ->
      %{
        channel_id: h.channel_id,
        agent_id: h.from_agent_id,
        event_type: "handoff_requested",
        ref_id: h.id,
        payload: %{
          "from_agent_id" => h.from_agent_id,
          "to_agent_id" => h.to_agent_id,
          "summary" => h.summary,
          "reason" => h.reason
        }
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{handoff: handoff, event: event}} ->
        Timeline.broadcast(event)
        {:ok, Repo.preload(handoff, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Accepts a requested handoff: sets its status, makes the target agent the
  channel owner and the task owner, and records `handoff_accepted` and
  `owner_changed`. Returns `{:error, :not_pending}` unless the handoff is
  still requested.
  """
  def accept(%Handoff{status: "requested"} = handoff) do
    now = DateTime.utc_now()
    to = handoff.to_agent_id

    Multi.new()
    |> Multi.run(:channel, fn repo, _ ->
      {:ok, repo.get!(Channel, handoff.channel_id)}
    end)
    |> Multi.update(:handoff, Handoff.changeset(handoff, %{status: "accepted", accepted_at: now}))
    |> Multi.update(:owner, fn %{channel: channel} ->
      Ecto.Changeset.change(channel, owner_agent_id: to)
    end)
    |> Multi.run(:task, fn repo, _ ->
      task = task_for(repo, handoff)

      if task do
        repo.update(Ecto.Changeset.change(task, owner_agent_id: to))
      else
        {:ok, nil}
      end
    end)
    |> Timeline.multi_record(:accepted_event, %{
      channel_id: handoff.channel_id,
      agent_id: to,
      event_type: "handoff_accepted",
      ref_id: handoff.id,
      payload: %{"from_agent_id" => handoff.from_agent_id, "to_agent_id" => to}
    })
    |> Timeline.multi_record(:owner_event, fn %{channel: channel} ->
      %{
        channel_id: handoff.channel_id,
        agent_id: to,
        event_type: "owner_changed",
        ref_id: handoff.channel_id,
        payload: %{"from_agent_id" => channel.owner_agent_id, "to_agent_id" => to}
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{handoff: handoff, accepted_event: accepted, owner_event: owner}} ->
        Timeline.broadcast(accepted)
        Timeline.broadcast(owner)
        {:ok, Repo.preload(handoff, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  def accept(%Handoff{}), do: {:error, :not_pending}

  @doc "Rejects a requested handoff with a reason and records `handoff_rejected`."
  def reject(%Handoff{status: "requested"} = handoff, reason) do
    Multi.new()
    |> Multi.update(
      :handoff,
      Handoff.changeset(handoff, %{
        status: "rejected",
        rejection_reason: reason,
        completed_at: DateTime.utc_now()
      })
    )
    |> Timeline.multi_record(:event, %{
      channel_id: handoff.channel_id,
      agent_id: handoff.to_agent_id,
      event_type: "handoff_rejected",
      ref_id: handoff.id,
      payload: %{
        "from_agent_id" => handoff.from_agent_id,
        "to_agent_id" => handoff.to_agent_id,
        "reason" => reason
      }
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{handoff: handoff, event: event}} ->
        Timeline.broadcast(event)
        {:ok, Repo.preload(handoff, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  def reject(%Handoff{}, _reason), do: {:error, :not_pending}

  @doc "Handoffs in a channel that are still waiting for the target's decision."
  def pending_for_channel(channel_id) do
    Repo.all(
      from h in Handoff,
        where: h.channel_id == ^channel_id and h.status == "requested",
        order_by: [asc: h.id],
        preload: ^@preloads
    )
  end

  defp task_for(repo, %Handoff{task_id: task_id}) when is_binary(task_id) do
    repo.get(Task, task_id)
  end

  defp task_for(repo, %Handoff{channel_id: channel_id}) do
    repo.get_by(Task, channel_id: channel_id)
  end
end
