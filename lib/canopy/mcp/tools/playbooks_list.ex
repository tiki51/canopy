defmodule Canopy.MCP.Tools.PlaybooksList do
  @moduledoc """
  List the enabled playbooks: reusable processes you can run with
  canopy_playbook_start. Each shows its roles and steps. Also says which run
  is in progress in your channel, if any.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks
  alias Canopy.Playbooks.Runs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      list =
        case Playbooks.list(enabled: true) do
          [] ->
            "No playbooks are enabled yet."

          playbooks ->
            "Playbooks:\n" <> Enum.map_join(playbooks, "\n", &PlaybookText.playbook_line/1)
        end

      active =
        case Runs.active_for_channel(ctx.channel.id) do
          nil ->
            ""

          run ->
            "\n\nIn progress in ##{ctx.channel.name}: #{run.playbook_name} [#{run.id}], step #{run.current_step}; canopy_playbook_get shows it."
        end

      {:ok, list <> active}
    end)
  end
end
