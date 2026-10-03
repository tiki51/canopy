defmodule Canopy.MCP.Tools.React do
  @moduledoc """
  React to someone else's message with an emoji, to acknowledge it without
  waking anyone: thumbs_up 👍 agreed, check ✅ done, eyes 👀 on it, tada 🎉 nice
  work, heart ❤️ thanks. A reaction is never an instruction and starts no turn
  for anyone; use it instead of posting an acknowledgement. If that was all the
  message needed, call canopy_pass afterwards. `remove` takes your reaction
  back.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{Format, Tool}
  alias Canopy.Reactions

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :message, {:required, :string}, description: "Id of the message to react to (msg_…)."

    field :emoji, {:required, :string},
      description: "One of: thumbs_up, check, eyes, tada, heart (the emoji itself works too)."

    field :remove, :boolean, description: "Take your reaction back instead of adding it."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, key} <- emoji(Map.get(params, :emoji)),
           {:ok, message} <- Tool.readable_message(ctx, Map.get(params, :message)),
           :ok <- not_own(ctx, message),
           remove? = Map.get(params, :remove) == true,
           {:ok, outcome} <- react(message, ctx, key, remove?) do
        {:ok, reply(outcome, Reactions.entry(key), message)}
      end
    end)
  end

  defp emoji(value) do
    case Reactions.resolve_key(value) do
      nil ->
        {:error,
         "unknown emoji #{inspect(value)}; use one of: " <> Enum.join(Reactions.keys(), ", ")}

      key ->
        {:ok, key}
    end
  end

  defp not_own(ctx, message) do
    if message.agent_id == ctx.agent.id,
      do: {:error, "that is your own message; react to someone else's message"},
      else: :ok
  end

  # the reactor is always the calling session's agent, never a param
  defp react(message, ctx, key, remove?) do
    result =
      if remove?,
        do: Reactions.remove(message.id, {:agent, ctx.agent.id}, key),
        else: Reactions.add(message.id, {:agent, ctx.agent.id}, key)

    case result do
      {:ok, outcome} -> {:ok, outcome}
      {:error, :system_message} -> {:error, "that is a system note; only messages take reactions"}
      {:error, :archived} -> {:error, "the channel is archived; it takes no reactions"}
      {:error, :not_found} -> {:error, "unknown message #{message.id}"}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, Tool.changeset_reason(changeset)}
    end
  end

  defp reply(:added, entry, message),
    do:
      "Reacted #{entry.glyph} to #{whose(message)} message #{message.id}; nobody was woken. " <>
        "If that was all this message needed, call canopy_pass and end your turn."

  defp reply(:exists, entry, message),
    do:
      "You had already reacted #{entry.glyph} to #{whose(message)} message #{message.id}; nothing changed."

  defp reply(:removed, entry, message),
    do:
      "Removed your #{entry.glyph} from #{whose(message)} message #{message.id}; nobody was woken."

  defp reply(:absent, entry, message),
    do:
      "You had not reacted #{entry.glyph} to #{whose(message)} message #{message.id}; nothing changed."

  defp whose(message), do: Format.sender(message) <> "'s"
end
