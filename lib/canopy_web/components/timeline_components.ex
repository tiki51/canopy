defmodule CanopyWeb.TimelineComponents do
  @moduledoc """
  Function components for the channel feed: messages (with nested thread
  replies), collaboration events rendered as centred system lines, the live
  telemetry card of a working agent, permission cards, and handoff banners.

  Every component that names an agent takes a `names` map (`agent_id => name`)
  and the local user's display name, so events with a nil agent read naturally
  ("Steven handed this task to @database").
  """

  use CanopyWeb, :html

  @fence_regex ~r/(```[^\n]*\n[\s\S]*?```)/
  @mention_regex ~r/((?<![\w@])@[a-z0-9][a-z0-9_-]*)/i

  # -- Timeline items ----------------------------------------------------------

  @doc "Renders one timeline event by its type."
  attr :id, :string, required: true
  attr :event, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :replies, :list, default: []

  def timeline_item(%{event: %{event_type: "message"}} = assigns) do
    ~H"""
    <div id={@id}>
      <.message_item
        message={@event.message}
        names={@names}
        user_name={@user_name}
        replies={@replies}
        inline_reply={not is_nil(@event.message.thread_id)}
      />
    </div>
    """
  end

  def timeline_item(assigns) do
    ~H"""
    <div id={@id}>
      <.system_line
        id={"line-#{@event.id}"}
        icon={event_icon(@event.event_type)}
        tone={event_tone(@event)}
        at={@event.inserted_at}
      >
        {event_text(@event, @names, @user_name)}
      </.system_line>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :replies, :list, default: []
  attr :inline_reply, :boolean, default: false

  def message_item(%{message: %{kind: "system"}} = assigns) do
    ~H"""
    <.system_line
      id={"message-#{@message.id}"}
      icon="hero-command-line-mini"
      tone="muted"
      at={@message.inserted_at}
    >
      <span class="font-medium">{sender_name(@message, @user_name)}</span>
      <.message_text body={@message.body} inline />
    </.system_line>
    """
  end

  def message_item(assigns) do
    ~H"""
    <article
      id={"message-#{@message.id}"}
      class={[
        "group flex gap-3 px-6 py-2 transition-colors hover:bg-base-200/50",
        @message.kind == "reply" && "message-reply"
      ]}
      data-kind={@message.kind}
    >
      <.avatar message={@message} user_name={@user_name} />
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class={[
            "text-sm font-semibold",
            @message.kind == "reply" && "text-base-content/60"
          ]}>
            {sender_name(@message, @user_name)}
          </span>
          <span
            :if={@message.kind == "reply"}
            class="rounded-full bg-base-300/70 px-1.5 text-[10px] font-medium uppercase tracking-wide text-base-content/50"
            title="The agent's final turn text"
          >
            reply
          </span>
          <span
            :if={@inline_reply}
            class="text-[11px] text-base-content/50"
            title="A reply in a thread that is not loaded"
          >
            in a thread
          </span>
          <time
            class="text-[11px] text-base-content/40"
            title={DateTime.to_iso8601(@message.inserted_at)}
          >
            {short_time(@message.inserted_at)}
          </time>
        </div>
        <div class={[
          "mt-0.5 text-sm leading-relaxed",
          @message.kind == "reply" && "text-base-content/80"
        ]}>
          <.message_text body={@message.body} />
        </div>

        <div :if={@replies != []} class="mt-1.5">
          <button
            type="button"
            id={"thread-toggle-#{@message.id}"}
            class="flex items-center gap-1 text-xs font-medium text-primary transition hover:underline"
            phx-click={JS.toggle(to: "#thread-#{@message.id}")}
          >
            <.icon name="hero-chat-bubble-left-right-mini" class="size-3.5" />
            {ngettext("1 reply", "%{count} replies", length(@replies))}
          </button>
          <div id={"thread-#{@message.id}"} class="mt-2 hidden border-l-2 border-base-300 pl-3">
            <div :for={reply <- @replies} class="-mx-6">
              <.message_item message={reply} names={@names} user_name={@user_name} />
            </div>
          </div>
        </div>
      </div>
    </article>
    """
  end

  attr :message, :map, required: true
  attr :user_name, :string, required: true

  defp avatar(assigns) do
    ~H"""
    <div
      class={[
        "mt-0.5 flex size-8 shrink-0 select-none items-center justify-center rounded-lg text-xs font-bold",
        @message.agent_id && "bg-primary/15 text-primary",
        is_nil(@message.agent_id) && "bg-neutral text-neutral-content"
      ]}
      style={
        @message.agent && @message.agent.color &&
          "background-color: #{@message.agent.color}; color: white"
      }
      aria-hidden="true"
    >
      {initial(sender_name(@message, @user_name))}
    </div>
    """
  end

  @doc """
  Renders a message body: whitespace preserved, fenced code blocks as
  monospace blocks, and `@mentions` highlighted.
  """
  attr :body, :string, required: true
  attr :inline, :boolean, default: false

  def message_text(assigns) do
    assigns = assign(assigns, :segments, body_segments(assigns.body))

    ~H"""
    <span :if={@inline} class="whitespace-pre-wrap break-words">
      <%= for segment <- @segments do %>
        <.text_segment segment={segment} />
      <% end %>
    </span>
    <div :if={!@inline} class="flex flex-col gap-1.5">
      <%= for segment <- @segments do %>
        <%= case segment do %>
          <% {:code, lang, code} -> %>
            <pre
              class="overflow-x-auto rounded-md bg-base-300/60 px-3 py-2 font-mono text-xs leading-relaxed"
              data-lang={lang}
            ><code>{code}</code></pre>
          <% {:text, _} = text -> %>
            <p class="whitespace-pre-wrap break-words">
              <.text_segment segment={text} />
            </p>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :segment, :any, required: true

  defp text_segment(%{segment: {:text, parts}} = assigns) do
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <%= for part <- @parts do %>
      <%= case part do %>
        <% {:mention, name} -> %>
          <span class="rounded bg-primary/10 px-1 font-medium text-primary">{name}</span>
        <% {:plain, text} -> %>
          {text}
      <% end %>
    <% end %>
    """
  end

  defp text_segment(%{segment: {:code, _lang, code}} = assigns) do
    assigns = assign(assigns, :code, code)

    ~H"""
    <code class="rounded bg-base-300/60 px-1 font-mono text-xs">{@code}</code>
    """
  end

  @doc "A centred, subtle line for collaboration events and system notes."
  attr :id, :string, required: true
  attr :icon, :string, default: "hero-information-circle-mini"
  attr :tone, :string, default: "muted", values: ~w(muted success error warning)
  attr :at, :any, default: nil
  slot :inner_block, required: true

  def system_line(assigns) do
    ~H"""
    <div id={@id} class="flex items-center justify-center gap-2 px-6 py-1 text-xs" data-tone={@tone}>
      <span class="h-px flex-1 bg-base-300/70" />
      <span class={[
        "flex items-center gap-1.5 whitespace-pre-wrap text-center",
        @tone == "muted" && "text-base-content/55",
        @tone == "success" && "text-success",
        @tone == "error" && "text-error",
        @tone == "warning" && "text-warning"
      ]}>
        <.icon name={@icon} class="size-3.5 shrink-0 opacity-70" />
        <span>{render_slot(@inner_block)}</span>
        <time :if={@at} class="text-[10px] opacity-60" title={DateTime.to_iso8601(@at)}>
          {short_time(@at)}
        </time>
      </span>
      <span class="h-px flex-1 bg-base-300/70" />
    </div>
    """
  end

  # -- Live telemetry ----------------------------------------------------------

  @doc "The collapsible card showing what a busy agent is doing right now."
  attr :agent_id, :string, required: true
  attr :name, :string, required: true
  attr :card, :map, required: true

  def telemetry_card(assigns) do
    ~H"""
    <section
      id={"telemetry-#{@agent_id}"}
      class="mx-6 my-2 overflow-hidden rounded-xl border border-success/30 bg-success/5 shadow-xs"
      data-collapsed={to_string(@card.collapsed)}
    >
      <button
        type="button"
        id={"telemetry-toggle-#{@agent_id}"}
        class="flex w-full items-center gap-2 px-4 py-2 text-left text-sm transition hover:bg-success/10"
        phx-click="toggle_telemetry"
        phx-value-agent-id={@agent_id}
      >
        <Layouts.status_dot status={:busy} />
        <span class="font-medium">@{@name} is working…</span>
        <span class="ml-auto flex items-center gap-3 text-[11px] text-base-content/50">
          <span :if={@card.tool_count > 0}>{@card.tool_count} tools</span>
          <span :if={@card.cost > 0}>{format_cost(@card.cost)}</span>
          <.icon
            name={if(@card.collapsed, do: "hero-chevron-down-mini", else: "hero-chevron-up-mini")}
            class="size-4"
          />
        </span>
      </button>
      <div :if={!@card.collapsed} class="border-t border-success/20 px-4 py-2">
        <ol :if={@card.entries != []} class="flex flex-col gap-0.5 font-mono text-xs">
          <li
            :for={entry <- @card.entries}
            id={"telemetry-#{@agent_id}-#{entry.key}"}
            class="flex items-start gap-2 text-base-content/75"
          >
            <.icon name={entry_icon(entry)} class={["mt-0.5 size-3.5 shrink-0", entry_class(entry)]} />
            <span class="min-w-0 truncate">
              <span class="text-base-content">{entry.label}</span>
              <span :if={entry.detail} class="text-base-content/50">— {entry.detail}</span>
            </span>
          </li>
        </ol>
        <p :if={@card.entries == []} class="text-xs text-base-content/50">
          Waiting for the first tool call…
        </p>
        <div :if={@card.preview != ""} class="mt-2 border-t border-dashed border-success/20 pt-2">
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
            Streaming
          </p>
          <p class="whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/80">
            {@card.preview}
          </p>
        </div>
      </div>
    </section>
    """
  end

  # -- Permission cards --------------------------------------------------------

  @doc "A pending OpenCode permission request with Once / Always / Reject."
  attr :request, :map, required: true
  attr :names, :map, required: true

  def permission_card(assigns) do
    ~H"""
    <section
      id={"permission-#{@request.id}"}
      class="mx-6 my-2 overflow-hidden rounded-xl border border-warning/40 bg-warning/5 shadow-xs"
    >
      <div class="flex items-center gap-2 px-4 py-2.5">
        <.icon name="hero-shield-exclamation" class="size-5 text-warning" />
        <div class="min-w-0 flex-1 text-sm">
          <span class="font-medium">@{requester_name(@request, @names)}</span>
          asks for <span class="font-semibold">{@request.permission}</span>
          permission
          <span :if={@request.patterns != []} class="text-base-content/60">
            on
            <code
              :for={pattern <- @request.patterns}
              class="mr-1 rounded bg-base-300/60 px-1 font-mono text-xs"
            >{pattern}</code>
          </span>
        </div>
        <div class="flex shrink-0 items-center gap-1.5">
          <button
            type="button"
            id={"permission-#{@request.id}-once"}
            class="btn btn-xs btn-primary"
            phx-click="respond_permission"
            phx-value-id={@request.id}
            phx-value-reply="once"
          >
            Once
          </button>
          <button
            type="button"
            id={"permission-#{@request.id}-always"}
            class="btn btn-xs btn-primary btn-soft"
            phx-click="respond_permission"
            phx-value-id={@request.id}
            phx-value-reply="always"
          >
            Always
          </button>
          <button
            type="button"
            id={"permission-#{@request.id}-reject"}
            class="btn btn-xs btn-ghost text-error"
            phx-click="respond_permission"
            phx-value-id={@request.id}
            phx-value-reply="reject"
          >
            Reject
          </button>
        </div>
      </div>
      <pre
        :if={is_binary(@request.metadata["diff"]) and @request.metadata["diff"] != ""}
        class="max-h-72 overflow-auto border-t border-warning/20 bg-base-100/60 px-4 py-2 font-mono text-xs leading-relaxed"
      ><code>{@request.metadata["diff"]}</code></pre>
    </section>
    """
  end

  # -- Handoff banners ---------------------------------------------------------

  @doc "A pending handoff with Accept / Reject on the user's behalf."
  attr :handoff, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true

  def handoff_banner(assigns) do
    ~H"""
    <section
      id={"handoff-#{@handoff.id}"}
      class="flex flex-wrap items-center gap-3 border-b border-info/30 bg-info/5 px-6 py-2.5 text-sm"
    >
      <.icon name="hero-arrow-right-circle" class="size-5 shrink-0 text-info" />
      <div class="min-w-0 flex-1">
        <span class="font-medium">{agent_ref(@names, @handoff.from_agent_id, @user_name)}</span>
        is handing this task to
        <span class="font-medium">{agent_ref(@names, @handoff.to_agent_id, @user_name)}</span>
        <span :if={@handoff.reason} class="text-base-content/60">— {@handoff.reason}</span>
        <p :if={@handoff.suggested_next_step} class="mt-0.5 text-xs text-base-content/60">
          Next: {@handoff.suggested_next_step}
        </p>
      </div>
      <button
        type="button"
        id={"handoff-#{@handoff.id}-accept"}
        class="btn btn-xs btn-primary"
        phx-click="accept_handoff"
        phx-value-id={@handoff.id}
      >
        Accept
      </button>
      <.form
        for={%{}}
        as={:handoff}
        id={"handoff-#{@handoff.id}-reject-form"}
        phx-submit="reject_handoff"
        class="flex items-center gap-1.5"
      >
        <input type="hidden" name="handoff_id" value={@handoff.id} />
        <input
          type="text"
          name="reason"
          placeholder="Reason"
          class="input input-xs w-40"
          aria-label="Rejection reason"
        />
        <button
          type="submit"
          id={"handoff-#{@handoff.id}-reject"}
          class="btn btn-xs btn-ghost text-error"
        >
          Reject
        </button>
      </.form>
    </section>
    """
  end

  # -- Event text --------------------------------------------------------------

  @doc "The one-line description of a collaboration event."
  def event_text(%{event_type: type, payload: p} = event, names, user_name) do
    agent = agent_ref(names, event.agent_id, user_name)
    from = agent_ref(names, p["from_agent_id"], user_name)
    to = agent_ref(names, p["to_agent_id"], user_name)

    case type do
      "agent_started" ->
        "#{agent} started working"

      "agent_turn_completed" ->
        verb = if p["outcome"] == "ok", do: "finished", else: "stopped with an error"
        Enum.join([agent <> " " <> verb | turn_stats(p)], " · ")

      "agent_error" ->
        "#{agent} hit an error: #{p["reason"]}"

      "delegation_created" ->
        "#{from} delegated to #{to}: #{p["description"]}"

      "delegation_completed" ->
        "#{to} completed the delegation for #{from}" <> suffix(p["result"])

      "delegation_failed" ->
        "#{to} could not complete the delegation for #{from}" <> suffix(p["result"])

      "handoff_requested" ->
        "#{from} handed this task to #{to}" <> suffix(p["reason"] || p["summary"])

      "handoff_accepted" ->
        "#{to} accepted the handoff from #{from}"

      "handoff_rejected" ->
        "#{to} declined the handoff from #{from}" <> suffix(p["reason"])

      "task_updated" ->
        "#{agent} updated the task" <> suffix(task_changes(p))

      "owner_changed" ->
        if is_nil(p["from_agent_id"]),
          do: "#{to} now owns this task",
          else: "ownership moved from #{from} to #{to}"

      "permission_requested" ->
        "#{agent} asked for #{p["permission"]} permission" <>
          suffix(Enum.join(List.wrap(p["patterns"]), ", "))

      "permission_resolved" ->
        "#{p["permission"]} permission #{permission_status(p["status"])}"

      other ->
        "#{agent} · #{other}"
    end
  end

  @doc "The `@name` of an agent id, or the user's name when the id is nil."
  def agent_ref(_names, nil, user_name), do: user_name
  def agent_ref(names, id, _user_name), do: "@" <> Map.get(names, id, "unknown")

  @doc "Formats a dollar cost with enough precision for cents of a cent."
  def format_cost(cost) when is_number(cost) do
    "$" <> :erlang.float_to_binary(cost / 1, decimals: 4)
  end

  def format_cost(_), do: "$0.0000"

  @doc "Formats milliseconds as seconds or minutes."
  def format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  def format_duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{seconds}s"
  end

  def format_duration(_), do: nil

  @doc "The HH:MM of a datetime (UTC)."
  def short_time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  def short_time(_), do: ""

  # -- Body parsing ------------------------------------------------------------

  @doc """
  Splits a body into `{:code, lang, code}` and `{:text, parts}` segments, where
  parts are `{:mention, "@name"}` or `{:plain, text}`.
  """
  def body_segments(body) when is_binary(body) do
    @fence_regex
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.map(fn
      "```" <> _ = fenced -> fenced_segment(fenced)
      text -> {:text, mention_parts(text)}
    end)
  end

  def body_segments(_), do: []

  defp fenced_segment(fenced) do
    inner = fenced |> String.trim_leading("`") |> String.trim_trailing("`")

    case String.split(inner, "\n", parts: 2) do
      [lang, code] -> {:code, String.trim(lang), String.trim_trailing(code, "\n")}
      [only] -> {:code, "", only}
    end
  end

  defp mention_parts(text) do
    @mention_regex
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn
      "@" <> _ = mention -> {:mention, mention}
      plain -> {:plain, plain}
    end)
  end

  # -- Private helpers ---------------------------------------------------------

  defp sender_name(%{agent: %{name: name}}, _user_name) when is_binary(name), do: "@" <> name
  defp sender_name(%{user: %{display_name: name}}, _user_name) when is_binary(name), do: name
  defp sender_name(_message, user_name), do: user_name

  defp initial(name) do
    name |> String.trim_leading("@") |> String.first() |> to_string() |> String.upcase()
  end

  defp requester_name(%{agent_session: %{agent: %{name: name}}}, _names), do: name
  defp requester_name(_request, _names), do: "agent"

  defp turn_stats(p) do
    [
      count(p["tools"], "tool"),
      count(length(List.wrap(p["files"])), "file"),
      if(is_number(p["cost"]) and p["cost"] > 0, do: format_cost(p["cost"])),
      format_duration(p["duration_ms"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp count(n, _noun) when not is_integer(n) or n == 0, do: nil
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp suffix(nil), do: ""
  defp suffix(""), do: ""
  defp suffix(text) when is_binary(text), do: ": " <> truncate(text, 160)
  defp suffix(other), do: ": " <> truncate(inspect(other), 160)

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp task_changes(%{"changes" => changes}) when is_map(changes) and map_size(changes) > 0 do
    Enum.map_join(changes, ", ", fn
      {"status", value} -> "status → #{value}"
      {"title", value} -> "title → #{value}"
      {"owner_agent_id", _} -> "owner"
      {field, _} -> field
    end)
  end

  defp task_changes(%{"status" => status}) when is_binary(status), do: "status → #{status}"
  defp task_changes(_), do: nil

  defp permission_status("once"), do: "granted once"
  defp permission_status("always"), do: "granted for the session"
  defp permission_status("rejected"), do: "rejected"
  defp permission_status(other), do: to_string(other)

  defp event_icon("agent_started"), do: "hero-play-circle-mini"
  defp event_icon("agent_turn_completed"), do: "hero-check-circle-mini"
  defp event_icon("agent_error"), do: "hero-exclamation-triangle-mini"
  defp event_icon("delegation_" <> _), do: "hero-arrow-uturn-right-mini"
  defp event_icon("handoff_" <> _), do: "hero-arrow-right-circle-mini"
  defp event_icon("task_updated"), do: "hero-clipboard-document-check-mini"
  defp event_icon("owner_changed"), do: "hero-user-circle-mini"
  defp event_icon("permission_" <> _), do: "hero-shield-check-mini"
  defp event_icon(_), do: "hero-information-circle-mini"

  defp event_tone(%{event_type: "agent_error"}), do: "error"
  defp event_tone(%{event_type: "delegation_failed"}), do: "error"
  defp event_tone(%{event_type: "handoff_rejected"}), do: "warning"

  defp event_tone(%{event_type: "agent_turn_completed", payload: %{"outcome" => "error"}}),
    do: "error"

  defp event_tone(%{event_type: type}) when type in ~w(handoff_accepted delegation_completed),
    do: "success"

  defp event_tone(_), do: "muted"

  defp entry_icon(%{kind: :tool, status: :running}), do: "hero-arrow-path-mini"
  defp entry_icon(%{kind: :tool, status: :error}), do: "hero-x-circle-mini"
  defp entry_icon(%{kind: :tool}), do: "hero-wrench-screwdriver-mini"
  defp entry_icon(%{kind: :file}), do: "hero-pencil-square-mini"
  defp entry_icon(%{kind: :step}), do: "hero-flag-mini"
  defp entry_icon(%{kind: :diff}), do: "hero-document-text-mini"
  defp entry_icon(_), do: "hero-information-circle-mini"

  defp entry_class(%{kind: :tool, status: :running}), do: "animate-spin text-success"
  defp entry_class(%{kind: :tool, status: :error}), do: "text-error"
  defp entry_class(%{kind: :file}), do: "text-warning"
  defp entry_class(_), do: "text-base-content/40"
end
