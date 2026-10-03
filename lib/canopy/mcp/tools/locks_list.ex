defmodule Canopy.MCP.Tools.LocksList do
  @moduledoc """
  The locks on this repository's shared resources: who holds each, for how
  long and why, and who is waiting. Every channel on the repository shares
  them.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Locks
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      case Locks.list(ctx.repository.id) do
        [] ->
          {:ok,
           "No locks are held in #{ctx.repository.name}. Call canopy_lock_acquire (name \"#{Locks.default_name()}\" for the test suite) before running anything that needs one."}

        locks ->
          {:ok,
           "Locks in #{ctx.repository.name}:\n" <>
             Enum.map_join(locks, "\n", &lock_line(&1, ctx))}
      end
    end)
  end

  defp lock_line(lock, ctx) do
    holder =
      case lock.holder do
        nil ->
          "free (being passed on)"

        claim ->
          "held by #{who(claim, ctx)}#{channel(claim, ctx)} for #{Locks.age(claim)}" <>
            reason(claim) <>
            if(claim.hold_across_turns, do: ", across turns", else: "") <>
            if(lock.awaiting_user?, do: ", waiting on the user's answer to a card", else: "")
      end

    queue =
      case lock.queue do
        [] ->
          ""

        waiters ->
          ". Waiting: " <>
            (waiters
             |> Enum.with_index(1)
             |> Enum.map_join(", ", fn {claim, i} ->
               "#{i}. #{who(claim, ctx)}#{reason(claim)}"
             end))
      end

    "- `#{lock.name}`: #{holder}#{queue}"
  end

  defp who(%{session_id: id} = claim, %{session: %{id: id}}),
    do: "#{Locks.holder_name(claim)} (you)"

  defp who(claim, _ctx), do: Locks.holder_name(claim)

  defp channel(%{channel: %{id: id, name: name}}, ctx) when id != ctx.channel.id,
    do: " in ##{name}"

  defp channel(_claim, _ctx), do: ""

  defp reason(%{reason: reason}) when is_binary(reason), do: " (\"#{reason}\")"
  defp reason(_claim), do: ""
end
