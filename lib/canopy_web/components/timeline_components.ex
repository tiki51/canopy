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

  alias Canopy.Runtime.Activity
  alias CanopyWeb.Markdown

  # -- Timeline items ----------------------------------------------------------

  @doc "Renders one timeline event by its type."
  attr :id, :string, required: true
  attr :event, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :replies, :list, default: []
  attr :channels, :map, default: %{}, doc: "channel name => id, for #channel links in bodies"

  def timeline_item(%{event: %{event_type: "message"}} = assigns) do
    ~H"""
    <div id={@id}>
      <.message_item
        message={@event.message}
        names={@names}
        user_name={@user_name}
        replies={@replies}
        channels={@channels}
        inline_reply={not is_nil(@event.message.thread_id)}
      />
    </div>
    """
  end

  def timeline_item(%{event: %{event_type: "agent_turn_completed"}} = assigns) do
    assigns =
      assigns
      |> assign(:entries, Activity.from_payload(assigns.event.payload["activity"]))
      |> assign(:final_text, assigns.event.payload["final_text"])

    ~H"""
    <div id={@id} data-activity={activity_class(@event)}>
      <.turn_card
        event={@event}
        names={@names}
        user_name={@user_name}
        entries={@entries}
        final_text={@final_text}
      />
    </div>
    """
  end

  def timeline_item(assigns) do
    ~H"""
    <div id={@id} data-activity={activity_class(@event)}>
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
  attr :channels, :map, default: %{}

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
        "group flex gap-3 px-3 py-2 transition-colors sm:px-6 hover:bg-base-200/50",
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
          <.message_text
            :if={@message.body not in [nil, ""]}
            body={@message.body}
            channels={@channels}
          />
          <.attachments message={@message} />
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
            <div :for={reply <- @replies} class="-mx-3 sm:-mx-6">
              <.message_item
                message={reply}
                names={@names}
                user_name={@user_name}
                channels={@channels}
              />
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
        is_nil(@message.agent_id) &&
          "bg-secondary text-secondary-content shadow-sm ring-2 ring-secondary/30"
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
  Renders a message body. Bodies are GitHub-flavoured Markdown, rendered by
  `CanopyWeb.Markdown` with raw HTML escaped. The inline variant, used for
  one-line system notes, keeps the text as written and only highlights mentions.
  """
  attr :body, :string, required: true
  attr :inline, :boolean, default: false
  attr :channels, :map, default: %{}

  def message_text(%{inline: true} = assigns) do
    assigns = assign(assigns, :parts, Markdown.mention_parts(assigns.body || ""))

    ~H"""
    <span class="whitespace-pre-wrap break-words" phx-no-format><%= for part <- @parts do %><%= case part do %><% {:mention, name} -> %><span class={Markdown.mention_class()}>{name}</span><% {:plain, text} -> %>{text}<% end %><% end %></span>
    """
  end

  def message_text(assigns) do
    assigns = assign(assigns, :html, Markdown.to_html(assigns.body, channels: assigns.channels))

    ~H"""
    <div class="message-body break-words">{raw(@html)}</div>
    """
  end

  @doc """
  The documents attached to a message: images inline (opening the file in a
  new tab), everything else as a card with a download link.
  """
  attr :message, :map, required: true

  def attachments(%{message: %{documents: docs}} = assigns) when is_list(docs) and docs != [] do
    ~H"""
    <div class="mt-1.5 flex flex-wrap gap-2" id={"attachments-#{@message.id}"}>
      <%= for doc <- @message.documents do %>
        <a
          :if={doc.kind == "image"}
          id={"attachment-#{@message.id}-#{doc.id}"}
          href={Canopy.Documents.url_path(doc)}
          target="_blank"
          rel="noopener"
          class="block max-w-full overflow-hidden rounded-lg border border-base-300 bg-base-200"
          title={"#{doc.filename} (#{Canopy.Documents.size_label(doc.byte_size)})"}
          data-kind="image"
        >
          <img
            src={Canopy.Documents.url_path(doc)}
            alt={doc.filename}
            loading="lazy"
            class="max-h-80 max-w-full object-contain"
          />
        </a>
        <a
          :if={doc.kind != "image"}
          id={"attachment-#{@message.id}-#{doc.id}"}
          href={Canopy.Documents.url_path(doc)}
          target="_blank"
          rel="noopener"
          class="flex max-w-xs items-center gap-2 rounded-lg border border-base-300 bg-base-200 px-2.5 py-1.5 text-xs transition hover:border-primary/50"
          data-kind={doc.kind}
        >
          <.icon name={document_icon(doc.kind)} class="size-5 shrink-0 text-base-content/60" />
          <span class="min-w-0">
            <span class="block truncate font-medium">{doc.filename}</span>
            <span class="block text-base-content/50">
              {String.upcase(doc.kind)} · {Canopy.Documents.size_label(doc.byte_size)}
            </span>
          </span>
          <.icon name="hero-arrow-down-tray-mini" class="ml-1 size-4 shrink-0 text-base-content/50" />
        </a>
      <% end %>
    </div>
    """
  end

  def attachments(assigns), do: ~H""

  defp document_icon("text"), do: "hero-document-text"
  defp document_icon("pdf"), do: "hero-document"
  defp document_icon(_), do: "hero-paper-clip"

  @doc "A centred, subtle line for collaboration events and system notes."
  attr :id, :string, required: true
  attr :icon, :string, default: "hero-information-circle-mini"
  attr :tone, :string, default: "muted", values: ~w(muted success error warning)
  attr :at, :any, default: nil
  slot :inner_block, required: true

  def system_line(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-center justify-center gap-2 px-3 py-1 text-xs sm:px-6"
      data-tone={@tone}
    >
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

  @doc """
  "routine" for lines the compact timeline hides: a turn starting, a turn that
  finished cleanly (including a pass with nothing to say), a schedule firing.
  Errors, passes with a note, and everything a person might act on stay visible.
  """
  def activity_class(%{event_type: "agent_started"}), do: "routine"
  def activity_class(%{event_type: "schedule_fired"}), do: "routine"
  def activity_class(%{event_type: "session_compacted"}), do: "routine"

  def activity_class(%{event_type: "agent_turn_completed", payload: p}) do
    cond do
      p["outcome"] != "ok" -> nil
      p["passed"] && present?(p["note"]) -> nil
      true -> "routine"
    end
  end

  def activity_class(_event), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # -- Activity cards ----------------------------------------------------------

  @doc """
  What a busy agent is doing right now. Closed by default; the header pulses
  while the turn is in flight.
  """
  attr :agent_id, :string, required: true
  attr :name, :string, required: true
  attr :card, :map, required: true

  def telemetry_card(assigns) do
    ~H"""
    <details
      id={"telemetry-#{@agent_id}"}
      class="group/card mx-3 my-2 overflow-hidden sm:mx-6 rounded-xl border border-secondary/40 bg-secondary/10 shadow-xs"
      data-live="true"
    >
      <summary
        id={"telemetry-toggle-#{@agent_id}"}
        class="flex cursor-pointer select-none list-none items-center gap-2 px-4 py-2 text-sm transition hover:bg-secondary/15 [&::-webkit-details-marker]:hidden"
      >
        <Layouts.status_dot status={:busy} />
        <span class="font-medium text-secondary">@{@name} is {Activity.verb(@card)}…</span>
        <span class="ml-auto flex items-center gap-3 text-[11px] text-base-content/50">
          <span :if={@card.tool_count > 0}>{@card.tool_count} tools</span>
          <span :if={@card.cost > 0}>{format_cost(@card.cost)}</span>
          <.chevron />
        </span>
      </summary>
      <div class="border-t border-secondary/20 px-4 py-2">
        <.activity_list id={"telemetry-#{@agent_id}"} entries={@card.entries} />
        <p :if={@card.entries == []} class="text-xs text-base-content/50">
          Waiting for the first tool call…
        </p>
        <div :if={@card.preview != ""} class="mt-2 border-t border-dashed border-secondary/20 pt-2">
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
            Streaming
          </p>
          <p class="whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/80">
            {@card.preview}
          </p>
        </div>
      </div>
    </details>
    """
  end

  @doc """
  A finished turn: the same summary line as before, reopenable to show the
  activity the live card held. Falls back to a plain line when nothing was recorded.
  """
  attr :event, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :entries, :list, default: []
  attr :final_text, :string, default: nil

  def turn_card(%{entries: [], final_text: nil} = assigns) do
    ~H"""
    <.system_line
      id={"line-#{@event.id}"}
      icon={event_icon(@event.event_type)}
      tone={event_tone(@event)}
      at={@event.inserted_at}
    >
      {event_text(@event, @names, @user_name)}
    </.system_line>
    """
  end

  def turn_card(assigns) do
    assigns = assign(assigns, :tone, event_tone(assigns.event))

    ~H"""
    <details
      id={"turn-#{@event.id}"}
      class={[
        "group/card mx-3 my-1 overflow-hidden sm:mx-6 rounded-xl border transition",
        @tone == "error" && "border-error/30 open:bg-error/5",
        @tone != "error" && "border-transparent open:border-base-300 open:bg-base-200/40"
      ]}
      data-tone={@tone}
    >
      <summary
        id={"turn-toggle-#{@event.id}"}
        class="flex cursor-pointer select-none list-none items-center justify-center gap-2 px-4 py-1 text-xs [&::-webkit-details-marker]:hidden"
        title="Show what the agent did"
      >
        <span class="h-px flex-1 bg-base-300/70" />
        <span class={[
          "flex items-center gap-1.5 whitespace-pre-wrap text-center",
          @tone == "error" && "text-error",
          @tone != "error" && "text-base-content/55"
        ]}>
          <.icon name={event_icon(@event.event_type)} class="size-3.5 shrink-0 opacity-70" />
          <span>{event_text(@event, @names, @user_name)}</span>
          <time
            class="text-[10px] opacity-60"
            title={DateTime.to_iso8601(@event.inserted_at)}
          >
            {short_time(@event.inserted_at)}
          </time>
          <.chevron />
        </span>
        <span class="h-px flex-1 bg-base-300/70" />
      </summary>
      <div class="px-4 pb-2 pt-1">
        <.activity_list id={"turn-#{@event.id}"} entries={@entries} />
        <div
          :if={@final_text}
          id={"turn-#{@event.id}-note"}
          class={["border-t border-dashed border-base-300 pt-2", @entries != [] && "mt-2"]}
        >
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
            Closing note
          </p>
          <.message_text body={@final_text} />
        </div>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true

  defp activity_list(assigns) do
    ~H"""
    <ol :if={@entries != []} class="flex flex-col gap-0.5 font-mono text-xs">
      <li
        :for={entry <- @entries}
        id={"#{@id}-#{dom_key(entry.key)}"}
        class="flex items-start gap-2 text-base-content/75"
      >
        <.icon name={entry_icon(entry)} class={["mt-0.5 size-3.5 shrink-0", entry_class(entry)]} />
        <span class="min-w-0 truncate">
          <span class="text-base-content">{entry.label}</span>
          <span :if={entry.detail} class="text-base-content/50">— {entry.detail}</span>
        </span>
      </li>
    </ol>
    """
  end

  # Entry keys carry paths; ids must stay selector-safe.
  defp dom_key(key), do: Regex.replace(~r/[^A-Za-z0-9_-]+/, key, "-")

  defp chevron(assigns) do
    ~H"""
    <.icon
      name="hero-chevron-down-mini"
      class="size-4 shrink-0 opacity-60 transition-transform group-open/card:rotate-180"
    />
    """
  end

  # -- Schedules -----------------------------------------------------------------

  @doc """
  A list of schedules with a Cancel button each. `scope` is `:channel` (agent
  shown) or `:agent` (channel shown). Emits `cancel_schedule` with the id.
  """
  attr :id, :string, required: true
  attr :schedules, :list, required: true
  attr :scope, :atom, default: :channel
  attr :empty, :string, default: "Nothing scheduled."

  def schedule_list(assigns) do
    ~H"""
    <ul id={@id} class="flex flex-col divide-y divide-base-300">
      <li
        :for={s <- @schedules}
        id={"#{@id}-#{s.id}"}
        data-status={s.status}
        class={["flex items-start gap-3 py-2 text-sm", s.status == "paused" && "opacity-60"]}
      >
        <.icon
          name={if s.kind == "recurring", do: "hero-arrow-path-mini", else: "hero-clock-mini"}
          class="mt-0.5 size-4 shrink-0 text-base-content/50"
        />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span class="font-medium" title={DateTime.to_iso8601(s.next_run_at)}>
              {Canopy.Schedules.local_text(s.next_run_at)}
            </span>
            <span class="text-xs text-base-content/60">{Canopy.Schedules.relative(s.next_run_at)}</span>
            <span :if={s.kind == "recurring"} class="text-xs text-base-content/60">
              · {Canopy.Schedules.describe_cron(s.cron)}
            </span>
            <span :if={@scope == :channel} class="font-mono text-xs text-base-content/60">@{s.agent.name}</span>
            <.link
              :if={@scope == :agent}
              navigate={~p"/channels/#{s.channel_id}"}
              class="font-mono text-xs text-secondary hover:underline"
            >
              #{s.channel.name}
            </.link>
            <span
              :if={s.status == "paused"}
              class="badge badge-ghost badge-xs"
              title={s.status_reason}
            >
              paused
            </span>
          </div>
          <p class="mt-0.5 break-words text-xs text-base-content/75">{s.instruction}</p>
          <p
            :if={s.status == "paused" and s.status_reason}
            class="mt-0.5 text-[11px] text-base-content/50"
          >
            {s.status_reason}
          </p>
        </div>
        <button
          type="button"
          id={"cancel-schedule-#{s.id}"}
          class="btn btn-ghost btn-xs shrink-0 text-base-content/60 hover:text-error"
          phx-click="cancel_schedule"
          phx-value-id={s.id}
          data-canopy-confirm="It will not run again."
          data-canopy-confirm-title="Cancel this schedule?"
          data-canopy-confirm-label="Cancel schedule"
          title="Cancel"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </li>
      <li :if={@schedules == []} class="py-2 text-xs text-base-content/50">{@empty}</li>
    </ul>
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
      class="mx-3 my-2 overflow-hidden rounded-xl border border-warning/40 bg-warning/5 shadow-xs sm:mx-6"
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
    user = user_name

    case type do
      "agent_started" ->
        "#{agent} started working"

      "session_compacted" ->
        "#{agent}'s session was compacted after reaching #{p["context"]} tokens of context"

      "session_reset" ->
        "#{if p["by"] == "user", do: user, else: p["by"]} reset #{agent}'s session; it starts fresh on its next turn"

      "agent_turn_completed" ->
        verb =
          cond do
            p["outcome"] != "ok" -> "stopped with an error"
            p["passed"] -> "passed" <> suffix(p["note"])
            true -> "finished"
          end

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

      "member_added" ->
        "#{agent} joined the channel"

      "member_removed" ->
        "#{agent} was removed from the channel"

      "channel_archived" ->
        "#{user} archived this channel"

      "channel_reopened" ->
        "#{user} reopened this channel"

      "spend_limit_changed" ->
        by = if p["by"] in ["user", nil], do: user, else: "@" <> p["by"]

        if is_number(p["limit"]),
          do: "#{by} set this channel's spend limit to #{Canopy.Costs.money(p["limit"])}",
          else: "#{by} removed this channel's spend limit"

      "spend_limit_reached" ->
        "spend limit reached: #{Canopy.Costs.money(p["spent"])} of #{Canopy.Costs.money(p["limit"])}; agents stay quiet here until the limit is raised"

      "repository_switched" ->
        by = if p["by"] == "user", do: user, else: p["by"]

        "#{by} moved this conversation to #{p["to"]}" <>
          if(p["from"], do: " (from #{p["from"]})", else: "")

      "schedule_created" ->
        by =
          if p["created_by_agent_id"] == event.agent_id,
            do: "",
            else: " (by #{agent_ref(names, p["created_by_agent_id"], user_name)})"

        "#{agent} scheduled#{by}: #{schedule_timing(p)} · #{p["instruction"]}"

      "schedule_fired" ->
        "scheduled task fired for #{agent}: #{p["instruction"]}"

      "schedule_skipped" ->
        "skipped a scheduled task for #{agent}" <> suffix(p["reason"]) <> ": #{p["instruction"]}"

      "schedule_cancelled" ->
        "cancelled a schedule for #{agent}" <> suffix(p["reason"]) <> ": #{p["instruction"]}"

      "schedule_paused" ->
        "paused a schedule for #{agent}" <> suffix(p["reason"]) <> ": #{p["instruction"]}"

      "schedule_resumed" ->
        "resumed a schedule for #{agent}: #{schedule_timing(p)} · #{p["instruction"]}"

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
  defdelegate format_cost(cost), to: Activity

  @doc "Formats milliseconds as seconds or minutes."
  def format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  def format_duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{seconds}s"
  end

  def format_duration(_), do: nil

  @doc "The HH:MM of a datetime in the machine's local time."
  def short_time(%DateTime{} = at),
    do: at |> Canopy.Schedules.When.to_local_naive() |> Calendar.strftime("%H:%M")

  def short_time(_), do: ""

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

  defp schedule_timing(%{"kind" => "recurring", "cron" => cron}),
    do: Canopy.Schedules.describe_cron(cron)

  defp schedule_timing(_), do: "once"

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
  defp event_icon("session_reset"), do: "hero-arrow-path-mini"
  defp event_icon("session_compacted"), do: "hero-arrows-pointing-in-mini"
  defp event_icon("agent_turn_completed"), do: "hero-check-circle-mini"
  defp event_icon("agent_error"), do: "hero-exclamation-triangle-mini"
  defp event_icon("delegation_" <> _), do: "hero-arrow-uturn-right-mini"
  defp event_icon("handoff_" <> _), do: "hero-arrow-right-circle-mini"
  defp event_icon("task_updated"), do: "hero-clipboard-document-check-mini"
  defp event_icon("owner_changed"), do: "hero-user-circle-mini"
  defp event_icon("member_added"), do: "hero-user-plus-mini"
  defp event_icon("member_removed"), do: "hero-user-minus-mini"
  defp event_icon("channel_archived"), do: "hero-archive-box-mini"
  defp event_icon("channel_reopened"), do: "hero-archive-box-x-mark-mini"
  defp event_icon("spend_limit_" <> _), do: "hero-banknotes-mini"
  defp event_icon("repository_switched"), do: "hero-folder-arrow-down-mini"
  defp event_icon("schedule_fired"), do: "hero-bell-alert-mini"
  defp event_icon("schedule_" <> _), do: "hero-clock-mini"
  defp event_icon("permission_" <> _), do: "hero-shield-check-mini"
  defp event_icon(_), do: "hero-information-circle-mini"

  defp event_tone(%{event_type: "agent_error"}), do: "error"
  defp event_tone(%{event_type: "spend_limit_reached"}), do: "error"
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
