defmodule Canopy.MCP.Tools.PlaybookGet do
  @moduledoc """
  Read a playbook or a run. With `name`: the playbook's full text. Otherwise
  a run (`run`, or the one in progress in your channel): its roster, every
  step with status, round, result, and delegations, and the current step's
  instructions. Canopy keeps a run's state; read it here rather than relying
  on memory.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :name, :string, description: "A playbook's name: returns its full text."

    field :run, :string,
      description: "A run id (pbr_…). Defaults to the run in progress in your channel."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      case Tool.blank_to_nil(Map.get(params, :name)) do
        nil ->
          with {:ok, run} <- PlaybookText.find_run(ctx, Tool.blank_to_nil(Map.get(params, :run))) do
            {:ok, PlaybookText.run_block(run)}
          end

        name ->
          case Playbooks.get_by_name(name) do
            nil ->
              {:error, "no playbook named #{name}; canopy_playbooks_list shows them"}

            playbook ->
              state =
                if playbook.enabled,
                  do: "",
                  else: " (disabled: it cannot be started until the user enables it)"

              {:ok, "Playbook #{playbook.name}#{state}:\n\n" <> playbook.body}
          end
      end
    end)
  end
end
