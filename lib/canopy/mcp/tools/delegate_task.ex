defmodule Canopy.MCP.Tools.DelegateTask do
  @moduledoc """
  Delegate a bounded subtask to another member of the channel. You keep
  ownership of the task; the delegate works in a child session and you are
  woken with the result when they report completion.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Delegations, Tasks}
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :to, {:required, :string},
      description: "Agent to delegate to: @name, name, or agent id."

    field :task, {:required, :string}, description: "What the delegate should do, self-contained."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, delegate} <-
             Tool.resolve_counterpart(ctx, channel, Map.get(params, :to), "delegate"),
           {:ok, description} <- description(params),
           {:ok, delegation} <- create(ctx, channel, delegate, description) do
        {:ok,
         "delegation [#{delegation.id}] requested: @#{delegate.name} will work on it in ##{channel.name}. " <>
           "You will be woken when it completes; ownership stays with #{Format.agent_ref(channel.owner)}."}
      end
    end)
  end

  defp description(params) do
    case Tool.blank_to_nil(Map.get(params, :task)) do
      nil -> {:error, "task is empty"}
      task -> {:ok, task}
    end
  end

  defp create(ctx, channel, delegate, description) do
    task = Tasks.for_channel(channel.id)

    attrs = %{
      channel_id: channel.id,
      task_id: task && task.id,
      from_agent_id: ctx.agent.id,
      to_agent_id: delegate.id,
      parent_session_id: ctx.session.id,
      description: description
    }

    case Delegations.create(attrs) do
      {:ok, delegation} -> {:ok, delegation}
      {:error, changeset} -> {:error, "could not delegate: " <> Tool.changeset_reason(changeset)}
    end
  end
end
