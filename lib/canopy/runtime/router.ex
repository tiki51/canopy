defmodule Canopy.Runtime.Router do
  @moduledoc """
  Pure decisions about which agents a timeline event should wake, and with what
  prompt. Keeping this out of the GenServer makes the routing rules unit-testable.

  Returns a list of `{target, text}` where target is `{:root, agent_id}`: the
  agent's one engine session in the channel.
  """

  alias Canopy.Runtime.Prompts
  alias Canopy.Timeline.Event

  @doc """
  `ctx` carries `channel`, `members` (agent ids), `owner_agent_id`, a `lookup`
  function `agent_id -> %Agent{} | nil` for display names, `thread_root`
  (`message_id -> message | nil`), optionally `thread_last_agent`
  (`(root_id, opts) -> agent_id | nil`, see `Canopy.Messages.thread_last_agent/2`:
  the agent that replied last in a thread before a message, among the members,
  leaving the sender out), and optionally `teams` (names of the teams
  the channel holds whole, for the wake prompt). Targets without an agent (for
  example the previous owner of a user-initiated handoff) are dropped.

  Threads: an unaddressed reply goes to the other side of the thread: the
  agent (in the channel, not the sender) that replied last in the thread
  before it, else the root's author when that is another agent in the
  channel. When there is none, a user's reply falls back to the usual
  listener (the owner; every agent in a DM) and an agent's wakes nobody,
  never the owner: a thread is a side conversation, and the owner can read
  it. Mentions always win.
  """
  def wakeups(event, ctx) do
    event
    |> do_wakeups(ctx)
    |> Enum.reject(fn {{_kind, id}, _text} -> is_nil(id) end)
  end

  # Notes left by user commands never wake anyone; the command's own event does.
  defp do_wakeups(%Event{event_type: "message", message: %{kind: "system"}}, _ctx), do: []

  defp do_wakeups(%Event{event_type: "message", message: message}, ctx)
       when not is_nil(message) do
    sender_agent_id = message.agent_id
    sender = sender_name(message, ctx)

    targets =
      message.mentions
      |> Enum.reject(&(&1 == sender_agent_id))
      |> Enum.filter(&(&1 in ctx.members))

    # An unaddressed reply in a thread goes to the thread's other side (the
    # agent that replied last before it, else the agent that started it),
    # even in a DM. Outside a thread, or with nobody on the other side, an
    # unaddressed user message wakes the owner, or every agent in a DM, where
    # the user is talking to everyone. An unaddressed post from an agent
    # reaches the owner, who is responsible for the task, unless the owner
    # wrote it; an agent's thread reply never does.
    threaded? = not is_nil(message.thread_id)

    counterpart =
      if targets == [] and threaded? and message.kind != "reply",
        do: thread_counterpart(message, ctx, sender_agent_id),
        else: []

    targets =
      cond do
        targets != [] ->
          targets

        counterpart != [] ->
          counterpart

        is_nil(sender_agent_id) and dm?(ctx) ->
          ctx.members

        is_nil(sender_agent_id) ->
          List.wrap(ctx.owner_agent_id)

        # The "reply" kind is the turn's final text that Canopy captures on its
        # own: narration, not a question. It wakes only who it mentions, or
        # acknowledgements would bounce between agents forever.
        message.kind == "reply" ->
          []

        threaded? ->
          []

        true ->
          owner_fallback(ctx, sender_agent_id)
      end

    attachments = message |> documents_of() |> Canopy.Documents.prompt_plan()

    args = %{
      channel: ctx.channel.name,
      sender: sender,
      message_id: message.id,
      thread?: threaded?,
      thread: thread_info(message, ctx),
      members: member_names(ctx),
      teams: Map.get(ctx, :teams, []),
      body: Map.get(message, :body),
      attachments: attachments
    }

    text = Prompts.new_message(args)

    # With attachments the wake carries the plan too, so the channel server
    # can add the file parts the text promises. A thread message's wake also
    # carries the same prompt without the thread's instructions: a wake
    # merged with one from elsewhere starts a channel turn and uses it.
    wake =
      case {attachments, threaded?} do
        {[], false} ->
          text

        {_, false} ->
          %{text: text, attachments: attachments}

        {_, true} ->
          %{
            text: text,
            channel_text: Prompts.new_message(%{args | thread?: false, thread: nil}),
            attachments: attachments
          }
      end

    charges = team_charges(message)

    targets
    |> Enum.uniq()
    |> Enum.map(fn target ->
      case Map.get(charges, target) do
        nil -> {{:root, target}, wake}
        charge -> {{:root, target}, put_charge(wake, charge)}
      end
    end)
  end

  # Whoever delegated, the delegate does the work in its own session.
  defp do_wakeups(%Event{event_type: "delegation_created", payload: p} = ev, ctx) do
    [
      {{:root, p["to_agent_id"]},
       Prompts.delegation(%{
         channel: ctx.channel.name,
         from: name(ctx, p["from_agent_id"]),
         delegation_id: ev.ref_id,
         task: p["description"]
       })}
    ]
  end

  defp do_wakeups(%Event{event_type: type, payload: p} = ev, ctx)
       when type in ["delegation_completed", "delegation_failed"] do
    [
      {{:root, p["from_agent_id"]},
       Prompts.delegation_completed(%{
         channel: ctx.channel.name,
         to: name(ctx, p["to_agent_id"]),
         delegation_id: ev.ref_id,
         result: p["result"],
         status: if(type == "delegation_completed", do: "completed", else: "marked failed")
       })}
    ]
  end

  defp do_wakeups(%Event{event_type: "handoff_requested", payload: p} = ev, ctx) do
    [
      {{:root, p["to_agent_id"]},
       Prompts.handoff(%{
         channel: ctx.channel.name,
         from: name(ctx, p["from_agent_id"]),
         handoff_id: ev.ref_id
       })}
    ]
  end

  defp do_wakeups(%Event{event_type: "handoff_accepted", payload: p} = ev, ctx) do
    [
      {{:root, p["from_agent_id"]},
       Prompts.handoff_accepted(%{
         channel: ctx.channel.name,
         to: name(ctx, p["to_agent_id"]),
         handoff_id: ev.ref_id
       })}
    ]
  end

  defp do_wakeups(%Event{event_type: "handoff_rejected", payload: p} = ev, ctx) do
    [
      {{:root, p["from_agent_id"]},
       Prompts.handoff_rejected(%{
         channel: ctx.channel.name,
         to: name(ctx, p["to_agent_id"]),
         handoff_id: ev.ref_id,
         reason: p["reason"] || p["rejection_reason"]
       })}
    ]
  end

  defp do_wakeups(_event, _ctx), do: []

  # A team mention costs one turn of the chatter budget however many members
  # it wakes: every wake it alone caused carries the same charge key, and the
  # channel server counts a key once. Agents also named directly carry none,
  # so they are charged on their own.
  defp team_charges(message) do
    for %{"team_id" => team_id, "agent_ids" => ids} <- Map.get(message, :team_mentions) || [],
        id <- ids,
        into: %{},
        do: {id, {message.id, team_id}}
  end

  defp put_charge(text, charge) when is_binary(text), do: %{text: text, charge: charge}
  defp put_charge(%{} = wake, charge), do: Map.put(wake, :charge, charge)

  defp documents_of(message) do
    case Map.get(message, :documents) do
      docs when is_list(docs) -> docs
      _ -> []
    end
  end

  # Who an unaddressed reply in a thread is addressed to: the agent in the
  # channel, other than the sender, that replied last before it; else the
  # root's author when that is another agent in the channel.
  defp thread_counterpart(%{thread_id: root_id, id: message_id}, ctx, sender_agent_id) do
    lookup = Map.get(ctx, :thread_last_agent, fn _root, _opts -> nil end)

    case lookup.(root_id, except: sender_agent_id, before: message_id, among: ctx.members) do
      agent_id when is_binary(agent_id) -> [agent_id]
      _ -> thread_root_author(root_id, ctx, sender_agent_id)
    end
  end

  defp thread_root_author(root_id, ctx, sender_agent_id) do
    case ctx.thread_root.(root_id) do
      %{agent_id: author} when is_binary(author) and author != sender_agent_id ->
        if author in ctx.members, do: [author], else: []

      _ ->
        []
    end
  end

  # The wake prompt names the thread's root and quotes the start of it.
  defp thread_info(%{thread_id: nil}, _ctx), do: nil

  defp thread_info(%{thread_id: root_id}, ctx) do
    case ctx.thread_root.(root_id) do
      %{body: body} = root ->
        %{id: root_id, sender: sender_name(root, ctx), excerpt: body}

      _ ->
        %{id: root_id, sender: nil, excerpt: nil}
    end
  end

  defp dm?(%{channel: channel}), do: Map.get(channel, :kind) == "dm"

  defp owner_fallback(%{owner_agent_id: owner, members: members}, sender)
       when is_binary(owner) and owner != sender do
    if owner in members, do: [owner], else: []
  end

  defp owner_fallback(_ctx, _sender), do: []

  defp member_names(ctx) do
    ctx.members
    |> Enum.map(&ctx.lookup.(&1))
    |> Enum.flat_map(fn
      %{name: n} -> [n]
      _ -> []
    end)
  end

  defp sender_name(%{agent_id: nil, user: %{display_name: n}}, _ctx) when is_binary(n), do: n
  defp sender_name(%{agent_id: nil}, ctx), do: ctx.user_name
  defp sender_name(%{agent_id: id}, ctx), do: name(ctx, id)

  # A nil agent id means the user did it (user-initiated handoff or delegation).
  defp name(ctx, nil), do: ctx.user_name

  defp name(ctx, agent_id) do
    case ctx.lookup.(agent_id) do
      %{name: n} -> "@" <> n
      _ -> "an agent"
    end
  end
end
