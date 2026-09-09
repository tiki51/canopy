defmodule Canopy.MCP.Tools.MessagesSearch do
  @moduledoc """
  Full-text search over a channel's messages. Words match whole tokens,
  "quoted phrases" match exactly, and a trailing * matches a prefix (retr*).
  Matches in snippets are wrapped in **.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Messages
  alias Canopy.MCP.{Format, Tool}

  @default_limit 20
  @max_limit 50

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :query, {:required, :string}, description: "Search terms."
    field :limit, :integer, description: "Maximum results (default 20, max 50)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)),
           {:ok, query} <- query(params) do
        limit = Tool.clamp_limit(Map.get(params, :limit), @default_limit, @max_limit)

        case Messages.search(channel.id, query, limit: limit) do
          [] ->
            {:ok, "No messages in ##{channel.name} match #{inspect(query)}."}

          hits ->
            lines =
              Enum.map_join(hits, "\n", fn %{message: message, snippet: snippet} ->
                "[#{message.id}] #{Format.sender(message)} (#{Format.relative_time(message.inserted_at)}): " <>
                  Format.single_line(snippet)
              end)

            {:ok,
             "#{length(hits)} match(es) in ##{channel.name} for #{inspect(query)}:\n" <> lines}
        end
      end
    end)
  end

  defp query(params) do
    case Tool.blank_to_nil(Map.get(params, :query)) do
      nil -> {:error, "query is empty"}
      query -> {:ok, query}
    end
  end
end
