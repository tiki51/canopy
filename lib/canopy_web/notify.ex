defmodule CanopyWeb.Notify do
  @moduledoc """
  Desktop notifications, the server's half: which events are worth a
  notification and what it says. `CanopyWeb.Nav` classifies every timeline
  event it hears on `"timeline:all"` and every `{:channel_quiet, …}` from the
  runtime (`Canopy.Runtime.subscribe_activity/0`), and pushes a note to the
  page as `"canopy:notify"`. The browser decides the rest
  (`assets/js/notify.js`): whether notifications are on, the kinds, browser
  permission, whether the user is already looking, one tab of several,
  grouping and the rate limit. The server knows no preferences.

  A note is `%{id, kind, channel_id, place, tag, title, body, url}`:

    * `kind` — `"needs_you"` (a question or permission card, or a playbook
      step held for sign-off), `"mention"` (an agent mentioned the user, or
      wrote in a DM), or `"work"` (the channel went quiet after a run, or its
      task was completed);
    * `id` — the same in every tab, so tabs can agree on one note; a card's
      id is its tag, so a card raised again (reopened on replay) is not
      announced twice;
    * `tag` — the notification it replaces: one per card, one per channel for
      mentions and for work;
    * `place` — the channel as people read it (`#site-review`, `@pm`), for
      a grouped title ("3 new mentions in #site-review");
    * `body` — plain text, at most 140 characters;
    * `url` — where a click goes: the card (`#question-…`, `#permission-…`),
      the message (`?msg=…`, which opens a thread reply in its thread), the
      sign-off line, or the channel.

  Never: the user's own messages, system notes, reactions (not timeline
  events), replies in followed threads that do not mention the user,
  detached or resolved cards, archived channels, and runs that agents
  started among themselves.
  """

  alias Canopy.Channels
  alias Canopy.Channels.Channel
  alias Canopy.Timeline.Event

  @body_max 140

  # Runs started by agents among themselves (a message, a delegation, a
  # handoff, a lock passing) with no user action since: not news. A
  # schedule, a watch, or a playbook the user started is.
  @quiet_triggers ~w(agent delegation handoff lock other)

  @type note :: %{
          id: String.t(),
          kind: String.t(),
          channel_id: String.t(),
          place: String.t(),
          tag: String.t(),
          title: String.t(),
          body: String.t(),
          url: String.t()
        }

  @doc """
  The note for a timeline event or a `{:channel_quiet, channel_id, info}`
  signal, or nil. `ctx`: `:channel` (the event's channel, nil when unknown)
  and `:names` (agent id => name, for a quiet run's agents).
  """
  @spec classify(Event.t() | tuple, map) :: note | nil
  def classify(signal, %{channel: %Channel{} = channel} = ctx) do
    if Channels.archived?(channel), do: nil, else: note(signal, channel, ctx)
  end

  def classify(_signal, _ctx), do: nil

  defp note(%Event{event_type: "question_requested"} = event, channel, _ctx) do
    headers = event.payload |> Map.get("headers", []) |> List.wrap() |> Enum.reject(&blank?/1)

    card(event, channel, "question",
      title: "#{who(event)} needs you#{in_channel(channel)}",
      body:
        if(headers == [],
          do: "A question is waiting for your answer.",
          else: Enum.join(headers, " · ")
        )
    )
  end

  defp note(%Event{event_type: "permission_requested"} = event, channel, _ctx) do
    permission = Map.get(event.payload, "permission") || "a tool"
    patterns = event.payload |> Map.get("patterns", []) |> List.wrap() |> Enum.join(" ")

    card(event, channel, "permission",
      title: "#{who(event)} needs you#{in_channel(channel)}",
      body: String.trim("#{permission} permission: #{patterns}")
    )
  end

  defp note(%Event{event_type: "playbook_approval_requested"} = event, channel, _ctx) do
    p = event.payload
    step = Map.get(p, "title") || Map.get(p, "step") || "a step"
    result = Map.get(p, "result")

    %{
      id: "signoff:" <> event.id,
      kind: "needs_you",
      channel_id: channel.id,
      place: label(channel),
      tag: "signoff:" <> (Map.get(p, "run_id") || event.id),
      title:
        "#{Map.get(p, "playbook") || "A playbook"} needs your sign-off#{in_channel(channel)}",
      body: plain(if(blank?(result), do: "Step: #{step}", else: "#{step}: #{result}")),
      url: channel_path(channel) <> "#evt-" <> event.id
    }
  end

  defp note(
         %Event{event_type: "message", message: %{agent_id: agent_id} = message} = event,
         channel,
         _ctx
       )
       when is_binary(agent_id) do
    if message.kind != "system" and (message.mentions_user or channel.kind == "dm") do
      where =
        cond do
          channel.kind == "dm" and message.thread_id -> " in a thread"
          channel.kind == "dm" -> ""
          message.thread_id -> " in a thread in " <> label(channel)
          true -> " in " <> label(channel)
        end

      title =
        if channel.kind == "dm" and is_nil(message.thread_id),
          do: who(event),
          else:
            "#{who(event)} #{if(message.mentions_user, do: "mentioned you", else: "wrote")}#{where}"

      body = plain(message.body || "")

      %{
        id: event.id,
        kind: "mention",
        channel_id: channel.id,
        place: label(channel),
        tag: "mention:" <> channel.id,
        title: title,
        body: if(body == "", do: "Sent a file.", else: body),
        url: channel_path(channel) <> "?msg=" <> message.id
      }
    end
  end

  defp note(%Event{event_type: "task_updated", payload: p} = event, channel, _ctx) do
    if get_in(p, ["changes", "status"]) == "completed" do
      %{
        id: "task:" <> event.id,
        kind: "work",
        channel_id: channel.id,
        place: label(channel),
        tag: "work:" <> channel.id,
        title: "#{label(channel)} is done",
        body: plain("Task completed: #{Map.get(p, "title") || "the channel's task"}"),
        url: channel_path(channel)
      }
    end
  end

  defp note({:channel_quiet, _channel_id, %{trigger: trigger}}, _channel, _ctx)
       when trigger in @quiet_triggers,
       do: nil

  defp note({:channel_quiet, _channel_id, %{turns: turns} = info}, channel, ctx)
       when turns > 0 do
    names = Map.get(ctx, :names, %{})

    agents =
      info.agent_ids
      |> Enum.map(&Map.get(names, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(", ", &("@" <> &1))

    stats = "#{turns} #{if turns == 1, do: "turn", else: "turns"} · #{duration(info.duration_ms)}"

    {title, outcome} =
      cond do
        info.paused? -> {"#{label(channel)} paused", "paused after #{turns} agent turns"}
        info.errors > 0 -> {"#{label(channel)} is done", "stopped with an error"}
        true -> {"#{label(channel)} is done", nil}
      end

    body = [agents, outcome || stats] |> Enum.reject(&(&1 == "")) |> Enum.join(" · ")

    %{
      id: "work:" <> info.run_id,
      kind: "work",
      channel_id: channel.id,
      place: label(channel),
      tag: "work:" <> channel.id,
      title: title,
      body: plain(body),
      url: channel_path(channel)
    }
  end

  defp note(_signal, _channel, _ctx), do: nil

  defp card(event, channel, kind, title: title, body: body) do
    %{
      id: "card:" <> event.ref_id,
      kind: "needs_you",
      channel_id: channel.id,
      place: label(channel),
      tag: "card:" <> event.ref_id,
      title: title,
      body: plain(body),
      url: channel_path(channel) <> "##{kind}-" <> event.ref_id
    }
  end

  defp who(%Event{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp who(_event), do: "An agent"

  defp in_channel(%Channel{kind: "dm"}), do: ""
  defp in_channel(channel), do: " in " <> label(channel)

  defp label(%Channel{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp label(channel), do: "#" <> channel.name

  defp channel_path(channel), do: "/channels/" <> channel.id

  @doc """
  Markdown as one line of plain text, at most #{@body_max} characters: code
  fences, emphasis, links and list markers are stripped, whitespace collapsed.
  """
  def plain(text) when is_binary(text) do
    text
    |> String.replace(~r/```[^\n]*\n?/, "")
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/^\s{0,3}(?:[#>]+|[-*+]|\d+[.)])\s+/m, "")
    |> String.replace(~r/(\*\*|__|~~|`)/, "")
    |> String.replace(~r/(?<![\w*])\*(?!\s)([^*\n]+?)\*(?![\w*])/, "\\1")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) > @body_max,
      do: String.slice(text, 0, @body_max - 1) |> String.trim_trailing() |> Kernel.<>("…"),
      else: text
  end

  defp duration(ms) when is_integer(ms) and ms >= 3_600_000,
    do: "#{div(ms, 3_600_000)} h #{div(rem(ms, 3_600_000), 60_000)} m"

  defp duration(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)} m"
  defp duration(ms) when is_integer(ms), do: "#{max(div(ms, 1000), 1)} s"
  defp duration(_ms), do: "a moment"

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
