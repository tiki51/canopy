defmodule Canopy.MCP.Tools.ScheduleCancel do
  @moduledoc "Cancel a schedule: your own, or any in a channel you own."

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Schedules}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :id, {:required, :string}, description: "The schedule id (sch_…)."
    field :reason, :string, description: "Why, in a few words. Shown on the timeline."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, schedule} <- find(Map.get(params, :id)),
           :ok <- permitted(ctx, schedule),
           {:ok, schedule} <-
             Schedules.cancel(
               schedule,
               Tool.blank_to_nil(Map.get(params, :reason)) || "cancelled by @#{ctx.agent.name}"
             ) do
        {:ok,
         "cancelled [#{schedule.id}] for @#{schedule.agent.name} in ##{schedule.channel.name}."}
      end
    end)
  end

  defp find(id) do
    case Tool.blank_to_nil(id) && Schedules.get(id) do
      %Schedules.Schedule{} = schedule -> {:ok, schedule}
      _ -> {:error, "unknown schedule #{inspect(id)}"}
    end
  end

  defp permitted(ctx, schedule) do
    cond do
      schedule.channel.repository_id != ctx.repository.id ->
        {:error, "unknown schedule"}

      not Channels.member?(schedule.channel, ctx.agent) ->
        {:error, "not a member of ##{schedule.channel.name}"}

      Schedules.permitted?(ctx.agent, schedule.channel, schedule.agent_id) ->
        :ok

      true ->
        {:error,
         "only @#{schedule.agent.name} or the owner of ##{schedule.channel.name} can cancel it"}
    end
  end
end
