defmodule Canopy.MCP.Tools.ScheduleCreate do
  @moduledoc """
  Schedule something for later, once or on a repeat. When it is due, Canopy
  wakes the agent in the channel with the instruction you write here, and
  nothing else: write it as a note to your future self. You can schedule for
  yourself; the channel owner can schedule for any member.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Schedules
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :when, {:required, :string},
      description:
        "An ISO datetime (2026-09-11T09:00, local unless it has an offset), a duration (30m, 2h, 1d), or a five-field cron line (0 9 * * 1-5) for a repeat, in local time."

    field :what, {:required, :string},
      description:
        "The instruction your future self will be given. Self-contained; include ids and paths."

    field :channel, :string, description: "Channel name or id. Defaults to your own channel."

    field :agent, :string,
      description: "Agent to wake (@name). Defaults to you; the owner may name any member."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, agent} <- target(ctx, channel, Map.get(params, :agent)),
           {:ok, what} <- required(Map.get(params, :what), "what"),
           {:ok, schedule} <- create(ctx, channel, agent, Map.get(params, :when), what) do
        {:ok, describe(schedule)}
      end
    end)
  end

  defp target(ctx, _channel, nil), do: {:ok, ctx.agent}

  defp target(ctx, channel, value) do
    with {:ok, agent} <- Tool.resolve_agent(value) do
      cond do
        agent.id == ctx.agent.id ->
          {:ok, agent}

        not Canopy.Channels.member?(channel, agent) ->
          {:error, "@#{agent.name} is not a member of ##{channel.name}"}

        channel.owner_agent_id != ctx.agent.id ->
          {:error, "only the owner of ##{channel.name} can schedule for @#{agent.name}"}

        true ->
          {:ok, agent}
      end
    end
  end

  defp required(value, name) do
    case Tool.blank_to_nil(value) do
      nil -> {:error, "#{name} is empty"}
      text -> {:ok, text}
    end
  end

  defp create(ctx, channel, agent, when_value, what) do
    case Schedules.create(%{
           channel_id: channel.id,
           agent_id: agent.id,
           created_by_agent_id: ctx.agent.id,
           instruction: what,
           when: when_value
         }) do
      {:ok, schedule} ->
        {:ok, schedule}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "could not schedule: " <> Tool.changeset_reason(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, String.replace(reason, "@agent", "@" <> agent.name)}
    end
  end

  defp describe(schedule) do
    at =
      "#{Schedules.local_text(schedule.next_run_at)} (#{Schedules.relative(schedule.next_run_at)})"

    timing =
      case schedule.kind do
        "once" -> "at #{at}"
        "recurring" -> "#{Schedules.describe_cron(schedule.cron)}, next #{at}"
      end

    "scheduled [#{schedule.id}] for @#{schedule.agent.name} in ##{schedule.channel.name} #{timing}. " <>
      "It will be woken with your instruction then; cancel with canopy_schedule_cancel."
  end
end
