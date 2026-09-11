defmodule Canopy.MCP.Tools.DmSwitchRepository do
  @moduledoc """
  Move a direct message to another registered repository. The conversation
  stays; your session is recreated in the new repository when this turn ends,
  so finish what you are saying, then continue there on your next wake.
  Channels stay in their repository; DMs are where you move between them.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Runtime}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :repository, {:required, :string},
      description: "Repository name or id to work in from now on."

    field :channel, :string, description: "DM name or id. Defaults to your current channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           :ok <- dm_only(channel),
           {:ok, repository} <- Tool.resolve_repository(ctx, Map.get(params, :repository)) do
        if channel.repository_id == repository.id do
          {:ok, "##{channel.name} already works in #{repository.name} (#{repository.path})."}
        else
          {:ok, _} =
            Runtime.switch_dm_repository(channel.id, repository.id, "@" <> ctx.agent.name)

          {:ok,
           "##{channel.name} now works in #{repository.name} (#{repository.path}). " <>
             "Your session there starts on your next turn; finish this turn without touching files, then continue after the next message."}
        end
      end
    end)
  end

  defp dm_only(channel) do
    if Channels.dm?(channel),
      do: :ok,
      else:
        {:error,
         "##{channel.name} is a channel; channels stay in their repository. Start one there with canopy_channel_create."}
  end
end
