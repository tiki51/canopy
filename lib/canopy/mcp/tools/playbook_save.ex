defmodule Canopy.MCP.Tools.PlaybookSave do
  @moduledoc """
  Draft a playbook for the user: Markdown with YAML frontmatter (name,
  description, steps with id/title/owner, roles or team), then guidance and
  a `## <step id>` section per step. It is saved disabled: an enabled
  playbook instructs every agent, so the user reviews and enables it on the
  Playbooks page. Saving again replaces your draft while it is still disabled.
  canopy_playbook_get with a name shows an existing playbook to copy from.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.Tool
  alias Canopy.Playbooks

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :text, {:required, :string},
      description: "The whole playbook: frontmatter between --- lines, then the body."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      case Tool.blank_to_nil(Map.get(params, :text)) do
        nil ->
          {:error, "text is empty"}

        text ->
          case Playbooks.save_draft(ctx.agent, text) do
            {:ok, playbook} ->
              {:ok,
               "saved #{playbook.name} as a disabled draft. Tell the user it is ready to review on the Playbooks page; it cannot be started until they enable it."}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:error, "could not save: " <> Tool.changeset_reason(changeset)}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end)
  end
end
