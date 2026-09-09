defmodule Canopy.MCP.Tools.MessagesRead do
  @moduledoc """
  Read channel messages, oldest first. Without options returns the latest
  messages. Use `around` to see the context of one message id, `before` to
  page further back, or `thread` to read one thread by its root message id.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Messages
  alias Canopy.MCP.{Format, Tool}

  @default_limit 20
  @max_limit 50

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :around, :string, description: "Message id; returns messages before and after it."
    field :before, :string, description: "Message id; returns the messages preceding it."
    field :thread, :string, description: "Root message id; returns that message and its replies."
    field :limit, :integer, description: "Maximum messages to return (default 20, max 50)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, channel} <- Tool.resolve_channel(ctx, Map.get(params, :channel)) do
        limit = Tool.clamp_limit(Map.get(params, :limit), @default_limit, @max_limit)

        opts =
          [limit: limit]
          |> put_opt(:around, Tool.blank_to_nil(Map.get(params, :around)))
          |> put_opt(:before, Tool.blank_to_nil(Map.get(params, :before)))
          |> put_opt(:thread, Tool.blank_to_nil(Map.get(params, :thread)))

        messages = Messages.list(channel.id, opts)
        header = "##{channel.name}: #{length(messages)} message(s), oldest first"
        {:ok, header <> "\n" <> Format.message_lines(messages, [])}
      end
    end)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
