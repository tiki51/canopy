defmodule Canopy.MCP.Tools.TaskUpdate do
  @moduledoc """
  Update the channel task: status (open, working, blocked, completed), result,
  title, or description. If you are working on a delegated subtask, reporting
  status "completed" (or a result) also completes the delegation and wakes the
  agent who delegated it.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Delegations, Tasks}
  alias Canopy.Tasks.Task
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :status, :string, description: "One of open, working, blocked, completed."
    field :result, :string, description: "Outcome or findings, kept on the task."
    field :title, :string, description: "New task title."
    field :description, :string, description: "New task description."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, attrs} <- attrs(params),
           {:ok, task} <- fetch_task(channel),
           {:ok, task} <- update(task, attrs, ctx) do
        delegation_note = maybe_complete_delegation(ctx, channel, task, attrs)
        {:ok, "updated task in ##{channel.name}\n" <> Format.task_block(task) <> delegation_note}
      end
    end)
  end

  defp attrs(params) do
    attrs =
      [:status, :result, :title, :description]
      |> Enum.map(fn key -> {key, Tool.blank_to_nil(Map.get(params, key))} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    cond do
      attrs == %{} ->
        {:error, "nothing to update; pass status, result, title, or description"}

      is_map_key(attrs, :status) and attrs.status not in Task.statuses() ->
        {:error, "status must be one of " <> Enum.join(Task.statuses(), ", ")}

      true ->
        {:ok, attrs}
    end
  end

  defp fetch_task(channel) do
    case Tasks.for_channel(channel.id) do
      nil -> {:error, "##{channel.name} has no task"}
      task -> {:ok, task}
    end
  end

  defp update(task, attrs, ctx) do
    case Tasks.update(task, attrs, agent_id: ctx.agent.id) do
      {:ok, task} ->
        {:ok, task}

      {:error, changeset} ->
        {:error, "could not update task: " <> Tool.changeset_reason(changeset)}
    end
  end

  # A delegate reporting completion (or a bare result) closes its delegation.
  defp maybe_complete_delegation(ctx, channel, task, attrs) do
    finished? =
      attrs[:status] == "completed" or (is_nil(attrs[:status]) and not is_nil(attrs[:result]))

    with true <- finished?,
         %{} = delegation <- pending_delegation(ctx, channel),
         {:ok, delegation} <-
           Delegations.complete(delegation, attrs[:result] || task.result || "completed") do
      "\nDelegation [#{delegation.id}] completed; #{Format.agent_ref(delegation.from_agent)} will be notified."
    else
      _ -> ""
    end
  end

  defp pending_delegation(ctx, channel) do
    Delegations.get_by_child_session(ctx.session.id) ||
      List.first(Delegations.list_pending_for(channel.id, ctx.agent.id))
  end
end
