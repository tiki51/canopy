defmodule Canopy.MCP.Tools.DocumentGet do
  @moduledoc """
  Read one shared file by id (doc_…). Text comes back as text, in windows for
  long files; images come back as an image you can see. Every file is also
  copied into .canopy/files/ in your repository, so your own read tool works
  on it too; the reply tells you the path.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Documents
  alias Canopy.MCP.{Format, Tool}

  @default_chars 8_000
  @max_chars 20_000
  @max_image_bytes 5 * 1024 * 1024

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :document, {:required, :string}, description: "The document id (doc_…)."

    field :offset, :integer, description: "For text: the character to start from (default 0)."

    field :length, :integer,
      description: "For text: how many characters to return (default 8000, max 20000)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, document} <- find(Map.get(params, :document)) do
        path = materialise(document, ctx.repository.path)
        header = header(document, path)

        case document.kind do
          "text" ->
            text(document, header, params)

          "image" ->
            image(document, header)

          _ ->
            {:ok,
             header <>
               "\nThis kind of file is not readable here; open it at the path above with your own tools."}
        end
      end
    end)
  end

  defp find(id) do
    case Tool.blank_to_nil(id) && Documents.get(id) do
      %Documents.Document{} = document -> {:ok, document}
      _ -> {:error, "unknown document #{inspect(id)}"}
    end
  end

  defp materialise(document, repository_path) do
    case Documents.materialize(document, repository_path) do
      {:ok, _} -> Documents.materialized_relative_path(document)
      {:error, _} -> nil
    end
  end

  defp header(document, path) do
    [
      Format.document_ref(document) <>
        " shared by #{sharer(document)} #{Format.relative_time(document.inserted_at)}",
      path && "Path in this repository: #{path}",
      "URL for Markdown: #{Documents.url_path(document)}" <>
        if(document.kind == "image",
          do: " (embed with ![#{document.filename}](#{Documents.url_path(document)}))",
          else: ""
        ),
      document.caption && "Caption: #{document.caption}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp text(document, header, params) do
    offset = max(Map.get(params, :offset) || 0, 0)
    length = Tool.clamp_limit(Map.get(params, :length), @default_chars, @max_chars)

    case Documents.read_text(document, offset, length) do
      {:ok, window, total} ->
        shown_to = min(offset + length, total)

        trailer =
          if shown_to < total,
            do: "\n\n… (#{total - shown_to} more chars; call again with offset=#{shown_to})",
            else: ""

        range =
          if offset > 0 or shown_to < total,
            do: " (chars #{offset}..#{shown_to} of #{total})",
            else: ""

        {:ok, header <> "\nContent#{range}:\n" <> window <> trailer}

      {:error, reason} ->
        {:error, "could not read #{document.id}: #{inspect(reason)}"}
    end
  end

  defp image(%{byte_size: size} = document, header) when size <= @max_image_bytes do
    case Documents.read(document) do
      {:ok, bytes} -> {:ok, header, {:image, Base.encode64(bytes), document.mime}}
      {:error, reason} -> {:error, "could not read #{document.id}: #{inspect(reason)}"}
    end
  end

  defp image(_document, header),
    do: {:ok, header <> "\nThe image is too large to return here; read it at the path above."}

  defp sharer(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp sharer(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp sharer(_), do: "unknown"
end
