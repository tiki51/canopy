defmodule Canopy.MCP.Tools.LockRelease do
  @moduledoc """
  Let go of a lock you hold, or leave its line if you are waiting. Locks are
  released when your turn ends anyway; call this when you finish early, or
  for a lock you held across turns. The next in line is woken by Canopy, so
  there is no need to tell anyone.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Locks
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :name, :string, description: "The lock. Default \"tests\"."

    field :note, :string,
      description:
        "Optional: what the next holder should know (\"done, shots are in .canopy/out/shots\"). Shown on the timeline."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      name = Tool.blank_to_nil(Map.get(params, :name)) || Locks.default_name()
      note = Tool.blank_to_nil(Map.get(params, :note))

      case Locks.release(ctx.session, ctx.repository.id, name, note) do
        {:ok, :released, nil} ->
          {:ok, "Released `#{name}`; nobody was waiting."}

        {:ok, :released, next} ->
          {:ok,
           "Released `#{name}`; it is #{Locks.holder_name(next)}'s now, and Canopy has woken them."}

        {:ok, :left_queue, nil} ->
          {:ok, "Left the line for `#{name}`."}

        {:error, :not_found} ->
          {:ok, "You neither hold `#{name}` nor wait for it; nothing to release."}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}
      end
    end)
  end
end
