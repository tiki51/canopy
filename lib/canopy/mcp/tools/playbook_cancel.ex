defmodule Canopy.MCP.Tools.PlaybookCancel do
  @moduledoc "Cancel a playbook run: its coordinator or the channel owner can."

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks.Runs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :reason, {:required, :string},
      description: "Why, in a few words. Shown on the timeline."

    field :run, :string,
      description: "The run id (pbr_…). Defaults to the run in progress in your channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, run} <- PlaybookText.find_run(ctx, Tool.blank_to_nil(Map.get(params, :run))),
           {:ok, run, :cancelled} <-
             Runs.cancel(run, {:agent, ctx.agent.id}, Map.get(params, :reason)) do
        {:ok, "cancelled #{run.playbook_name} [#{run.id}] in ##{run.channel.name}."}
      end
    end)
  end
end
