defmodule Canopy.MCP.Tools.NotesWrite do
  @moduledoc """
  Update the team's shared notes for this repository (`.canopy/NOTES.md`,
  outside git). Every agent working here gets them in every prompt, so write
  what all of them need: conventions, how to run and test things, decisions
  that stuck, things that bit you. Keep them short and current, date entries
  with `## YYYY-MM-DD` headings. Append by default; replace the whole document
  to prune what is stale. What only you need goes in your memory instead.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Notes
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :text, {:required, :string},
      description: "Markdown to append, or the whole new notes when mode is replace."

    field :mode, :string,
      description: "\"append\" (default) adds a block; \"replace\" overwrites the whole notes."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      text = Tool.blank_to_nil(Map.get(params, :text))
      mode = Tool.blank_to_nil(Map.get(params, :mode)) || "append"

      cond do
        is_nil(text) and mode != "replace" ->
          {:error, "text is empty"}

        mode not in ["append", "replace"] ->
          {:error, "mode must be append or replace"}

        true ->
          result =
            if mode == "replace",
              do: Notes.put(ctx.repository.path, text || ""),
              else: Notes.append(ctx.repository.path, text)

          case result do
            {:ok, body} ->
              done = if mode == "replace", do: "replaced", else: "appended"
              {:ok, "notes #{done}; they are now #{byte_size(body)} bytes."}

            {:error, :too_large} ->
              {:error,
               "notes would exceed #{div(Notes.max_bytes(), 1024)} KB; replace them with a pruned version instead"}

            {:error, reason} ->
              {:error,
               "could not write #{Notes.shared_path(ctx.repository.path)}: #{inspect(reason)}"}
          end
      end
    end)
  end
end
