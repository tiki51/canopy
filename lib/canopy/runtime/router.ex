defmodule Canopy.Runtime.Router do
  @moduledoc """
  Pure decisions about which agents a timeline event should wake, and with what
  prompt. Keeping this out of the GenServer makes the routing rules unit-testable.

  Returns a list of `{target, text}` where target is `{:root, agent_id}` or
  `{:child, delegation}` (a delegate working in a child session).
  """

  alias Canopy.Runtime.Prompts
  alias Canopy.Timeline.Event

  @doc """
  `ctx` carries `channel`, `members` (agent ids), `owner_agent_id`, a `lookup`
  function `agent_id -> %Agent{} | nil` for display names, and `thread_root`
  (`message_id -> message | nil`). Targets without an agent (for example the
  previous owner of a user-initiated handoff) are dropped.
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

    # In a DM the user is talking to everyone in it, so an unaddressed user
    # message wakes all agents rather than just the owner.
    # An unaddressed post from an agent reaches the owner, who is responsible
    # for the task, unless the owner wrote it. Thread replies still go to the
    # thread's author first.
    targets =
      cond do
        targets != [] ->
          targets

        is_nil(sender_agent_id) and dm?(ctx) ->
          ctx.members

        is_nil(sender_agent_id) and ctx.owner_agent_id ->
          [ctx.owner_agent_id]

        # The "reply" kind is the turn's final text that Canopy captures on its
        # own: narration, not a question. It wakes only who it mentions, or
        # acknowledgements would bounce between agents forever.
        message.kind == "reply" ->
          []

        true ->
          thread_root_author(message, ctx, sender_agent_id) ++
            owner_fallback(ctx, sender_agent_id)
      end

    text =
      Prompts.new_message(%{
        channel: ctx.channel.name,
        sender: sender,
        message_id: message.id,
        thread?: not is_nil(message.thread_id),
        members: member_names(ctx),
        body: Map.get(message, :body)
      })

    Enum.map(Enum.uniq(targets), &{{:root, &1}, text})
  end

  defp do_wakeups(%Event{event_type: "delegation_created", payload: p} = ev, ctx) do
    # A delegation from an agent runs in a child session under the delegator; one
    # from the user (no delegator) runs in the delegate's own root session.
    target = if p["from_agent_id"], do: {:child, ev.ref_id}, else: {:root, p["to_agent_id"]}

    [
      {target,
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

  defp thread_root_author(%{thread_id: nil}, _ctx, _sender), do: []

  defp thread_root_author(%{thread_id: thread_id}, ctx, sender_agent_id) do
    case ctx.thread_root.(thread_id) do
      %{agent_id: author} when is_binary(author) and author != sender_agent_id -> [author]
      _ -> []
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
