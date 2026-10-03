defmodule Canopy.MCP.Tools.MessagesRead do
  @moduledoc """
  Read messages. Without an anchor it returns what is new since you last read
  this channel (the latest ones on your first read), then the reactions added
  since then to older messages. Long bodies are shortened;
  `canopy_message_get` returns one in full. Reactions show after a message as
  `[reactions: ✅ check: Steven, @qa]`; they are acknowledgements, not
  instructions.

  Read channel messages, oldest first. Without options returns the latest
  messages. Use `around` to see the context of one message id, `before` to
  page further back, or `thread` to read one thread (the root and its latest
  replies) by any message id in it.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{Messages, Reactions}
  alias Canopy.MCP.{Format, Tool}

  @default_limit 10
  @max_limit 50

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :channel, :string, description: "Channel name or id. Defaults to your own channel."
    field :around, :string, description: "Message id; returns messages before and after it."
    field :before, :string, description: "Message id; returns the messages preceding it."

    field :thread, :string,
      description:
        "Any message id in a thread (the root or a reply); returns the root and the thread's latest replies."

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

        last_read = Messages.last_read(ctx.agent.id, channel.id)
        {messages, header} = fetch(channel, opts, last_read)
        # A thread read leaves the channel's read marker alone: its newest reply
        # can be newer than channel messages the agent has not read yet.
        unless Keyword.has_key?(opts, :thread), do: mark(ctx, channel, messages)
        lines = Format.message_lines(messages, truncate: @body_chars)

        case catching_up(ctx, channel, opts, messages, is_nil(last_read)) do
          [] ->
            {:ok, header <> "\n" <> lines}

          reactions when messages == [] ->
            {:ok,
             "##{channel.name}: no new messages since your last read; " <>
               "#{length(reactions)} new reaction(s) below.\n" <>
               reactions_trailer(ctx, reactions)}

          reactions ->
            {:ok, header <> "\n" <> lines <> "\n\n" <> reactions_trailer(ctx, reactions)}
        end
      end
    end)
  end

  # Only the no-anchor read catches up on reactions: the ones added since the
  # agent's reaction cursor, to messages it is not being shown now (those carry
  # them inline), minus its own. The first read in a channel only sets the
  # cursor; the messages it lists carry their reactions inline. Either way the
  # cursor moves to the channel's newest reaction.
  @reactions_listed 10

  defp catching_up(ctx, channel, opts, messages, first_read?) do
    anchored? = Enum.any?([:around, :before, :thread], &Keyword.has_key?(opts, &1))

    if anchored? do
      []
    else
      cursor = Messages.last_reaction_read(ctx.agent.id, channel.id)

      reactions =
        if first_read?,
          do: [],
          else:
            Reactions.since(channel.id, cursor,
              exclude_agent: ctx.agent.id,
              except_messages: Enum.map(messages, & &1.id),
              limit: @reactions_listed
            )

      Messages.mark_reactions_read(ctx.agent.id, channel.id, Reactions.newest_id(channel.id))

      # reactions to the reader's own messages first: those are the answers
      Enum.sort_by(reactions, &{&1.message.agent_id != ctx.agent.id, &1.id})
    end
  end

  defp reactions_trailer(ctx, reactions) do
    "Reactions since your last read:\n" <>
      Enum.map_join(reactions, "\n", &reaction_line(ctx, &1))
  end

  # `- Steven ✅ check on your [msg_…] "Ship it?" (12m ago)`
  defp reaction_line(ctx, reaction) do
    %{glyph: glyph} = Reactions.entry(reaction.emoji)
    message = reaction.message

    whose =
      if message.agent_id == ctx.agent.id,
        do: "your [#{message.id}]",
        else: "[#{message.id}] from #{Format.sender(message)}"

    excerpt = message.body |> Format.single_line() |> Format.truncate(60)

    "- #{Format.reactor(reaction)} #{glyph} #{reaction.emoji} on #{whose} \"#{excerpt}\" " <>
      "(#{Format.relative_time(reaction.inserted_at)})"
  end

  # With no anchor, reading means "what is new since I last read here"; the
  # first read in a channel returns the latest messages instead.
  defp fetch(channel, opts, last_read) do
    anchored? = Enum.any?([:around, :before, :thread], &Keyword.has_key?(opts, &1))

    cond do
      thread_id = Keyword.get(opts, :thread) ->
        thread(channel, thread_id, opts)

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

  defp thread(channel, thread_id, opts) do
    case Messages.list(channel.id, opts) do
      [] ->
        {[], "##{channel.name}: no thread with message #{thread_id} here"}

      [root | replies] = messages ->
        total = get_in(Messages.thread_summaries([root.id]), [root.id, :count]) || 0

        shown =
          if length(replies) < total, do: ", showing the last #{length(replies)}", else: ""

        {messages,
         "thread [#{root.id}] in ##{channel.name}: #{count(total, "reply", "replies")}#{shown}, oldest first"}
    end
  end

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp mark(_ctx, _channel, []), do: :ok

  defp mark(ctx, channel, messages) do
    newest = messages |> Enum.map(& &1.id) |> Enum.max()
    Messages.mark_read(ctx.agent.id, channel.id, newest)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
