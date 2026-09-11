defmodule Canopy.MCP.Tools.MemoryWrite do
  @moduledoc """
  Update your memory across repositories. It is yours alone, follows you into
  every channel and repository, and rides along in every prompt. Keep it
  short and current: facts about codebases and people, decisions and why,
  things that bit you. Date entries with `## YYYY-MM-DD` headings. Append by
  default; replace the whole document to prune what is stale.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Memory
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :text, {:required, :string},
      description: "Markdown to append, or the whole new memory when mode is replace."

    field :mode, :string,
      description: "\"append\" (default) adds a block; \"replace\" overwrites the whole memory."
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
              do: Memory.put(ctx.agent.id, text || ""),
              else: Memory.append(ctx.agent.id, text)

          case result do
            {:ok, body} ->
              done = if mode == "replace", do: "replaced", else: "appended"
              {:ok, "memory #{done}; it is now #{byte_size(body)} bytes."}

            {:error, :too_large} ->
              {:error,
               "memory would exceed #{div(Memory.max_bytes(), 1024)} KB; replace it with a pruned version instead"}
          end
      end
    end)
  end
end
