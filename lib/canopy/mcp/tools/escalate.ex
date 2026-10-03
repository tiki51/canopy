defmodule Canopy.MCP.Tools.Escalate do
  @moduledoc """
  Ask for your main model (model routing, experimental). On a wake Canopy ran
  on your light model, when it needs real work (editing files, running
  commands, investigating, a substantive reply): call this and end your turn;
  Canopy runs the same wake again on your main model. On your main model it
  changes nothing.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.Tool
  alias Canopy.Runtime

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :reason, :string,
      description: "Optional, private: why this wake needs your main model (a few words)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      reason = Tool.blank_to_nil(Map.get(params, :reason))

      case Runtime.escalate(ctx.channel.id, ctx.session.engine_session_id, reason) do
        {:ok, :escalating} ->
          {:ok,
           "Escalating: end your turn now, without posting anything; Canopy continues this wake on your main model."}

        {:ok, :main} ->
          {:ok, "You are already on your main model; continue the work."}

        {:error, :no_turn} ->
          {:ok,
           "Noted; no Canopy turn is in flight, so there is nothing to escalate. End your turn."}
      end
    end)
  end
end
