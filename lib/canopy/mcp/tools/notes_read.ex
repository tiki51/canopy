defmodule Canopy.MCP.Tools.NotesRead do
  @moduledoc """
  Read the team's shared notes for this repository in full (`.canopy/NOTES.md`).
  The first part of them is already in your system prompt; call this when it
  says the notes continue.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Notes
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      case Notes.get(ctx.repository.path) do
        "" ->
          {:ok,
           "The shared notes for this repository are empty. Add to them with canopy_notes_write."}

        body ->
          {:ok, body}
      end
    end)
  end
end
