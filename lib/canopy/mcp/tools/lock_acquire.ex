defmodule Canopy.MCP.Tools.LockAcquire do
  @moduledoc """
  Take a lock on a shared resource of this repository before using it: the
  test suite and its database, e2e ports, a screenshot or video run. Call it
  before `mix test`, `mix precommit`, Playwright, or anything that starts a
  server or writes shared output. If someone else holds it you are put in
  line: end your turn, and Canopy wakes you when it is yours. A lock is
  released when your turn ends; never announce, pass, or broker locks in
  messages.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Locks, Runtime}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :name, :string,
      description:
        "The lock, shared by everyone on this repository. Default \"tests\" (the test suite, its database and ports); use another name only for a resource of its own, such as \"e2e\" or \"ports:4100\"."

    field :reason, :string,
      description: "What you need it for, in a few words. Shown to the user and to whoever waits."

    field :hold_across_turns, :boolean,
      description:
        "Keep the lock after this turn ends, until you call canopy_lock_release. Rarely needed; Canopy frees it after a while regardless."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      name = Tool.blank_to_nil(Map.get(params, :name)) || Locks.default_name()
      hold? = Map.get(params, :hold_across_turns) == true
      turn_ref = Runtime.turn_ref(ctx.channel.id, ctx.session.id)

      ctx.session
      |> Locks.acquire(ctx.repository.id, name, Map.get(params, :reason),
        hold_across_turns: hold?,
        turn_ref: turn_ref
      )
      |> reply(ctx)
    end)
  end

  defp reply({:granted, claim}, _ctx),
    do: {:ok, "You hold `#{claim.name}` now. " <> release_line(claim)}

  defp reply({:already_held, claim}, _ctx),
    do:
      {:ok, "You already hold `#{claim.name}` (for #{Locks.age(claim)}). " <> release_line(claim)}

  defp reply({:queued, claim, position, holder}, ctx) do
    lock = Locks.get(ctx.repository.id, claim.name)
    ahead = lock.queue |> Enum.take(position - 1) |> Enum.map(&Locks.holder_name/1)
    after_line = if ahead == [], do: "", else: " after #{Enum.join(ahead, ", ")}"
    reason = if holder.reason, do: " for \"#{holder.reason}\"", else: ""

    waiting_on_user =
      if lock.awaiting_user?,
        do:
          " #{Locks.holder_name(holder)} is waiting on the user's answer to a card, so this may take a while.",
        else: ""

    {:ok,
     "`#{claim.name}` is held by #{Locks.holder_name(holder)}#{where(holder, ctx)}#{reason}, " <>
       "#{Locks.age(holder)}. You are #{ordinal(position)} in line#{after_line}.#{waiting_on_user} " <>
       "End your turn now; Canopy will wake you when it's yours. " <>
       "Don't run anything that needs the lock until then."}
  end

  defp reply({:error, %Ecto.Changeset{} = changeset}, _ctx),
    do: {:error, "could not take the lock: " <> Tool.changeset_reason(changeset)}

  defp reply({:error, reason}, _ctx) when is_binary(reason), do: {:error, reason}

  defp release_line(%{hold_across_turns: true}),
    do:
      "You asked to keep it across turns: it stays yours until you call canopy_lock_release, " <>
        "and Canopy frees it after #{div(Canopy.Settings.lock_hold_ms(), 60_000)} minutes regardless."

  defp release_line(_claim),
    do: "It is released when this turn ends, or call canopy_lock_release when you are done."

  # the holder's channel, when it is not this one
  defp where(%{channel: %{id: id, name: name}}, ctx) when id != ctx.channel.id,
    do: " (in ##{name})"

  defp where(_holder, _ctx), do: ""

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n), do: "#{n}th"
end
