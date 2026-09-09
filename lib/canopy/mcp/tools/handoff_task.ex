defmodule Canopy.MCP.Tools.HandoffTask do
  @moduledoc """
  Hand the channel task to another member. Only the current owner can hand
  off. Canopy attaches a packet (branch, git status, diff stat, recent
  message ids, task) and wakes the target, who must accept or reject; you stay
  owner until they accept.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{AgentSessions, Handoffs, Messages, Repositories, Tasks}
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :to, {:required, :string},
      description: "Agent to hand off to: @name, name, or agent id."

    field :summary, {:required, :string}, description: "What you did and where things stand."
    field :reason, :string, description: "Why this agent should take over."
    field :suggested_next_step, :string, description: "What the new owner should do first."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           :ok <- check_owner(ctx, channel),
           {:ok, target} <-
             Tool.resolve_counterpart(ctx, channel, Map.get(params, :to), "hand off"),
           {:ok, summary} <- summary(params),
           {:ok, handoff} <- request(ctx, channel, target, summary, params) do
        packet = handoff.packet || %{}

        {:ok,
         "handoff [#{handoff.id}] requested: @#{target.name} has been asked to take over ##{channel.name} " <>
           "(branch #{packet["branch"] || "unknown"}, #{length(packet["changed_files"] || [])} changed file(s)). " <>
           "You remain owner until they accept."}
      end
    end)
  end

  defp check_owner(ctx, channel) do
    cond do
      is_nil(channel.owner_agent_id) ->
        {:error, "##{channel.name} has no owner to hand off from"}

      channel.owner_agent_id != ctx.agent.id ->
        {:error,
         "only the owner (#{Format.agent_ref(channel.owner)}) can hand off ##{channel.name}"}

      true ->
        :ok
    end
  end

  defp summary(params) do
    case Tool.blank_to_nil(Map.get(params, :summary)) do
      nil -> {:error, "summary is empty"}
      summary -> {:ok, summary}
    end
  end

  defp request(ctx, channel, target, summary, params) do
    task = Tasks.for_channel(channel.id)
    target_session = AgentSessions.get_root(channel.id, target.id)

    attrs = %{
      channel_id: channel.id,
      task_id: task && task.id,
      from_agent_id: ctx.agent.id,
      to_agent_id: target.id,
      source_session_id: ctx.session.id,
      target_session_id: target_session && target_session.id,
      summary: summary,
      reason: Tool.blank_to_nil(Map.get(params, :reason)),
      suggested_next_step: Tool.blank_to_nil(Map.get(params, :suggested_next_step)),
      packet: build_packet(channel, task)
    }

    case Handoffs.request(attrs) do
      {:ok, handoff} -> {:ok, handoff}
      {:error, changeset} -> {:error, "could not hand off: " <> Tool.changeset_reason(changeset)}
    end
  end

  @doc "Assembles the context packet stored on the handoff."
  def build_packet(channel, task) do
    repository = channel.repository

    %{
      "branch" => ok_or_nil(Repositories.current_branch(repository)),
      "status" => ok_or_nil(Repositories.status(repository)) || [],
      "changed_files" => ok_or_nil(Repositories.changed_files(repository)) || [],
      "diff_stat" => ok_or_nil(Repositories.diff_stat(repository)),
      "recent_message_ids" => channel.id |> Messages.list(limit: 10) |> Enum.map(& &1.id),
      "task" => task_snapshot(task)
    }
  end

  defp task_snapshot(nil), do: %{}

  defp task_snapshot(task) do
    %{
      "id" => task.id,
      "title" => task.title,
      "status" => task.status,
      "description" => task.description,
      "result" => task.result
    }
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil
end
