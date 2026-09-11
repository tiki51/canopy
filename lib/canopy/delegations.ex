defmodule Canopy.Delegations do
  @moduledoc "Bounded subtasks handed to another agent; ownership never changes."

  import Ecto.Query, warn: false

  alias Canopy.Delegations.Delegation
  alias Canopy.Repo
  alias Canopy.Timeline
  alias Ecto.Multi

  @preloads [:from_agent, :to_agent, :task]
  @pending ~w(requested working)

  def get!(id), do: Delegation |> Repo.get!(id) |> Repo.preload(@preloads)
  def get(id), do: Delegation |> Repo.get(id) |> Repo.preload(@preloads)

  @doc "Creates a delegation (status `requested`) and records `delegation_created`."
  def create(attrs) do
    Multi.new()
    |> Multi.insert(:delegation, Delegation.changeset(%Delegation{}, attrs))
    |> Timeline.multi_record(:event, fn %{delegation: d} ->
      %{
        channel_id: d.channel_id,
        agent_id: d.from_agent_id,
        event_type: "delegation_created",
        ref_id: d.id,
        payload: %{
          "from_agent_id" => d.from_agent_id,
          "to_agent_id" => d.to_agent_id,
          "description" => d.description
        }
      }
    end)
    |> commit()
  end

  @doc "Marks the delegation as working and stores the delegate's child session."
  def start(%Delegation{} = delegation, child_session_id) do
    delegation
    |> Delegation.changeset(%{status: "working", child_session_id: child_session_id})
    |> Repo.update()
    |> preload()
  end

  @doc "Completes the delegation with a result and records `delegation_completed`."
  def complete(%Delegation{} = delegation, result) do
    finish(delegation, "completed", result, "delegation_completed")
  end

  @doc "Fails the delegation with a reason and records `delegation_failed`."
  def fail(%Delegation{} = delegation, reason) do
    finish(delegation, "failed", reason, "delegation_failed")
  end

  def cancel(%Delegation{} = delegation) do
    delegation
    |> Delegation.changeset(%{status: "cancelled", completed_at: DateTime.utc_now()})
    |> Repo.update()
    |> preload()
  end

  @doc "Delegations addressed to `agent_id` in a channel that are still requested or working."
  def list_pending_for(channel_id, agent_id) do
    Repo.all(
      from d in Delegation,
        where:
          d.channel_id == ^channel_id and d.to_agent_id == ^agent_id and
            d.status in ^@pending,
        order_by: [asc: d.id],
        preload: ^@preloads
    )
  end

  @doc "The pending delegation whose child session is `session_id`, if any."
  def get_by_child_session(session_id) do
    Repo.one(
      from d in Delegation,
        where: d.child_session_id == ^session_id and d.status in ^@pending,
        preload: ^@preloads
    )
  end

  defp finish(delegation, status, result, event_type) do
    Multi.new()
    |> Multi.update(
      :delegation,
      Delegation.changeset(delegation, %{
        status: status,
        result: result,
        completed_at: DateTime.utc_now()
      })
    )
    |> Timeline.multi_record(:event, fn %{delegation: d} ->
      %{
        channel_id: d.channel_id,
        agent_id: d.to_agent_id,
        event_type: event_type,
        ref_id: d.id,
        payload: %{
          "from_agent_id" => d.from_agent_id,
          "to_agent_id" => d.to_agent_id,
          "status" => d.status,
          "result" => d.result
        }
      }
    end)
    |> commit()
  end

  defp commit(multi) do
    case Repo.transaction(multi) do
      {:ok, %{delegation: delegation, event: event}} ->
        Timeline.broadcast(event)
        {:ok, Repo.preload(delegation, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  defp preload({:ok, delegation}), do: {:ok, Repo.preload(delegation, @preloads, force: true)}
  defp preload(other), do: other
end
