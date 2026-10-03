defmodule Canopy.MCP.Tools.TaskUpdate do
  @moduledoc """
  Update the channel task: status (open, working, blocked, completed), result,
  title, or description.

  If you have a delegated subtask pending in the channel, this reports on the
  delegation instead of the channel task: status "completed" (or a bare result)
  completes the delegation with your result, "blocked" marks it failed with
  your result as the reason, and whoever delegated it is notified. With several
  pending, pass `delegation` (its id, or `dl_` plus its first eight
  characters) to say which. Only the task owner changes the channel task itself.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Delegations, Tasks}
  alias Canopy.Tasks.Task
  alias Canopy.MCP.{Format, Tool}

  @pending ~w(requested working)

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :status, :string, description: "One of open, working, blocked, completed."

    field :result, :string,
      description: "Outcome or findings, kept on the task (or on your delegation)."

    field :title, :string, description: "New task title."
    field :description, :string, description: "New task description."

    field :delegation, :string,
      description:
        "The delegation you are reporting on: its id or short form (dl_ plus 8 characters). " <>
          "Needed when you have several pending."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, attrs} <- attrs(params) do
        case pending_delegation(ctx, channel, Tool.blank_to_nil(Map.get(params, :delegation))) do
          {:ok, nil} -> update_task(channel, attrs, ctx)
          {:ok, delegation} -> report_delegation(delegation, attrs, channel)
          {:error, _} = error -> error
        end
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

  # -- Owner path: the channel task ------------------------------------------

  defp update_task(channel, attrs, ctx) do
    with {:ok, task} <- fetch_task(channel),
         {:ok, task} <- update(task, attrs, ctx) do
      {:ok, "updated task in ##{channel.name}\n" <> Format.task_block(task)}
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

  # -- Delegate path: the delegation, never the channel task ------------------

  defp report_delegation(delegation, attrs, channel) do
    result = attrs[:result]

    delegator =
      if delegation.from_agent, do: Format.agent_ref(delegation.from_agent), else: "the channel"

    case attrs[:status] do
      "completed" ->
        finish(delegation, :complete, result || "completed", delegator)

      nil when is_binary(result) ->
        finish(delegation, :complete, result, delegator)

      "blocked" ->
        finish(delegation, :fail, result || "blocked", delegator)

      "working" ->
        {:ok,
         "noted: you are still working on delegation [#{delegation.id}] in ##{channel.name}. " <>
           "Call task_update with status \"completed\" and a result when done."}

      _ ->
        {:error,
         "you are working on delegation [#{delegation.id}]; report with status completed (plus result) " <>
           "or blocked. Only the task owner can change the channel task."}
    end
  end

  defp finish(delegation, action, result, delegator) do
    outcome =
      case action do
        :complete -> Delegations.complete(delegation, result)
        :fail -> Delegations.fail(delegation, result)
      end

    case outcome do
      {:ok, delegation} ->
        verb = if action == :complete, do: "completed", else: "marked blocked"
        {:ok, "delegation [#{delegation.id}] #{verb}; #{delegator} will be notified."}

      {:error, changeset} ->
        {:error, "could not update delegation: " <> Tool.changeset_reason(changeset)}
    end
  end

  # The delegation a call reports on. Named: that one, if it is pending and
  # addressed to the caller. Unnamed: the caller's only pending delegation in
  # the channel; with several, the caller has to say which; with none, the
  # call is about the channel task. Identity is the session's, never the model's.
  defp pending_delegation(ctx, channel, nil) do
    case Delegations.list_pending_for(channel.id, ctx.agent.id) do
      [] ->
        {:ok, nil}

      [delegation] ->
        {:ok, delegation}

      pending ->
        {:error,
         "you have #{length(pending)} pending delegations in ##{channel.name} " <>
           "(#{Enum.map_join(pending, ", ", &describe/1)}); pass `delegation` with the one you are reporting on."}
    end
  end

  # A short id can match several delegations made within the same second;
  # the caller's own pending one among them is the one meant.
  defp pending_delegation(ctx, channel, ref) do
    matches = Delegations.matching(channel.id, ref)

    mine =
      Enum.filter(matches, &(&1.to_agent_id == ctx.agent.id and &1.status in @pending))

    case {mine, matches} do
      {[delegation], _} ->
        {:ok, delegation}

      {[_, _ | _] = several, _} ->
        {:error,
         "#{ref} matches #{length(several)} of your delegations (#{Enum.map_join(several, ", ", & &1.id)}); pass the full id."}

      {[], []} ->
        {:error, "no delegation #{ref} in ##{channel.name}"}

      {[], [%{to_agent_id: to} = delegation]} when to != ctx.agent.id ->
        {:error,
         "delegation [#{delegation.id}] is addressed to #{Format.agent_ref(delegation.to_agent)}, not to you"}

      {[], [delegation]} ->
        {:error, "delegation [#{delegation.id}] is already #{delegation.status}"}

      {[], several} ->
        {:error,
         "#{ref} matches #{length(several)} delegations, none of them pending for you; pass the full id."}
    end
  end

  defp describe(delegation) do
    description = delegation.description |> Format.single_line() |> Format.truncate(60)

    "#{delegation.id} \"#{description}\""
  end
end
