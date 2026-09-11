defmodule Canopy.MCP.Tools.SchedulesList do
  @moduledoc "List scheduled tasks: this channel's by default, or one agent's across channels."

  use Anubis.Server.Component, type: :tool

  alias Canopy.Schedules
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :agent, :string, description: "Show this agent's schedules across all channels instead."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, schedules} <- fetch(ctx, params) do
        case schedules do
          [] -> {:ok, "No active or paused schedules."}
          list -> {:ok, Enum.map_join(list, "\n", &line/1)}
        end
      end
    end)
  end

  defp fetch(ctx, params) do
    case Tool.blank_to_nil(Map.get(params, :agent)) do
      nil ->
        with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)) do
          {:ok, Schedules.list_for_channel(channel.id)}
        end

      ref ->
        with {:ok, agent} <- Tool.resolve_agent(ref) do
          {:ok, Schedules.list_for_agent(agent.id)}
        end
    end
  end

  defp line(s) do
    timing =
      case s.kind do
        "once" -> "once"
        "recurring" -> Schedules.describe_cron(s.cron)
      end

    status = if s.status == "paused", do: " (paused: #{s.status_reason})", else: ""

    "[#{s.id}] @#{s.agent.name} in ##{s.channel.name}: #{timing}, next #{Schedules.local_text(s.next_run_at)} " <>
      "(#{Schedules.relative(s.next_run_at)})#{status} — #{String.slice(s.instruction, 0, 120)}"
  end
end
