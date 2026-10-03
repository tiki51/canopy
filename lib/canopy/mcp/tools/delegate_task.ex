defmodule Canopy.MCP.Tools.DelegateTask do
  @moduledoc """
  Delegate a bounded subtask to another member of the channel. You keep
  ownership of the task; the delegate works on it in its session in the
  channel and you are woken with the result when they report completion.

  The delegate is woken with the task, so a status post about it needn't
  @mention them; a mention only adds a message to their queue. To add to the
  task, cite the delegation id in a message.

  When you coordinate the channel's playbook run, the delegation is made for
  its current step (the run's panel lists it there, and the delegate is told
  which step it is); `step` names another step, or `none`.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Delegations, Tasks}
  alias Canopy.MCP.{Format, Tool}
  alias Canopy.Playbooks.Runs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :to, {:required, :string},
      description: "Agent to delegate to: @name, name, or agent id."

    field :task, {:required, :string}, description: "What the delegate should do, self-contained."

    field :step, :string,
      description:
        "The playbook step this is for, by id, when you coordinate the channel's run. Defaults to the current step; \"none\" for no step."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, delegate} <-
             Tool.resolve_counterpart(ctx, channel, Map.get(params, :to), "delegate"),
           {:ok, description} <- description(params),
           {:ok, step} <- playbook_step(ctx, channel, Tool.blank_to_nil(Map.get(params, :step))),
           {:ok, delegation} <- create(ctx, channel, delegate, description, step) do
        {:ok,
         "delegation [#{delegation.id}] requested#{step_note(step)}: @#{delegate.name} will work on it in ##{channel.name}. " <>
           "You will be woken when it completes; ownership stays with #{Format.agent_ref(channel.owner)}. " <>
           "@#{delegate.name} has the task already, so a post about it needn't @mention them."}
      end
    end)
  end

  defp description(params) do
    case Tool.blank_to_nil(Map.get(params, :task)) do
      nil -> {:error, "task is empty"}
      task -> {:ok, task}
    end
  end

  # The step of the channel's run this delegation is for: the current one by
  # default when the caller coordinates the run, a named one, or none.
  defp playbook_step(_ctx, _channel, "none"), do: {:ok, nil}

  defp playbook_step(ctx, channel, ref) do
    run = Runs.active_for_channel(channel.id)
    coordinator? = match?(%{coordinator_agent_id: id} when id == ctx.agent.id, run)

    cond do
      is_nil(ref) and coordinator? and run.status == "active" ->
        {:ok, Runs.current_step(run)}

      is_nil(ref) ->
        {:ok, nil}

      not coordinator? ->
        {:error, "step is for the coordinator of the channel's playbook run; leave it out"}

      step = Enum.find(run.steps, &(&1.step_id == ref)) ->
        {:ok, step}

      true ->
        {:error,
         "no step #{ref} in #{run.playbook_name}; steps: " <>
           Enum.map_join(run.steps, ", ", & &1.step_id)}
    end
  end

  defp step_note(nil), do: ""
  defp step_note(step), do: " for step `#{step.step_id}`"

  defp create(ctx, channel, delegate, description, step) do
    task = Tasks.for_channel(channel.id)

    attrs = %{
      channel_id: channel.id,
      task_id: task && task.id,
      from_agent_id: ctx.agent.id,
      to_agent_id: delegate.id,
      parent_session_id: ctx.session.id,
      description: description,
      playbook_step_id: step && step.id
    }

    case Delegations.create(attrs) do
      {:ok, delegation} -> {:ok, delegation}
      {:error, changeset} -> {:error, "could not delegate: " <> Tool.changeset_reason(changeset)}
    end
  end
end
