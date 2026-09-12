defmodule Canopy.MCP.Tools.DocumentsList do
  @moduledoc """
  Find files shared in Canopy: screenshots and documents people or agents
  attached to messages in any channel or DM. Returns ids you can read with
  canopy_document_get or attach to your own posts.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Documents
  alias Canopy.MCP.{Format, Tool}

  @default_limit 20
  @max_limit 100

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :search, :string, description: "Part of a filename to match."

    field :channel, :string,
      description: "Only files posted in this channel (name or id). Omit for every chat."

    field :kind, :string, description: "image, text, pdf, or other."
    field :limit, :integer, description: "Maximum files to return (default 20, max 100)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel_id} <- channel_filter(ctx, Tool.blank_to_nil(Map.get(params, :channel))),
           {:ok, kind} <- kind_filter(Tool.blank_to_nil(Map.get(params, :kind))) do
        limit = Tool.clamp_limit(Map.get(params, :limit), @default_limit, @max_limit)

        documents =
          Documents.list(
            search: Tool.blank_to_nil(Map.get(params, :search)),
            channel: channel_id,
            kind: kind,
            limit: limit
          )

        {:ok, render(documents)}
      end
    end)
  end

  defp channel_filter(_ctx, nil), do: {:ok, nil}

  defp channel_filter(ctx, value) do
    with {:ok, channel} <- Tool.resolve_channel(ctx, value), do: {:ok, channel.id}
  end

  defp kind_filter(nil), do: {:ok, nil}

  defp kind_filter(kind) do
    if kind in Documents.Document.kinds(),
      do: {:ok, kind},
      else: {:error, "kind must be one of image, text, pdf, other"}
  end

  defp render([]), do: "(no files shared yet)"

  defp render(documents) do
    "#{length(documents)} file(s), newest first:\n" <>
      Enum.map_join(documents, "\n", fn document ->
        channels =
          document
          |> Documents.usages()
          |> Enum.map(& &1.channel)
          |> Enum.uniq_by(& &1.id)
          |> Enum.map_join(", ", &channel_label/1)

        where = if channels == "", do: "not posted anywhere", else: "in " <> channels

        "[#{document.id}] #{document.filename} (#{document.kind}, #{Documents.size_label(document.byte_size)}) by #{sharer(document)}, #{Format.relative_time(document.inserted_at)}, #{where}"
      end)
  end

  defp channel_label(%{kind: "dm"} = channel), do: Canopy.Channels.dm_label(channel)
  defp channel_label(channel), do: "#" <> channel.name

  defp sharer(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp sharer(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp sharer(_), do: "unknown"
end
