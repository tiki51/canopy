defmodule Canopy.MCP.Tools.DocumentShare do
  @moduledoc """
  Publish a file so people and agents can download it and you can attach it
  to posts. Give `content` and `filename` for text you have in hand (a
  Markdown report), or `path` for a file inside the repository you already
  wrote (a screenshot, a CSV; keep such files under .canopy/out/). Returns the
  document id to pass as `attachments` on canopy_message_send.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Documents
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :path, :string,
      description: "Repository-relative path of a file to share, e.g. .canopy/out/report.md."

    field :content, :string,
      description: "Text to share as a new file (with filename). Use instead of path."

    field :filename, :string,
      description: "Name for the file when sharing content, e.g. retry-analysis.md."

    field :caption, :string, description: "One line saying what the file is (optional)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      path = Tool.blank_to_nil(Map.get(params, :path))
      content = Map.get(params, :content)
      filename = Tool.blank_to_nil(Map.get(params, :filename))
      caption = Tool.blank_to_nil(Map.get(params, :caption))

      base = %{agent_id: ctx.agent.id, origin_channel_id: ctx.channel.id, caption: caption}

      result =
        cond do
          path && is_binary(content) && content != "" ->
            {:error, "give either path or content, not both"}

          path ->
            Documents.create_from_repository(ctx.repository.path, path, base)

          is_binary(content) && content != "" && filename ->
            Documents.create(Map.merge(base, %{filename: filename, source: {:binary, content}}))

          is_binary(content) && content != "" ->
            {:error, "filename is required when sharing content"}

          true ->
            {:error, "give path (a file in the repository) or content with filename"}
        end

      case result do
        {:ok, document} ->
          {:ok, shared(document)}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, :too_large} ->
          {:error, "content is larger than #{Documents.size_label(Documents.max_bytes())}"}

        {:error, :unreadable} ->
          {:error, "the file cannot be read"}

        {:error, changeset} ->
          {:error, "could not share: " <> Tool.changeset_reason(changeset)}
      end
    end)
  end

  defp shared(document) do
    embed =
      if document.kind == "image",
        do:
          "; embed it in Markdown with ![#{document.filename}](#{Documents.url_path(document)})",
        else: ""

    "shared [#{document.id}] #{Format.document_ref(document) |> String.replace_prefix(document.id <> " ", "")}; attach it with attachments: \"#{document.id}\" on the message that asks about it, mentioning whoever should look#{embed}"
  end
end
