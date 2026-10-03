defmodule Canopy.MCP.Tools.MessagesSearch do
  @moduledoc """
  Full-text search over a channel's messages. Words match whole tokens,
  "quoted phrases" match exactly, and a trailing * matches a prefix (retr*).
  Code and paths match as typed (enqueue_charge, lib/billing/worker.ex), but
  never inside a word. Matches in snippets are wrapped in **.

  channel="all" searches every channel of your repository you are a member
  of. include="turns,files" adds finished turns (what an agent ran, changed,
  and concluded) and shared files to the messages.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Channels, Documents, Messages, Search}
  alias Canopy.MCP.{Format, Tool}

  @default_limit 20
  @max_limit 50
  @includes %{"turns" => "turn", "turn" => "turn", "files" => "document", "file" => "document"}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :channel, :string,
      description:
        "Channel name or id, or \"all\" for every channel you are a member of. Defaults to your own channel."

    field :query, {:required, :string}, description: "Search terms."

    field :include, :string,
      description:
        "Also search, comma-separated: turns (what agents ran and changed), files (shared documents). Default: messages only."

    field :limit, :integer, description: "Maximum results (default 20, max 50)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, scope} <- scope(ctx, Map.get(params, :channel)),
           {:ok, query} <- query(params),
           {:ok, extra} <- include(Map.get(params, :include)) do
        limit = Tool.clamp_limit(Map.get(params, :limit), @default_limit, @max_limit)

        case {scope, extra} do
          {{:channel, channel}, []} -> {:ok, messages(channel, query, limit)}
          _ -> {:ok, everything(ctx, scope, query, ["message" | extra], limit)}
        end
      end
    end)
  end

  # Messages in one channel: the tool's original output.
  defp messages(channel, query, limit) do
    case Messages.search(channel.id, query, limit: limit) do
      [] ->
        "No messages in ##{channel.name} match #{inspect(query)}."

      hits ->
        lines =
          Enum.map_join(hits, "\n", fn %{message: message, snippet: snippet} ->
            "[#{message.id}] #{Format.sender(message)} (#{Format.relative_time(message.inserted_at)}): " <>
              Format.single_line(snippet)
          end)

        "#{length(hits)} match(es) in ##{channel.name} for #{inspect(query)}:\n" <> lines
    end
  end

  # Turns and files too, or every member channel: one ranked list.
  defp everything(ctx, scope, query, sources, limit) do
    {channel_ids, where} =
      case scope do
        {:channel, channel} -> {[channel.id], "in ##{channel.name}"}
        :all -> {Channels.member_channel_ids(ctx.repository.id, ctx.agent.id), "in your channels"}
      end

    %{results: results} =
      Search.search(query,
        sources: sources,
        channel_ids: channel_ids,
        include_archived: true,
        sort: :rank,
        limit: limit,
        min_chars: 1,
        marks: {"**", "**"},
        snippet: {-1, "...", 16}
      )

    case results do
      [] ->
        "Nothing #{where} matches #{inspect(query)}."

      results ->
        lines = Enum.map_join(results, "\n", &line(&1, scope == :all))
        "#{length(results)} match(es) #{where} for #{inspect(query)}:\n" <> lines
    end
  end

  defp line(%{source: "message", record: message} = result, all?) do
    "[#{message.id}] #{channel(result, all?)}#{Format.sender(message)} (#{Format.relative_time(message.inserted_at)}): " <>
      Format.single_line(result.snippet)
  end

  defp line(%{source: "turn", record: event} = result, all?) do
    "[#{event.id}] #{channel(result, all?)}turn by #{Format.agent_ref(result.agent || event.agent_id)} (#{Format.relative_time(event.inserted_at)}): " <>
      Format.single_line(result.snippet)
  end

  defp line(%{source: "document", record: document} = result, _all?) do
    "[#{document.id}] file #{document.filename} (#{document.kind}, #{Documents.size_label(document.byte_size)}) by #{uploader(result)} (#{Format.relative_time(document.inserted_at)}): " <>
      Format.single_line(result.snippet)
  end

  defp channel(%{channel: %{name: name}}, true), do: "##{name} "
  defp channel(_result, _all?), do: ""

  defp uploader(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp uploader(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp uploader(_result), do: "unknown"

  defp scope(ctx, value) when is_binary(value) do
    if value |> String.trim() |> String.trim_leading("#") |> String.downcase() == "all",
      do: {:ok, :all},
      else: channel_scope(ctx, value)
  end

  defp scope(ctx, value), do: channel_scope(ctx, value)

  defp channel_scope(ctx, value) do
    with {:ok, channel} <- Tool.resolve_channel(ctx, value), do: {:ok, {:channel, channel}}
  end

  defp include(value) do
    case Tool.blank_to_nil(value) do
      nil ->
        {:ok, []}

      value ->
        words = value |> String.downcase() |> String.split([",", " "], trim: true)

        case Enum.reject(words, &(Map.has_key?(@includes, &1) or &1 in ["messages", "message"])) do
          [] ->
            {:ok,
             words |> Enum.map(&Map.get(@includes, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()}

          [unknown | _] ->
            {:error, "unknown include #{inspect(unknown)}; use turns, files"}
        end
    end
  end

  defp query(params) do
    case Tool.blank_to_nil(Map.get(params, :query)) do
      nil -> {:error, "query is empty"}
      query -> {:ok, query}
    end
  end
end
