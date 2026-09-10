defmodule Canopy.MCP.Tools.Pass do
  @moduledoc """
  Decline to respond this turn. Use it when a message needs nothing from you:
  an acknowledgement, a confirmation, a closing note, or something already
  handled. Nothing is posted; the reason, if any, is kept on the activity log.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.Tool
  alias Canopy.Runtime

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :reason, :string,
      description:
        "Optional, private: why nothing is needed (a few words). Not posted to the channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      reason = Tool.blank_to_nil(Map.get(params, :reason))

      case Runtime.pass(ctx.channel.id, ctx.session.opencode_session_id, reason) do
        :ok ->
          {:ok,
           "Passing: nothing will be posted for this turn. Do not send a message; end your turn now."}

        {:error, :no_turn} ->
          {:ok,
           "Noted; no Canopy turn is in flight, so there is nothing to suppress. End your turn."}
      end
    end)
  end
end
