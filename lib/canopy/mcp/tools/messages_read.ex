defmodule Canopy.MCP.Tools.MessagesRead do
  @moduledoc """
  Read messages. Without an anchor it returns what is new since you last read
  this channel (the latest ones on your first read). Long bodies are shortened;
  `canopy_message_get` returns one in full.

  Read channel messages, oldest first. Without options returns the latest
  messages. Use `around` to see the context of one message id, `before` to
  page further back, or `thread` to read one thread by its root message id.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Messages
  alias Canopy.MCP.{Format, Tool}

  @default_limit 10
  @max_limit 50

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :around, :string, description: "Message id; returns messages before and after it."
    field :before, :string, description: "Message id; returns the messages preceding it."
    field :thread, :string, description: "Root message id; returns that message and its replies."
    field :limit, :integer, description: "Maximum messages to return (default 10, max 50)."
  end

  @body_chars 400

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

        {messages, header} = fetch(ctx, channel, opts)
        mark(ctx, channel, messages)
        {:ok, header <> "\n" <> Format.message_lines(messages, truncate: @body_chars)}
      end
    end)
  end

  # With no anchor, reading means "what is new since I last read here"; the
  # first read in a channel returns the latest messages instead.
  defp fetch(ctx, channel, opts) do
    anchored? = Enum.any?([:around, :before, :thread], &Keyword.has_key?(opts, &1))
    last_read = Messages.last_read(ctx.agent.id, channel.id)

    cond do
      anchored? ->
        messages = Messages.list(channel.id, opts)
        {messages, "##{channel.name}: #{length(messages)} message(s), oldest first"}

      is_nil(last_read) ->
        messages = Messages.list(channel.id, opts)

        {messages,
         "##{channel.name}: latest #{length(messages)} message(s), oldest first (first read here)"}

      true ->
        messages = Messages.list(channel.id, Keyword.put(opts, :after, last_read))

        header =
          case messages do
            [] ->
              "##{channel.name}: nothing new since your last read. Use before/around for history."

            list ->
              "##{channel.name}: #{length(list)} new message(s) since your last read, oldest first"
          end

        {messages, header}
    end
  end

  defp mark(_ctx, _channel, []), do: :ok

  defp mark(ctx, channel, messages) do
    newest = messages |> Enum.map(& &1.id) |> Enum.max()
    Messages.mark_read(ctx.agent.id, channel.id, newest)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
