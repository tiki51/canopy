defmodule CanopyWeb.TimelineComponents do
  @moduledoc """
  Function components for the channel feed and the thread panel: messages
  (a thread's root with its summary row), collaboration events rendered as
  centred system lines, the live telemetry card of a working agent,
  permission cards, and handoff banners.

  Every component that names an agent takes a `names` map (`agent_id => name`)
  and the local user's display name, so events with a nil agent read naturally
  ("Steven handed this task to @database").
  """

  use CanopyWeb, :html

  alias Canopy.Runtime.Activity
  alias CanopyWeb.Markdown

  # -- Timeline items ----------------------------------------------------------

  @doc """
  Renders one timeline event by its type. Message events take `thread`, what
  the message shows about threads (all keys optional):

    * `:href` — the thread to open from "Reply in thread"
    * `:link` — the path "Copy link" copies
    * `:summary` — the summary row under a thread's root: `%{root_id, count,
      last_reply_at, participants, open?, unread?, working}`
    * `:parent` — for a reply also sent to the channel, `%{href, excerpt}` of
      its thread
    * `:highlight` — mark the message as the open thread's root
    * `:target` — the reply a link pointed at: the thread panel scrolls to it
      and flashes it
    * `:divider` — inside the thread panel, the reply count under the root

  `dom_prefix` keeps a message's DOM ids unique when it shows both in the feed
  and in the thread panel. A turn card takes `activity`, the view's state for
  it (see `turn_card/1`); an agent's message takes `receipt`, the turn that
  posted it (`%{event_id, tools, duration_ms}`), shown as a chip in the
  compact timeline.
  """
  attr :id, :string, required: true
  attr :event, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :thread, :map, default: %{}
  attr :dom_prefix, :string, default: "message"
  attr :channels, :map, default: %{}, doc: "channel name => id, for #channel links in bodies"

  attr :mentions, :any,
    default: MapSet.new(),
    doc: "agent and team names highlighted as @mentions in bodies"

  attr :root, :string,
    default: nil,
    doc: "the repository path; tool paths inside it show relative"

  attr :activity, :map, default: %{}
  attr :receipt, :map, default: nil

  attr :queued, :atom,
    default: nil,
    doc: "a message steered into a working turn, not yet read: `:next_step` or `:held`"

  attr :reactable, :boolean,
    default: false,
    doc: "the user may react (not in an archived channel)"

  def timeline_item(%{event: %{event_type: "message"}} = assigns) do
    ~H"""
    <div id={@id} data-scroll-target={@thread[:target] && "true"}>
      <.message_item
        message={@event.message}
        names={@names}
        user_name={@user_name}
        channels={@channels}
        mentions={@mentions}
        dom_prefix={@dom_prefix}
        thread_href={@thread[:href]}
        link={@thread[:link]}
        summary={@thread[:summary]}
        parent={@thread[:parent]}
        highlight={@thread[:highlight] == true}
        target={@thread[:target] == true}
        receipt={@receipt}
        queued={@queued}
        reactable={@reactable}
      />
      <div
        :if={is_integer(@thread[:divider])}
        id="thread-divider"
        class="flex items-center gap-2 px-3 py-1 text-[11px] font-medium text-base-content/55 sm:px-4"
      >
        <span>{ngettext("1 reply", "%{count} replies", @thread[:divider])}</span>
        <span class="h-px flex-1 bg-base-300/70" />
      </div>
    </div>
    """
  end

  def timeline_item(%{event: %{event_type: "agent_turn_completed"}} = assigns) do
    assigns =
      assigns
      |> assign(:final_text, assigns.event.payload["final_text"])
      |> assign(:card, Activity.card_from_payload(assigns.event.payload))

    ~H"""
    <div id={@id} data-activity={activity_class(@event)}>
      <.turn_card
        event={@event}
        names={@names}
        user_name={@user_name}
        card={@card}
        final_text={@final_text}
        root={@root}
        mentions={@mentions}
        activity={@activity}
      />
    </div>
    """
  end

  # The new text one click away; mentions in it are highlighted but woke nobody.
  def timeline_item(%{event: %{event_type: "brief_updated"}} = assigns) do
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
      <details
        :if={@event.payload["body"]}
        id={"brief-change-#{@event.id}"}
        class="group mx-auto mb-1 max-w-2xl px-3 text-xs sm:px-6"
      >
        <summary class="flex cursor-pointer list-none justify-center text-base-content/50 transition hover:text-base-content/80">
          <span class="group-open:hidden">Show the brief</span>
          <span class="hidden group-open:inline">Hide the brief</span>
        </summary>
        <div class="mt-1 max-h-64 overflow-y-auto rounded-lg border border-base-300 bg-base-200/40 px-3 py-2 text-sm">
          <.message_text body={@event.payload["body"]} channels={@channels} mentions={@mentions} />
        </div>
      </details>
    </div>
    """
  end

  # The session the reset dropped is still the engine's: one click reads it.
  def timeline_item(
        %{event: %{event_type: "session_reset", payload: %{"engine_session_id" => sid}}} =
          assigns
      )
      when is_binary(sid) and is_binary(assigns.event.agent_id) do
    ~H"""
    <div id={@id} data-activity={activity_class(@event)}>
      <.system_line
        id={"line-#{@event.id}"}
        icon={event_icon(@event.event_type)}
        tone={event_tone(@event)}
        at={@event.inserted_at}
      >
        {event_text(@event, @names, @user_name)} ·
        <.link
          navigate={
            ~p"/channels/#{@event.channel_id}/agents/#{@event.agent_id}/transcript?#{[session: @event.payload["engine_session_id"]]}"
          }
          id={"line-#{@event.id}-transcript"}
          class="link link-hover"
        >
          earlier transcript
        </.link>
      </.system_line>
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
  attr :dom_prefix, :string, default: "message"
  attr :thread_href, :string, default: nil, doc: "show Reply in thread, opening this thread"
  attr :link, :string, default: nil, doc: "show Copy link, copying this path"
  attr :summary, :map, default: nil, doc: "the summary row under a thread's root"
  attr :parent, :map, default: nil, doc: "`%{href, excerpt}` for a reply sent to the channel"
  attr :highlight, :boolean, default: false
  attr :target, :boolean, default: false
  attr :channels, :map, default: %{}
  attr :mentions, :any, default: MapSet.new()

  attr :receipt, :map,
    default: nil,
    doc: "`%{event_id, tools, duration_ms}` of the turn that posted it"

  attr :reactable, :boolean, default: false, doc: "show React and make the chips toggle"
  attr :queued, :atom, default: nil, doc: "`:next_step` or `:held` while it waits to be read"

  def message_item(%{message: %{kind: "system"}} = assigns) do
    ~H"""
    <.system_line
      id={"#{@dom_prefix}-#{@message.id}"}
      icon="hero-command-line-mini"
      tone="muted"
      at={@message.inserted_at}
    >
      <span class="font-medium">{sender_name(@message, @user_name)}</span>
      <.message_text body={@message.body} mentions={@mentions} inline />
    </.system_line>
    """
  end

  def message_item(assigns) do
    ~H"""
    <article
      id={"#{@dom_prefix}-#{@message.id}"}
      class={[
        "group relative flex gap-3 px-3 py-2 transition-colors sm:px-6 hover:bg-base-200/50",
        @message.kind == "reply" && "message-reply",
        @target && "message-target"
      ]}
      data-kind={@message.kind}
    >
      <span
        :if={@highlight}
        class="absolute inset-y-1 left-0 w-0.5 rounded-r-full bg-primary"
        aria-hidden="true"
      />
      <.avatar message={@message} user_name={@user_name} />
      <div class="min-w-0 flex-1">
        <.link
          :if={@parent}
          patch={@parent.href}
          id={"#{@dom_prefix}-parent-#{@message.id}"}
          class="mb-0.5 flex min-w-0 items-center gap-1 text-[11px] text-base-content/60 transition hover:text-primary"
          title="Open the thread"
        >
          <.icon name="hero-arrow-uturn-right-mini" class="size-3.5 shrink-0 rotate-180" />
          <span class="shrink-0">replied to a thread:</span>
          <span class="min-w-0 truncate">“{@parent.excerpt}”</span>
        </.link>
        <div class="flex items-baseline gap-2">
          <span class={[
            "text-sm font-semibold",
            @message.kind == "reply" && "text-base-content/60"
          ]}>
            {sender_name(@message, @user_name)}
          </span>
          <span
            :if={@message.kind == "reply"}
            class="rounded-full bg-base-300/70 px-1.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60"
            title="The agent's final turn text"
          >
            reply
          </span>
          <span
            :if={@message.sent_to_channel and is_nil(@parent)}
            id={"#{@dom_prefix}-also-#{@message.id}"}
            class="flex items-center gap-0.5 text-[11px] text-base-content/60"
            title="This reply was also sent to the channel"
          >
            <.icon name="hero-arrow-uturn-right-mini" class="size-3 rotate-180" /> also in channel
          </span>
          <time
            class="text-[11px] text-base-content/60"
            title={DateTime.to_iso8601(@message.inserted_at)}
          >
            {short_time(@message.inserted_at)}
          </time>
          <.link
            :if={@receipt}
            patch={~p"/channels/#{@message.channel_id}?#{[activity: @receipt.event_id]}"}
            id={"#{@dom_prefix}-receipt-#{@message.id}"}
            class="receipt-chip items-center gap-1 rounded-full border border-base-300 px-1.5 text-[10px] text-base-content/60 transition hover:border-primary/40 hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            title="See what the agent ran for this"
          >
            <.icon name="hero-cog-6-tooth-mini" class="size-3" />
            {receipt_text(@receipt)}
          </.link>
          <div
            :if={@thread_href || @link || @reactable}
            class="message-actions ml-auto flex items-center gap-0.5 opacity-0 transition focus-within:opacity-100 group-hover:opacity-100"
          >
            <.react_button
              :if={@reactable}
              message={@message}
              prefix={attachment_prefix(@dom_prefix)}
            />
            <.link
              :if={@thread_href}
              patch={@thread_href}
              id={"reply-#{@message.id}"}
              class="flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] font-medium text-base-content/60 transition hover:bg-base-300/60 hover:text-base-content"
              title="Reply in thread"
            >
              <.icon name="hero-chat-bubble-left-right-mini" class="size-3.5" />
              <span class="max-sm:sr-only">Reply</span>
            </.link>
            <button
              :if={@link}
              type="button"
              id={"#{@dom_prefix}-copy-link-#{@message.id}"}
              phx-hook="CopyLink"
              data-href={@link}
              class="flex items-center rounded-md px-1.5 py-0.5 text-[11px] text-base-content/60 transition hover:bg-base-300/60 hover:text-base-content"
              title="Copy link"
              aria-label="Copy link to this message"
            >
              <.icon name="hero-link-mini" class="size-3.5" />
            </button>
          </div>
        </div>
        <div class={[
          "mt-0.5 text-sm leading-relaxed",
          @message.kind == "reply" && "text-base-content/80"
        ]}>
          <.message_text
            :if={@message.body not in [nil, ""]}
            body={@message.body}
            channels={@channels}
            mentions={@mentions}
          />
          <.attachments message={@message} dom_prefix={attachment_prefix(@dom_prefix)} />
        </div>
        <p
          :if={@queued}
          id={"#{@dom_prefix}-queued-#{@message.id}"}
          class="mt-0.5 flex items-center gap-1 text-xs text-warning"
        >
          <.icon name="hero-clock-mini" class="size-3.5 shrink-0" />
          {if @queued == :held,
            do: "Queued · delivered once the card is answered",
            else: "Queued · delivered after the current step"}
        </p>

        <.reactions
          message={@message}
          prefix={attachment_prefix(@dom_prefix)}
          names={@names}
          reactable={@reactable}
        />

        <.thread_summary :if={@summary} href={@thread_href} summary={@summary} user_name={@user_name} />
      </div>
    </article>
    """
  end

  attr :message, :map, required: true
  attr :prefix, :string, required: true

  # The React button and its five-emoji picker. Opening and closing are
  # client-side only; a pick sends `toggle_reaction` and closes the picker.
  defp react_button(assigns) do
    assigns = assign(assigns, :picker, "#{assigns.prefix}react-picker-#{assigns.message.id}")

    ~H"""
    <div class="relative">
      <button
        type="button"
        id={"#{@prefix}react-#{@message.id}"}
        phx-click={JS.toggle(to: "##{@picker}", display: "flex")}
        class="flex items-center rounded-md px-1.5 py-0.5 text-[11px] text-base-content/60 transition hover:bg-base-300/60 hover:text-base-content"
        title="React"
        aria-label="Add a reaction"
        aria-haspopup="true"
      >
        <.icon name="hero-face-smile-mini" class="size-3.5" />
      </button>
      <div
        id={@picker}
        class="absolute right-0 top-full z-20 mt-1 hidden items-center gap-0.5 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg"
        phx-click-away={JS.hide(to: "##{@picker}")}
        role="menu"
      >
        <button
          :for={entry <- Canopy.Reactions.palette()}
          type="button"
          id={"#{@picker}-#{entry.key}"}
          phx-click={
            JS.push("toggle_reaction", value: %{id: @message.id, emoji: entry.key})
            |> JS.hide(to: "##{@picker}")
          }
          class="flex size-7 items-center justify-center rounded-md text-base transition hover:scale-110 hover:bg-base-200"
          title={entry.label}
          aria-label={"React #{entry.glyph} #{entry.label}"}
          role="menuitem"
        >
          {entry.glyph}
        </button>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :prefix, :string, required: true
  attr :names, :map, required: true
  attr :reactable, :boolean, default: false

  # One chip per emoji, in palette order: the glyph and the count, marked
  # when the user is among the reactors. A click toggles the user's own.
  defp reactions(assigns) do
    assigns =
      assign(assigns, :groups, Canopy.Reactions.group(Map.get(assigns.message, :reactions)))

    ~H"""
    <div
      :if={@groups != []}
      id={"#{@prefix}reactions-#{@message.id}"}
      class="mt-1 flex flex-wrap items-center gap-1"
    >
      <button
        :for={group <- @groups}
        type="button"
        id={"#{@prefix}reaction-#{@message.id}-#{group.key}"}
        phx-click={@reactable && "toggle_reaction"}
        phx-value-id={@message.id}
        phx-value-emoji={group.key}
        disabled={!@reactable}
        data-mine={group.user? && "true"}
        class={[
          "flex items-center gap-1 rounded-full border px-1.5 py-px text-xs transition",
          group.user? && "border-primary/40 bg-primary/10 ring-1 ring-primary/40",
          !group.user? && "border-base-300 bg-base-100",
          @reactable && "hover:border-primary/50 hover:bg-primary/5",
          !@reactable && "cursor-default"
        ]}
        title={reaction_title(group, @names)}
        aria-pressed={to_string(group.user?)}
      >
        <span>{group.glyph}</span>
        <span class="tabular-nums text-[11px] font-medium text-base-content/70">{group.count}</span>
      </button>
    </div>
    """
  end

  # "You, @qa: done / approved"
  defp reaction_title(group, names) do
    who =
      Enum.map_join(group.reactions, ", ", fn
        %{user_id: id} when is_binary(id) -> "You"
        %{agent_id: id} -> "@" <> Map.get(names, id, "agent")
      end)

    "#{who}: #{group.label}"
  end

  # The feed keeps the plain ids it always had; the thread panel's copies
  # carry the panel's prefix.
  defp attachment_prefix("message"), do: ""
  defp attachment_prefix(prefix), do: prefix <> "-"

  attr :href, :string, required: true
  attr :summary, :map, required: true
  attr :user_name, :string, required: true

  # The one line a thread leaves in the feed: who is in it, how many replies,
  # when the last one came, whether there is something new, and whether an
  # agent is replying right now. It opens the thread panel.
  defp thread_summary(assigns) do
    assigns =
      assigns
      |> assign(:shown, Enum.take(assigns.summary.participants, 3))
      |> assign(:more, max(length(assigns.summary.participants) - 3, 0))

    ~H"""
    <.link
      patch={@href}
      id={"thread-summary-#{@summary.root_id}"}
      class={[
        "mt-1.5 flex max-w-xl items-center gap-2 rounded-lg border px-2 py-1 text-xs transition",
        @summary.open? && "border-primary/30 bg-primary/5 ring-1 ring-primary/30",
        !@summary.open? &&
          "border-transparent hover:border-base-300 hover:bg-base-100 group-hover:border-base-300"
      ]}
      data-open={@summary.open? && "true"}
      title="Open the thread"
    >
      <span class="flex shrink-0 -space-x-1">
        <.mini_avatar :for={p <- @shown} participant={p} user_name={@user_name} />
        <span
          :if={@more > 0}
          class="flex size-5 items-center justify-center rounded-md bg-base-300 text-[9px] font-bold ring-2 ring-base-100"
        >
          +{@more}
        </span>
      </span>
      <span class="shrink-0 font-semibold text-primary">
        {ngettext("1 reply", "%{count} replies", @summary.count)}
      </span>
      <span
        :if={@summary.working != []}
        id={"thread-working-#{@summary.root_id}"}
        class="flex min-w-0 items-center gap-1.5 text-success"
      >
        <Layouts.status_dot status={:busy} />
        <span class="truncate">
          {Enum.map_join(@summary.working, ", ", &("@" <> &1))} {if length(@summary.working) == 1,
            do: "is",
            else: "are"} replying…
        </span>
      </span>
      <span
        :if={@summary.working == [] and @summary.last_reply_at}
        class="min-w-0 truncate text-base-content/55"
      >
        last reply {Canopy.MCP.Format.relative_time(@summary.last_reply_at)}
      </span>
      <span
        :if={@summary.unread?}
        id={"thread-unread-#{@summary.root_id}"}
        class="flex shrink-0 items-center gap-1 font-medium text-primary"
        title="New replies since you last read this thread"
      >
        <span class="size-1.5 rounded-full bg-primary" /> new
      </span>
      <span class="ml-auto flex shrink-0 items-center text-base-content/50">
        View <.icon name="hero-chevron-right-mini" class="size-3.5" />
      </span>
    </.link>
    """
  end

  @doc "A small avatar for a thread participant (`%{agent}`, nil for the user)."
  attr :participant, :map, required: true
  attr :user_name, :string, required: true

  def mini_avatar(%{participant: %{agent: %{} = agent}} = assigns) do
    assigns = assign(assigns, :agent, agent)

    ~H"""
    <span
      class="flex size-5 select-none items-center justify-center rounded-md bg-primary/15 text-[9px] font-bold text-primary ring-2 ring-base-100"
      style={
        @agent.color && "background-color: #{@agent.color}; color: #{initial_color(@agent.color)}"
      }
      title={"@" <> @agent.name}
    >
      {initial(@agent.name)}
    </span>
    """
  end

  def mini_avatar(assigns) do
    ~H"""
    <span
      class="flex size-5 select-none items-center justify-center rounded-md bg-secondary text-[9px] font-bold text-secondary-content ring-2 ring-base-100"
      title={@user_name}
    >
      {initial(@user_name)}
    </span>
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
          "background-color: #{@message.agent.color}; color: #{initial_color(@message.agent.color)}"
      }
      aria-hidden="true"
    >
      {initial(sender_name(@message, @user_name))}
    </div>
    """
  end

  @doc """
  The text colour for initials drawn on an agent's own colour: white unless it
  falls below WCAG AA (4.5:1) on that hex, then whichever of white and Blue
  Hour navy contrasts more (mid-luminance hues can fail with both).
  """
  def initial_color(hex) do
    # 0.00986 is the relative luminance of #0B1834.
    case luminance(hex) do
      {:ok, l} when 1.05 / (l + 0.05) < 4.5 and (l + 0.05) / 0.05986 > 1.05 / (l + 0.05) ->
        "#0B1834"

      _ ->
        "white"
    end
  end

  defp luminance("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    with {r, ""} <- Integer.parse(r, 16),
         {g, ""} <- Integer.parse(g, 16),
         {b, ""} <- Integer.parse(b, 16) do
      [lr, lg, lb] = Enum.map([r, g, b], &linear/1)
      {:ok, 0.2126 * lr + 0.7152 * lg + 0.0722 * lb}
    else
      _ -> :error
    end
  end

  defp luminance(_hex), do: :error

  defp linear(channel) do
    c = channel / 255
    if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  @doc """
  Renders a message body. Bodies are GitHub-flavoured Markdown, rendered by
  `CanopyWeb.Markdown` with raw HTML escaped. The inline variant, used for
  one-line system notes, keeps the text as written and only highlights mentions.
  Only `mentions` (known agent and team names) are highlighted.
  """
  attr :body, :string, required: true
  attr :inline, :boolean, default: false
  attr :channels, :map, default: %{}
  attr :mentions, :any, default: MapSet.new()

  def message_text(%{inline: true} = assigns) do
    assigns =
      assign(assigns, :parts, Markdown.mention_parts(assigns.body || "", assigns.mentions))

    ~H"""
    <span class="whitespace-pre-wrap break-words" phx-no-format><%= for part <- @parts do %><%= case part do %><% {:mention, name} -> %><span class={Markdown.mention_class()}>{name}</span><% {:plain, text} -> %>{text}<% end %><% end %></span>
    """
  end

  def message_text(assigns) do
    assigns =
      assign(
        assigns,
        :html,
        Markdown.to_html(assigns.body, channels: assigns.channels, mentions: assigns.mentions)
      )

    ~H"""
    <div class="message-body break-words">{raw(@html)}</div>
    """
  end

  @doc """
  The documents attached to a message: images inline (opening the file in a
  new tab), everything else as a card with a download link.
  """
  attr :message, :map, required: true
  attr :dom_prefix, :string, default: "", doc: "prefixes the ids where a message shows twice"

  def attachments(%{message: %{documents: docs}} = assigns) when is_list(docs) and docs != [] do
    ~H"""
    <div class="mt-1.5 flex flex-wrap gap-2" id={"#{@dom_prefix}attachments-#{@message.id}"}>
      <%= for doc <- @message.documents do %>
        <a
          :if={doc.kind == "image"}
          id={"#{@dom_prefix}attachment-#{@message.id}-#{doc.id}"}
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
          id={"#{@dom_prefix}attachment-#{@message.id}-#{doc.id}"}
          href={Canopy.Documents.url_path(doc)}
          target="_blank"
          rel="noopener"
          class="flex max-w-xs items-center gap-2 rounded-lg border border-base-300 bg-base-200 px-2.5 py-1.5 text-xs transition hover:border-primary/50"
          data-kind={doc.kind}
        >
          <.icon name={document_icon(doc.kind)} class="size-5 shrink-0 text-base-content/60" />
          <span class="min-w-0">
            <span class="block truncate font-medium">{doc.filename}</span>
            <span class="block text-base-content/60">
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
  finished cleanly (including a pass with nothing to say), a schedule firing,
  a lock taken while free or freed by its holder with nobody waiting. Errors,
  passes with a note, and everything a person might act on stay visible.
  """
  def activity_class(%{event_type: "agent_started"}), do: "routine"

  def activity_class(%{event_type: "lock_granted", payload: %{"promoted" => false}}),
    do: "routine"

  def activity_class(%{event_type: "lock_released", payload: p}) do
    if p["released_by"] in ["agent", "turn_end"] and is_nil(p["next_agent_id"]) and
         is_nil(p["note"]),
       do: "routine"
  end

  def activity_class(%{event_type: "schedule_fired"}), do: "routine"
  # the step that starts is already named on the line of the one that ended
  def activity_class(%{event_type: "playbook_step_started"}), do: "routine"
  def activity_class(%{event_type: "session_compacted"}), do: "routine"
  # a message handed to a working agent; Interrupt now stays visible
  def activity_class(%{event_type: "agent_interrupted", payload: %{"mode" => "next_step"}}),
    do: "routine"

  def activity_class(%{event_type: "agent_turn_completed", payload: p}) do
    cond do
      p["outcome"] != "ok" -> nil
      p["passed"] && present?(p["note"]) -> nil
      # the light model handed the wake to the main one
      p["escalated"] -> nil
      true -> "routine"
    end
  end

  def activity_class(_event), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # -- Activity cards ----------------------------------------------------------

  @doc """
  What a busy agent is doing right now. Closed by default: the header says
  what it is doing (the verb and the call running now), for how long, and
  how much it has done; opening it (`toggle_activity_card`) renders the
  rows. A turn blocked on a permission or question card says it is waiting
  for the user. While the user's messages wait to be read mid-turn (`steer`,
  `%{pending, held}`), a chip says when the agent will read them, with
  Interrupt now.
  """
  attr :agent_id, :string, required: true
  attr :name, :string, required: true
  attr :card, :map, required: true

  attr :steer, :map,
    default: nil,
    doc: "`%{pending, held}`: the user's messages steered into the turn"

  attr :root, :string, default: nil
  attr :channel_id, :string, default: nil, doc: "for the Open in panel link"
  attr :status, :atom, default: :busy
  attr :open?, :boolean, default: false
  attr :open_rows, :any, default: MapSet.new(), doc: "keys of the rows shown open"
  attr :highlight, :boolean, default: false, doc: "the card is open in the side panel"
  attr :auto_open?, :boolean, default: false, doc: "the browser opens live cards by itself"

  attr :question, :map,
    default: nil,
    doc: "the question the turn is blocked on: the card becomes the question card"

  attr :draft, :map, default: %{}, doc: "the question form's current params"

  def telemetry_card(assigns) do
    card = assigns.card

    assigns =
      assigns
      |> assign(:waiting?, assigns.status == :awaiting_user or assigns.question != nil)
      |> assign(:verb, Activity.verb(card))
      |> assign(:current, Activity.current(card))

    ~H"""
    <section
      id={"telemetry-#{@agent_id}"}
      class={[
        "mx-3 my-2 overflow-hidden rounded-xl border shadow-xs sm:mx-6",
        !@waiting? && "border-secondary/40 bg-secondary/10",
        @waiting? && "border-info/40 bg-info/5",
        @highlight && "ring-2 ring-primary/30"
      ]}
      data-live="true"
      data-open={to_string(@open?)}
      data-status={@status}
    >
      <div class={["flex items-center gap-1 pr-2", @open? && "sticky top-0 z-10 bg-inherit"]}>
        <button
          type="button"
          id={"telemetry-toggle-#{@agent_id}"}
          class="flex min-w-0 flex-1 flex-col gap-0.5 rounded-xl px-4 py-2 text-left text-sm transition hover:bg-secondary/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          phx-click="toggle_activity_card"
          phx-value-card={"telemetry-#{@agent_id}"}
          aria-expanded={to_string(@open?)}
          aria-controls={"telemetry-#{@agent_id}-body"}
        >
          <span class="flex w-full min-w-0 items-center gap-2">
            <Layouts.status_dot status={if @waiting?, do: :awaiting_user, else: :busy} />
            <span class={[
              "shrink-0 font-medium",
              !@waiting? && "text-secondary",
              @waiting? && "text-info"
            ]}>
              <%= cond do %>
                <% @question -> %>
                  @{@name} needs a decision to carry on
                <% @waiting? -> %>
                  @{@name} is waiting for you
                <% true -> %>
                  @{@name} is {@verb}…
              <% end %>
            </span>
            <span
              :if={@current && !@waiting?}
              id={"telemetry-#{@agent_id}-current"}
              class="min-w-0 truncate font-mono text-xs text-base-content/60 max-sm:hidden"
              title={@current[:command] || @current.label}
            >
              {relative_paths(@current.label, @root)}
            </span>
            <span class="ml-auto flex shrink-0 items-center gap-2 text-[11px] text-base-content/60">
              <span
                :if={@card.started_at}
                id={"telemetry-#{@agent_id}-elapsed"}
                class="tabular-nums"
                phx-hook=".Elapsed"
                phx-update="ignore"
                data-started-at={@card.started_at}
                title="Time since the turn started"
              />
              <.chevron open?={@open?} />
            </span>
          </span>
          <span class="flex w-full min-w-0 items-center gap-2 text-[11px] text-base-content/60">
            <span
              :if={@current && !@waiting?}
              class="min-w-0 truncate font-mono sm:hidden"
            >
              {relative_paths(@current.label, @root)}
            </span>
            <span class="min-w-0 truncate max-sm:hidden">{tally_text(@card)}</span>
            <span class="sm:hidden">{short_tally(@card)}</span>
            <span class="ml-auto flex shrink-0 items-center gap-2">
              <span :if={@card.tokens > 0}>{format_tokens(@card.tokens)} tok</span>
              <span :if={@card.cost > 0}>{format_cost(@card.cost)}</span>
              <span :if={@card.model} class="max-sm:hidden">{@card.model}</span>
            </span>
          </span>
        </button>
        <.link
          :if={@channel_id}
          patch={~p"/channels/#{@channel_id}?#{[activity: "live:" <> @agent_id]}"}
          id={"telemetry-#{@agent_id}-panel"}
          class="btn btn-ghost btn-xs btn-square shrink-0 focus-visible:ring-2 focus-visible:ring-primary/50"
          title="Open in panel"
          aria-label="Open the activity in the side panel"
        >
          <.icon name="hero-arrows-pointing-out-mini" class="size-4" />
        </.link>
      </div>
      <span class="sr-only" aria-live="polite">
        {if @waiting?, do: "@#{@name} is waiting for you", else: "@#{@name} is #{@verb}"}
      </span>
      <div
        :if={@question}
        id={"question-#{@question.id}"}
        data-detached="false"
        class="border-t border-info/20"
      >
        <.question_form request={@question} draft={@draft} />
      </div>
      <div
        :if={@steer}
        id={"steer-chip-#{@agent_id}"}
        class="flex items-center gap-2 border-t border-secondary/20 px-4 py-1.5 text-xs text-base-content/70"
      >
        <.icon name="hero-forward-mini" class="size-4 shrink-0 text-secondary" />
        <span class="min-w-0 truncate">
          <%= cond do %>
            <% @steer.held == @steer.pending -> %>
              Your {if @steer.pending == 1, do: "message", else: "#{@steer.pending} messages"} reach @{@name} once the card is answered
            <% @current -> %>
              Interrupting after current step:
              <span class="font-mono">{relative_paths(@current.label, @root)}</span>
            <% true -> %>
              Interrupting after current step
          <% end %>
          <span :if={@steer.pending > 1 and @steer.held != @steer.pending}>
            · {@steer.pending} messages
          </span>
        </span>
        <button
          type="button"
          id={"interrupt-now-#{@agent_id}"}
          class="btn btn-ghost btn-xs ml-auto shrink-0 text-warning"
          phx-click="interrupt_now"
          phx-value-agent-id={@agent_id}
          title="Stop the current step now and read your message"
        >
          Interrupt now
        </button>
      </div>
      <.activity_body
        :if={@open?}
        id={"telemetry-#{@agent_id}"}
        card_id={"telemetry-#{@agent_id}"}
        card={@card}
        live?
        open_rows={@open_rows}
        details={@card.details}
        root={@root}
        auto_open?={@auto_open?}
        class="border-t border-secondary/20"
      />
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Elapsed">
      // Ticks a live duration from data-started-at (wall-clock ms) once a second.
      const format = ms => {
        const s = Math.max(0, Math.floor(ms / 1000))
        return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
      }
      export default {
        mounted() {
          this.tick = () => {
            const at = Number(this.el.dataset.startedAt)
            if (at) this.el.textContent = format(Date.now() - at)
          }
          this.tick()
          this.timer = setInterval(this.tick, 1000)
        },
        updated() { this.tick() },
        destroyed() { clearInterval(this.timer) },
      }
    </script>
    """
  end

  @doc """
  A finished turn: the same box as the live card, quieter, with the summary
  line as its header. Opening it shows the rows the live card held and the
  turn's closing note; a row opens to its input and output. Falls back to a
  plain line when nothing was recorded.

  `activity` carries the view's state for the card (all optional): `open?`,
  `open_rows` (the keys of the rows shown open), `details` (the rows'
  details once loaded, or `:not_recorded`), and `highlight` (shown in the
  side panel).
  """
  attr :event, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :card, :map, required: true
  attr :final_text, :string, default: nil
  attr :root, :string, default: nil
  attr :mentions, :any, default: MapSet.new()
  attr :activity, :map, default: %{}

  def turn_card(assigns) do
    if Enum.any?(assigns.card.entries, &(&1.kind != :step)) or assigns.final_text do
      turn_box(assigns)
    else
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
  end

  defp turn_box(assigns) do
    open? = assigns.activity[:open?] == true

    assigns =
      assigns
      |> assign(:tone, event_tone(assigns.event))
      |> assign(:open?, open?)
      |> assign(
        :header_note,
        header_note(assigns.event.payload, assigns.card, assigns.final_text)
      )
      |> assign(:text, event_text(assigns.event, assigns.names, assigns.user_name))

    ~H"""
    <section
      id={"turn-#{@event.id}"}
      class={[
        "mx-3 my-1 overflow-hidden rounded-xl border transition sm:mx-6",
        @tone == "error" && "border-error/30 bg-error/5",
        @tone != "error" && !@open? && "border-base-300/70 bg-base-200/40",
        @tone != "error" && @open? && "border-base-300 bg-base-200/40",
        @activity[:highlight] && "ring-2 ring-primary/30"
      ]}
      data-tone={@tone}
      data-open={to_string(@open?)}
    >
      <div class={["flex items-center gap-1 pr-2", @open? && "sticky top-0 z-10 bg-inherit"]}>
        <button
          type="button"
          id={"turn-toggle-#{@event.id}"}
          class="flex min-w-0 flex-1 items-center gap-2 rounded-xl px-4 py-1.5 text-left text-xs transition hover:bg-base-300/30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          phx-click="toggle_activity_card"
          phx-value-card={"turn-#{@event.id}"}
          aria-expanded={to_string(@open?)}
          aria-controls={"turn-#{@event.id}-body"}
          title={@text}
        >
          <.icon
            name={outcome_icon(@event.payload)}
            class={["size-4 shrink-0", outcome_class(@event.payload)]}
          />
          <span class={[
            "min-w-0 truncate",
            @tone == "error" && "text-error",
            @tone != "error" && "text-base-content/70"
          ]}>
            {@text}
          </span>
          <span
            :if={@event.payload["profile"] == "light"}
            id={"turn-#{@event.id}-light"}
            class="badge badge-info badge-soft badge-xs shrink-0"
            title={"Ran on the agent's light model (model routing): #{@event.payload["model"]}"}
          >
            light model
          </span>
          <%= case @header_note do %>
            <% {:error, quote} -> %>
              <span
                id={"turn-#{@event.id}-first-error"}
                class="min-w-0 truncate font-mono text-[11px] text-error max-md:hidden"
              >
                “{quote}”
              </span>
            <% {:note, note, errors} -> %>
              <span
                id={"turn-#{@event.id}-note"}
                class="min-w-0 truncate text-[11px] text-base-content/60 max-md:hidden"
              >
                {note}
              </span>
              <.error_count_chip :if={errors > 0} id={"turn-#{@event.id}-errors"} count={errors} />
            <% {:last_error, quote, errors} -> %>
              <span
                id={"turn-#{@event.id}-last-error"}
                class="min-w-0 truncate font-mono text-[11px] text-base-content/60 max-md:hidden"
              >
                {quote}
              </span>
              <.error_count_chip id={"turn-#{@event.id}-errors"} count={errors} />
            <% nil -> %>
          <% end %>
          <span class="ml-auto flex shrink-0 items-center gap-2 text-[10px] text-base-content/55">
            <time title={DateTime.to_iso8601(@event.inserted_at)}>
              {short_time(@event.inserted_at)}
            </time>
            <.chevron open?={@open?} />
          </span>
        </button>
        <.link
          patch={~p"/channels/#{@event.channel_id}?#{[activity: @event.id]}"}
          id={"turn-#{@event.id}-panel"}
          class="btn btn-ghost btn-xs btn-square shrink-0 focus-visible:ring-2 focus-visible:ring-primary/50"
          title="Open in panel"
          aria-label="Open the activity in the side panel"
        >
          <.icon name="hero-arrows-pointing-out-mini" class="size-4" />
        </.link>
      </div>
      <.activity_body
        :if={@open?}
        id={"turn-#{@event.id}"}
        card_id={"turn-#{@event.id}"}
        card={@card}
        open_rows={@activity[:open_rows] || MapSet.new()}
        details={@activity[:details]}
        root={@root}
        final_text={@final_text}
        mentions={@mentions}
        class="border-t border-base-300/70"
      />
      <div
        :if={@open? and @event.agent_id}
        class="flex justify-end border-t border-base-300/70 px-4 py-1"
      >
        <.link
          navigate={
            ~p"/channels/#{@event.channel_id}/agents/#{@event.agent_id}/transcript?#{[turn: @event.id]}"
          }
          id={"turn-#{@event.id}-transcript"}
          class="link link-hover text-[11px] text-base-content/60"
        >
          View in transcript →
        </.link>
      </div>
    </section>
    """
  end

  @doc """
  The open part of an activity card, shared by the live card, the finished
  card, and the side panel: the filter bar (category chips with counts, a
  text filter, and on a live card Follow), the rows grouped by model step,
  the changed files as chips that open their diff, and the closing note.
  Filtering, searching and following happen in the browser (the
  `.ActivityFilter` and `.ActivityFollow` hooks), so new rows arriving
  while a filter is set are filtered too.

  `id` prefixes every id inside; `card_id` is what the toggle events name
  (`telemetry-<agent>` or `turn-<event>`), the same in the feed and the panel.
  """
  attr :id, :string, required: true
  attr :card_id, :string, required: true
  attr :card, :map, required: true
  attr :live?, :boolean, default: false
  attr :open_rows, :any, default: MapSet.new()
  attr :details, :any, default: nil, doc: "row key => details, or :not_recorded"
  attr :root, :string, default: nil
  attr :final_text, :string, default: nil
  attr :mentions, :any, default: MapSet.new()
  attr :panel?, :boolean, default: false, doc: "full height, in the side panel"
  attr :auto_open?, :boolean, default: false
  attr :class, :any, default: nil

  def activity_body(assigns) do
    items = activity_items(assigns.card)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:early, Enum.count(items, &(&1.early? and &1.type == :row)))
      |> assign(:counts, filter_counts(assigns.card))

    ~H"""
    <div
      id={"#{@id}-body"}
      class={["activity-body", @class]}
      phx-hook=".ActivityFilter"
      data-filter="all"
    >
      <div
        id={"#{@id}-filters"}
        class="flex flex-wrap items-center gap-1 border-b border-base-300/60 px-3 py-1.5 text-[11px]"
      >
        <button
          :for={{filter, label} <- filter_chips()}
          :if={filter == "all" or Map.get(@counts, filter, 0) > 0}
          type="button"
          id={"#{@id}-filter-#{filter}"}
          data-filter-chip={filter}
          aria-pressed={to_string(filter == "all")}
          class="activity-chip rounded-full px-2 py-0.5 font-medium text-base-content/60 transition hover:bg-base-300/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
        >
          {label} <span class="tabular-nums opacity-70">{Map.get(@counts, filter, 0)}</span>
        </button>
        <label class="ml-auto flex min-w-0 items-center gap-1 rounded-md border border-base-300/70 bg-base-100/60 px-1.5 focus-within:ring-2 focus-within:ring-primary/50">
          <.icon name="hero-magnifying-glass-mini" class="size-3.5 shrink-0 text-base-content/50" />
          <input
            type="search"
            id={"#{@id}-search"}
            data-filter-search
            placeholder="Filter…"
            aria-label="Filter the rows"
            autocomplete="off"
            class="w-24 min-w-0 bg-transparent py-0.5 text-[11px] outline-none sm:w-32"
          />
        </label>
        <span :if={@live?} id={"#{@id}-follow-wrap"} phx-update="ignore">
          <button
            type="button"
            id={"#{@id}-follow"}
            aria-pressed="true"
            class="activity-chip flex items-center gap-1 rounded-full px-2 py-0.5 font-medium text-base-content/60 transition hover:bg-base-300/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            title="Keep the newest row in view"
          >
            <.icon name="hero-arrow-down-circle-mini" class="size-3.5" /> Follow
          </button>
        </span>
        <label
          :if={@live? and not @panel?}
          for={"#{@id}-auto-open"}
          class="flex cursor-pointer items-center gap-1 text-base-content/55"
          title="Open the live activity card whenever an agent starts working (this browser)"
        >
          <input
            type="checkbox"
            id={"#{@id}-auto-open"}
            class="checkbox checkbox-xs"
            checked={@auto_open?}
            phx-click="toggle_auto_open_live"
          /> Open automatically
        </label>
      </div>

      <div
        id={"#{@id}-scroll"}
        class={["relative overflow-y-auto px-3 py-2", !@panel? && "max-h-[60vh]"]}
        phx-hook=".ActivityFollow"
        data-live={to_string(@live?)}
        data-pill={"#{@id}-pill"}
        data-follow={"#{@id}-follow"}
      >
        <p
          :if={@card.dropped > 0}
          id={"#{@id}-dropped"}
          class="mb-1 px-1 text-[11px] text-base-content/55"
        >
          ⋯ {ngettext("1 earlier row not kept", "%{count} earlier rows not kept", @card.dropped)} (the turn ran {ngettext(
            "1 call",
            "%{count} calls",
            @card.tool_count
          )})
        </p>
        <button
          :if={@early > 0}
          type="button"
          id={"#{@id}-earlier"}
          class="activity-earlier mb-1 rounded-md px-1 text-[11px] font-medium text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          phx-click={
            JS.set_attribute({"data-expanded", "true"}, to: "##{@id}-body")
            |> JS.hide()
          }
        >
          Show {ngettext("1 earlier row", "%{count} earlier rows", @early)}
        </button>
        <ol id={"#{@id}-rows"} class="flex flex-col gap-px">
          <li
            :for={item <- @items}
            :key={item.key}
            id={"#{@id}-#{dom_key(item.key)}"}
            class={[item.early? && "activity-early"]}
            data-step-divider={item.type == :divider && "true"}
            data-row={item.type == :row && "true"}
            data-kind={item.type == :row && item.entry.kind}
            data-category={item.type == :row && item.entry.category}
            data-status={item.type == :row && row_status(item.entry)}
            data-search={item.type == :row && search_text(item.entry, @root)}
          >
            <p
              :if={item.type == :divider}
              class="mt-2 mb-0.5 px-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/50"
            >
              Step {item.step + 1}<span :if={item.tokens > 0}> · {format_tokens(item.tokens)} tok</span>
            </p>
            <.narration
              :if={item.type == :row and item.entry.kind == :text}
              id={"#{@id}-#{dom_key(item.key)}"}
              entry={item.entry}
              mentions={@mentions}
            />
            <.activity_row
              :if={item.type == :row and item.entry.kind != :text}
              id={"#{@id}-#{dom_key(item.key)}"}
              card_id={@card_id}
              entry={item.entry}
              open?={MapSet.member?(@open_rows, item.entry.key)}
              details={row_details(@details, item.entry.key)}
              root={@root}
            />
          </li>
        </ol>
        <p :if={@items == []} id={"#{@id}-empty"} class="px-1 text-xs text-base-content/60">
          {if @live?, do: "Waiting for the first tool call…", else: "No calls."}
        </p>

        <div
          :if={@card.files != []}
          id={"#{@id}-files"}
          class="mt-2 flex flex-wrap items-center gap-1.5 border-t border-dashed border-base-300 pt-2 text-[11px]"
        >
          <span class="font-semibold uppercase tracking-wider text-base-content/55">Changed</span>
          <button
            :for={chip <- @card.files}
            type="button"
            id={"#{@id}-chip-#{:erlang.phash2(chip.path)}"}
            class="flex max-w-56 items-center gap-1 rounded-md border border-base-300 bg-base-100/70 px-1.5 py-0.5 font-mono transition hover:border-primary/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            phx-click="open_changes"
            phx-value-path={relative_paths(chip.path, @root)}
            title={"See the diff of " <> relative_paths(chip.path, @root)}
          >
            <.icon name="hero-pencil-square-mini" class="size-3 shrink-0 text-warning" />
            <span class="truncate">{Path.basename(chip.path)}</span>
            <.line_counts stats={Activity.chip_stats(chip)} />
          </button>
          <button
            type="button"
            id={"#{@id}-open-changes"}
            class="ml-auto font-medium text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            phx-click="open_changes"
          >
            Open Changes ›
          </button>
        </div>
        <div
          :if={@final_text}
          id={"#{@id}-note"}
          class={[
            "border-t border-dashed border-base-300 pt-2",
            (@items != [] or @card.files != []) && "mt-2"
          ]}
        >
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/60">
            Closing note
          </p>
          <div class="text-sm"><.message_text body={@final_text} mentions={@mentions} /></div>
        </div>
      </div>
      <div :if={@live?} id={"#{@id}-pill-wrap"} phx-update="ignore" class="relative">
        <button
          type="button"
          id={"#{@id}-pill"}
          hidden
          class="absolute bottom-2 left-1/2 -translate-x-1/2 rounded-full bg-primary px-3 py-1 text-[11px] font-medium text-primary-content shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
        >
          ↓ new rows
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ActivityFilter">
      // The filter bar of an activity card: a category chip and a text filter,
      // both applied in the browser. The chip is kept as data-filter on this
      // element (CSS hides what it excludes) and the text as a class on the
      // rows that miss it; both are set through LiveView's JS commands, so
      // patches keep them, and rows that arrive later are filtered too.
      export default {
        mounted() {
          this.filter = "all"
          this.query = ""
          this.el.addEventListener("click", e => {
            const chip = e.target.closest("[data-filter-chip]")
            if (!chip || !this.el.contains(chip)) return
            this.filter = chip.dataset.filterChip
            this.apply()
          })
          this.el.addEventListener("input", e => {
            if (!e.target.matches("[data-filter-search]")) return
            this.query = e.target.value.trim().toLowerCase()
            this.apply()
          })
          // Esc in the filter box clears it, and goes no further (the side
          // panel would close)
          this.el.addEventListener("keydown", e => {
            if (e.key !== "Escape" || !e.target.matches("[data-filter-search]")) return
            if (e.target.value === "") return
            e.preventDefault()
            e.stopPropagation()
            e.target.value = ""
            this.query = ""
            this.apply()
          })
          this.observer = new MutationObserver(() => this.applyRows())
          const rows = this.el.querySelector("ol")
          if (rows) this.observer.observe(rows, {childList: true})
          this.apply()
        },
        updated() { this.apply() },
        destroyed() { this.observer.disconnect() },
        apply() {
          const js = this.js()
          js.setAttribute(this.el, "data-filter", this.filter)
          if (this.query) js.setAttribute(this.el, "data-searching", "true")
          else js.removeAttribute(this.el, "data-searching")
          this.el.querySelectorAll("[data-filter-chip]").forEach(chip => {
            js.setAttribute(chip, "aria-pressed", String(chip.dataset.filterChip === this.filter))
          })
          this.applyRows()
        },
        applyRows() {
          const js = this.js()
          this.el.querySelectorAll("[data-row]").forEach(row => {
            const miss = this.query !== "" && !(row.dataset.search || "").toLowerCase().includes(this.query)
            if (miss && !row.classList.contains("activity-miss")) js.addClass(row, "activity-miss")
            if (!miss && row.classList.contains("activity-miss")) js.removeClass(row, "activity-miss")
          })
        },
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ActivityFollow">
      // Follow on a live card: while on, new rows keep the list scrolled to the
      // newest one. Scrolling up turns it off and counts what arrives in a
      // "new rows" pill; the pill, the Follow chip, or scrolling back down
      // turns it on again. The pill and the chip sit in phx-update="ignore"
      // wrappers, so their state here survives patches.
      const NEAR = 24
      export default {
        mounted() {
          this.live = this.el.dataset.live === "true"
          if (!this.live) return
          this.pill = document.getElementById(this.el.dataset.pill)
          this.chip = document.getElementById(this.el.dataset.follow)
          this.following = true
          this.pinning = false
          this.seen = this.rowCount()
          this.el.addEventListener("scroll", () => {
            if (this.pinning) return
            const near = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < NEAR
            if (near && !this.following) this.setFollowing(true)
            else if (!near && this.following) this.setFollowing(false)
          })
          if (this.pill) this.pill.addEventListener("click", () => { this.setFollowing(true); this.pin() })
          if (this.chip) this.chip.addEventListener("click", () => {
            this.setFollowing(!this.following)
            if (this.following) this.pin()
          })
          this.observer = new MutationObserver(() => this.onRows())
          this.observer.observe(this.el, {childList: true, subtree: true})
          this.pin()
        },
        destroyed() { if (this.observer) this.observer.disconnect() },
        rowCount() { return this.el.querySelectorAll("[data-row]").length },
        onRows() {
          const count = this.rowCount()
          if (this.following) { this.seen = count; this.pin(); return }
          const fresh = count - this.seen
          if (this.pill && fresh > 0) {
            this.pill.textContent = `↓ ${fresh} new ${fresh === 1 ? "row" : "rows"}`
            this.pill.hidden = false
          }
        },
        setFollowing(on) {
          this.following = on
          if (this.chip) this.chip.setAttribute("aria-pressed", String(on))
          if (on) {
            this.seen = this.rowCount()
            if (this.pill) this.pill.hidden = true
          }
        },
        pin() {
          this.pinning = true
          this.el.scrollTop = this.el.scrollHeight
          requestAnimationFrame(() => {
            this.el.scrollTop = this.el.scrollHeight
            this.pinning = false
          })
        },
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :mentions, :any, default: MapSet.new()

  # The agent's own words between tool calls: Markdown once the part is
  # done (plain while it streams, so it doesn't reflow), clamped to three
  # lines with a client-side "more".
  defp narration(assigns) do
    assigns = assign(assigns, :long?, long_text?(assigns.entry.label))

    ~H"""
    <div class="flex items-start gap-2 px-1 py-1">
      <.icon
        name="hero-chat-bubble-bottom-center-text-mini"
        class={[
          "mt-0.5 size-3.5 shrink-0",
          @entry.status == :running && "text-secondary",
          @entry.status != :running && "text-secondary/60"
        ]}
      />
      <div class="min-w-0 flex-1">
        <div id={"#{@id}-text"} class="line-clamp-3 text-xs leading-relaxed text-base-content/80">
          <%= if @entry.status == :running do %>
            <p class="whitespace-pre-wrap break-words">{@entry.label}</p>
          <% else %>
            <.message_text body={@entry.label} mentions={@mentions} />
          <% end %>
        </div>
        <button
          :if={@long?}
          type="button"
          id={"#{@id}-more"}
          class="text-[11px] font-medium text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          phx-click={JS.toggle_class("line-clamp-3", to: "##{@id}-text")}
        >
          more
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :card_id, :string, required: true
  attr :entry, :map, required: true
  attr :open?, :boolean, default: false
  attr :details, :any, default: nil
  attr :root, :string, default: nil

  # One call: what ran, whether it worked, how long it took. The row is a
  # button that opens its detail.
  defp activity_row(assigns) do
    entry = assigns.entry

    {label, detail} =
      path_label(
        relative_paths(entry.label, assigns.root),
        relative_paths(entry.detail, assigns.root)
      )

    detail = if redundant_detail?(label, detail), do: nil, else: detail

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:detail, detail)
      |> assign(:status, row_status(entry))
      |> assign(:chip, tool_chip(entry))

    ~H"""
    <button
      type="button"
      id={"#{@id}-toggle"}
      class={[
        "flex w-full min-w-0 items-center gap-2 rounded-md px-1 py-0.5 text-left font-mono text-xs transition hover:bg-base-300/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50",
        @status == "error" && "bg-error/5",
        @entry[:category] == :canopy && "text-base-content/60"
      ]}
      phx-click="toggle_activity_row"
      phx-value-card={@card_id}
      phx-value-key={@entry.key}
      aria-expanded={to_string(@open?)}
      aria-controls={"#{@id}-detail"}
      title={@entry[:command] || @label}
    >
      <.icon
        name={category_icon(@entry)}
        class={["size-3.5 shrink-0", category_class(@entry)]}
      />
      <span
        :if={@chip}
        class="shrink-0 rounded bg-base-300/60 px-1 text-[10px] font-semibold text-base-content/70"
      >
        {@chip}
      </span>
      <span class={[
        "min-w-0 flex-1 truncate",
        @status == "error" && "text-error",
        @status != "error" && "text-base-content"
      ]}>
        {@label}<span :if={@detail} class="text-base-content/60"> — {@detail}</span>
      </span>
      <span
        :if={@entry[:fact]}
        class={[
          "shrink-0 text-[11px]",
          @status == "error" && "text-error",
          @status != "error" && "text-base-content/60"
        ]}
      >
        {@entry[:fact]}
      </span>
      <.status_glyph status={@status} />
      <span class="w-12 shrink-0 text-right text-[11px] tabular-nums text-base-content/55">
        <span
          :if={@entry.status == :running and is_integer(@entry[:started_at])}
          id={"#{@id}-elapsed"}
          phx-hook=".Elapsed"
          phx-update="ignore"
          data-started-at={@entry[:started_at]}
        />
        <span :if={@entry.status != :running}>{format_duration(@entry[:duration_ms])}</span>
      </span>
    </button>
    <.row_detail :if={@open?} id={@id} entry={@entry} details={@details} root={@root} />
    """
  end

  attr :status, :string, required: true

  defp status_glyph(%{status: "running"} = assigns) do
    ~H"""
    <span class="shrink-0" title="running">
      <.icon
        name="hero-arrow-path-mini"
        class="size-3.5 animate-spin text-success motion-reduce:animate-none"
      />
      <span class="sr-only">running</span>
    </span>
    """
  end

  defp status_glyph(%{status: "error"} = assigns) do
    ~H"""
    <span class="shrink-0" title="failed">
      <.icon name="hero-x-mark-mini" class="size-3.5 text-error" />
      <span class="sr-only">failed</span>
    </span>
    """
  end

  defp status_glyph(%{status: "denied"} = assigns) do
    ~H"""
    <span class="shrink-0" title="denied">
      <.icon name="hero-shield-exclamation-mini" class="size-3.5 text-warning" />
      <span class="sr-only">denied</span>
    </span>
    """
  end

  defp status_glyph(assigns) do
    ~H"""
    <span class="shrink-0" title="done">
      <.icon name="hero-check-mini" class="size-3.5 text-base-content/35" />
      <span class="sr-only">done</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :details, :any, default: nil
  attr :root, :string, default: nil

  # What an opened row shows, by category: the error first, then the full
  # command and its output for a shell call, the patch for an edit, the
  # input and output otherwise. Outputs are excerpts (head and tail), never
  # highlighted; Copy copies what is shown.
  defp row_detail(assigns) do
    details = if is_map(assigns.details), do: assigns.details, else: %{}
    entry = assigns.entry

    assigns =
      assigns
      |> assign(:d, details)
      |> assign(:not_recorded?, assigns.details == :not_recorded)
      |> assign(
        :show_input?,
        entry[:category] not in [:canopy, :edit] and is_binary(details["input"])
      )
      |> assign(:show_output?, entry[:category] != :read and is_binary(details["output"]))
      |> assign(:provenance, provenance(entry))

    ~H"""
    <div
      id={"#{@id}-detail"}
      class="mb-1 ml-5 mt-0.5 flex flex-col gap-2 rounded-lg border border-base-300 bg-base-100/70 p-2 text-xs"
    >
      <p :if={@not_recorded?} class="text-base-content/60">
        Details weren't recorded for turns before this version of Canopy.
      </p>
      <p :if={@entry[:denied]} class="flex items-center gap-1 text-warning">
        <.icon name="hero-shield-exclamation-mini" class="size-3.5" />
        The call was refused, so it never ran.
      </p>
      <.detail_block
        :if={@d["error"]}
        id={"#{@id}-error"}
        title="Error"
        text={@d["error"]}
        tone="error"
      />
      <.detail_block
        :if={@show_input?}
        id={"#{@id}-command"}
        title={if @entry[:category] == :shell, do: "Command", else: "Input"}
        text={relative_paths(@d["input"], @root)}
        copy
      />
      <p
        :if={@entry[:category] == :shell and @entry[:description]}
        class="-mt-1 text-[11px] text-base-content/60"
      >
        {@entry[:description]}
      </p>
      <p :if={@entry[:category] == :read and @entry[:path]} class="font-mono text-[11px]">
        {relative_paths(@entry[:path], @root)}
      </p>
      <div :if={@entry[:category] == :edit and @d["patch"]}>
        <.diff_view
          id={"#{@id}-diff"}
          diff={relative_paths(@d["patch"], @root)}
          class="max-h-72 rounded-md bg-base-200/60 py-1"
        />
      </div>
      <button
        :if={@entry[:category] == :edit and @entry[:path]}
        type="button"
        id={"#{@id}-changes"}
        class="self-start text-[11px] font-medium text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
        phx-click="open_changes"
        phx-value-path={relative_paths(@entry[:path], @root)}
      >
        Open in Changes ›
      </button>
      <.detail_block
        :if={@show_output?}
        id={"#{@id}-output"}
        title={output_title(@d)}
        text={@d["output"]}
        copy
        copy_label={if @d["truncated"], do: "Copy (excerpt)", else: "Copy"}
      />
      <.detail_block
        :if={@d["stderr"]}
        id={"#{@id}-stderr"}
        title="Stderr"
        text={@d["stderr"]}
        tone="warning"
        copy
      />
      <p :if={@d["interrupted"]} class="text-warning">The command was interrupted.</p>
      <p
        :if={!@not_recorded? and @d == %{} and @entry.status != :running and !@entry[:denied]}
        class="text-base-content/60"
      >
        Nothing was recorded for this call.
      </p>
      <p :if={@entry.status == :running and @d == %{}} class="text-base-content/60">Running…</p>
      <p :if={@provenance} class="text-[10px] text-base-content/50">{@provenance}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true
  attr :tone, :string, default: nil
  attr :copy, :boolean, default: false
  attr :copy_label, :string, default: "Copy"

  defp detail_block(assigns) do
    ~H"""
    <div>
      <div class="mb-0.5 flex items-center gap-2">
        <span class={[
          "text-[10px] font-semibold uppercase tracking-wider",
          @tone == "error" && "text-error",
          @tone == "warning" && "text-warning",
          is_nil(@tone) && "text-base-content/55"
        ]}>
          {@title}
        </span>
        <button
          :if={@copy}
          type="button"
          id={"#{@id}-copy"}
          class="ml-auto flex items-center gap-1 rounded px-1 text-[10px] text-base-content/60 transition hover:bg-base-300/60 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          phx-click={JS.dispatch("canopy:copy", to: "##{@id}-text", detail: %{button: "#{@id}-copy"})}
        >
          <.icon name="hero-clipboard-document-mini" class="size-3" />
          <span data-copy-label>{@copy_label}</span>
        </button>
      </div>
      <pre
        id={"#{@id}-text"}
        class={[
          "max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md px-2 py-1 font-mono text-[11px] leading-relaxed",
          @tone == "error" && "bg-error/10 text-error",
          @tone == "warning" && "bg-warning/10",
          is_nil(@tone) && "bg-base-300/50"
        ]}
      >{@text}</pre>
    </div>
    """
  end

  attr :stats, :any, required: true

  defp line_counts(%{stats: {_a, _d}} = assigns) do
    ~H"""
    <span class="shrink-0 tabular-nums">
      <span class="text-success">+{elem(@stats, 0)}</span>
      <span class="text-error">−{elem(@stats, 1)}</span>
    </span>
    """
  end

  defp line_counts(assigns), do: ~H""

  attr :open?, :boolean, default: false

  defp chevron(assigns) do
    ~H"""
    <.icon
      name="hero-chevron-down-mini"
      class={["size-4 shrink-0 opacity-60 transition-transform", @open? && "rotate-180"]}
    />
    """
  end

  # The rows of a card in order, with a divider before each model step when
  # there is more than one. Past 150 rows the earlier complete steps start
  # collapsed ("Show N earlier rows").
  @collapse_above 150
  @keep_open 120

  @doc false
  def activity_items(card) do
    rows = Enum.reject(card.entries, &(&1.kind == :step))
    steps = rows |> Enum.map(&Map.get(&1, :step, 0)) |> Enum.uniq()
    dividers? = length(steps) > 1

    tokens =
      card.steps |> Enum.map(& &1.tokens) |> Enum.with_index() |> Map.new(fn {t, i} -> {i, t} end)

    groups = Enum.chunk_by(rows, &Map.get(&1, :step, 0))
    early = early_groups(groups)

    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {[first | _] = group, index} ->
      step = Map.get(first, :step, 0)
      early? = index < early

      divider =
        if dividers?,
          do: [
            %{
              type: :divider,
              key: "step-#{index}-#{step}",
              step: step,
              tokens: Map.get(tokens, step, 0),
              early?: early?
            }
          ],
          else: []

      divider ++ Enum.map(group, &%{type: :row, key: &1.key, entry: &1, early?: early?})
    end)
  end

  # How many leading groups start collapsed: whole steps, never the last,
  # while at least @keep_open rows stay shown.
  defp early_groups(groups) do
    total = groups |> Enum.map(&length/1) |> Enum.sum()

    if total <= @collapse_above do
      0
    else
      groups
      |> Enum.drop(-1)
      |> Enum.reduce_while({0, total}, fn group, {count, shown} ->
        if shown - length(group) >= @keep_open,
          do: {:cont, {count + 1, shown - length(group)}},
          else: {:halt, {count, shown}}
      end)
      |> elem(0)
    end
  end

  defp filter_chips do
    [
      {"all", "All"},
      {"shell", "Commands"},
      {"files", "Files"},
      {"errors", "Errors"},
      {"notes", "Notes"},
      {"canopy", "Canopy"}
    ]
  end

  # The chips count from the card's tallies, so they stay exact past the row cap.
  defp filter_counts(card) do
    t = card.tallies

    %{
      "all" => Enum.count(card.entries, &(&1.kind not in [:step])) + card.dropped,
      "shell" => Map.get(t, :shell, 0),
      "files" => Map.get(t, :read, 0) + Map.get(t, :search, 0) + Map.get(t, :edit, 0),
      "errors" => Map.get(t, :errors, 0),
      "notes" => Enum.count(card.entries, &(&1.kind == :text)),
      "canopy" => Map.get(t, :canopy, 0)
    }
  end

  defp row_details(:not_recorded, _key), do: :not_recorded
  defp row_details(details, key) when is_map(details), do: Map.get(details, key, %{})
  defp row_details(_details, _key), do: nil

  defp row_status(%{status: :running}), do: "running"
  defp row_status(%{denied: true}), do: "denied"
  defp row_status(%{status: :error}), do: "error"
  defp row_status(_entry), do: "ok"

  defp search_text(entry, root) do
    [
      entry.label,
      entry[:command],
      entry[:path],
      entry[:description],
      entry[:fact],
      entry[:detail]
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&relative_paths(&1, root))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp long_text?(text), do: String.length(text) > 240 or length(String.split(text, "\n")) > 3

  defp output_title(details) do
    case details["output_lines"] do
      n when is_integer(n) and n > 1 ->
        "Output · " <>
          ngettext("1 line", "%{count} lines", n) <>
          if(details["truncated"], do: ", excerpt", else: "")

      _ ->
        "Output"
    end
  end

  # When the call started, how long it took, how it ended.
  defp provenance(entry) do
    [
      if(is_integer(entry[:started_at]), do: "started " <> clock(entry[:started_at])),
      format_duration(entry[:duration_ms]),
      if(is_integer(entry[:exit_code]), do: "exit #{entry[:exit_code]}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp clock(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Canopy.Schedules.When.to_local_naive()
    |> Calendar.strftime("%H:%M:%S")
  end

  # What a finished card's header adds after its summary. A turn that ended
  # in an error quotes its first failed call in red. A turn that ended well
  # never shows red: when some calls failed on the way it shows the closing
  # note, or failing that the last failed call, muted, with a count chip.
  defp header_note(payload, card, final_text) do
    failed = Enum.filter(card.entries, &(&1.kind == :tool and &1.status == :error))

    cond do
      failed == [] ->
        nil

      payload["outcome"] == "error" ->
        {:error, error_quote(hd(failed))}

      payload["outcome"] != "ok" ->
        nil

      (note = closing_note(final_text)) != nil ->
        {:note, note, length(failed)}

      true ->
        {:last_error, error_quote(List.last(failed)), length(failed)}
    end
  end

  defp error_quote(%{fact: "exit " <> _ = fact, label: label}),
    do: "#{fact}: #{truncate(label, 60)}"

  defp error_quote(%{label: label}), do: truncate(label, 60)

  defp closing_note(text) when is_binary(text) do
    case text |> CanopyWeb.Markdown.plain() |> String.trim() do
      "" -> nil
      plain -> truncate(plain, 120)
    end
  end

  defp closing_note(_text), do: nil

  attr :id, :string, required: true
  attr :count, :integer, required: true

  defp error_count_chip(assigns) do
    ~H"""
    <span
      id={@id}
      class="badge badge-ghost badge-xs shrink-0 text-base-content/60"
      title="Calls that failed along the way; the turn still finished"
    >
      {ngettext("1 error", "%{count} errors", @count)}
    </span>
    """
  end

  defp outcome_icon(%{"outcome" => "error"}), do: "hero-x-circle-mini"
  defp outcome_icon(%{"outcome" => "stopped"}), do: "hero-stop-circle-mini"
  defp outcome_icon(%{"outcome" => "interrupted"}), do: "hero-forward-mini"
  defp outcome_icon(_payload), do: "hero-check-circle-mini"

  defp outcome_class(%{"outcome" => "error"}), do: "text-error"

  defp outcome_class(%{"outcome" => outcome}) when outcome in ["stopped", "interrupted"],
    do: "text-base-content/50"

  # a pass keeps the check, in grey: nothing went wrong, nothing was said
  defp outcome_class(%{"passed" => true}), do: "text-base-content/50"

  defp outcome_class(_payload), do: "text-success/70"

  @tally_nouns [
    shell: {"cmd", "cmds"},
    read: {"read", "reads"},
    search: {"search", "searches"},
    edit: {"edit", "edits"},
    web: {"fetch", "fetches"},
    agent: {"subagent", "subagents"},
    plan: {"plan update", "plan updates"},
    other: {"other call", "other calls"},
    canopy: {"Canopy call", "Canopy calls"}
  ]

  @doc false
  # "7 cmds · 5 reads · 2 edits · 1 failed", from the card's tallies.
  def tally_text(card) do
    parts =
      for {category, {one, many}} <- @tally_nouns,
          n = Map.get(card.tallies, category, 0),
          n > 0,
          do: "#{n} #{if n == 1, do: one, else: many}"

    errors = Map.get(card.tallies, :errors, 0)
    parts = if errors > 0, do: parts ++ ["#{errors} failed"], else: parts
    Enum.join(parts, " · ")
  end

  # The narrow header: calls, and failures if any ("14 · 1 ✕").
  defp short_tally(%{tool_count: 0}), do: nil

  defp short_tally(card) do
    case Map.get(card.tallies, :errors, 0) do
      0 -> "#{card.tool_count}"
      errors -> "#{card.tool_count} · #{errors} ✕"
    end
  end

  @doc false
  def format_tokens(n) when is_integer(n) and n >= 1000,
    do: :erlang.float_to_binary(n / 1000, decimals: 1) <> "k"

  def format_tokens(n), do: to_string(n)

  @doc false
  def tool_chip(%{category: :shell}), do: "$"
  def tool_chip(%{category: :canopy}), do: nil
  def tool_chip(%{tool: "mcp__" <> name}), do: name |> String.split("__") |> hd()

  def tool_chip(%{tool: tool}) when is_binary(tool),
    do: tool |> String.replace("_", " ") |> String.capitalize()

  def tool_chip(_entry), do: nil

  defp category_icon(%{category: :shell}), do: "hero-command-line-mini"
  defp category_icon(%{category: :read}), do: "hero-document-text-mini"
  defp category_icon(%{category: :search}), do: "hero-magnifying-glass-mini"
  defp category_icon(%{category: :edit}), do: "hero-pencil-square-mini"
  defp category_icon(%{category: :web}), do: "hero-globe-alt-mini"
  defp category_icon(%{category: :canopy}), do: "hero-chat-bubble-left-right-mini"
  defp category_icon(%{category: :plan}), do: "hero-list-bullet-mini"
  defp category_icon(%{category: :agent}), do: "hero-sparkles-mini"
  defp category_icon(%{kind: :diff}), do: "hero-document-text-mini"
  defp category_icon(_entry), do: "hero-wrench-screwdriver-mini"

  defp category_class(%{status: :error}), do: "text-error"
  defp category_class(%{category: :shell}), do: "text-info"
  defp category_class(%{category: :read}), do: "text-base-content/55"
  defp category_class(%{category: :search}), do: "text-accent"
  defp category_class(%{category: :edit}), do: "text-warning"
  defp category_class(%{category: :web}), do: "text-info"
  defp category_class(%{category: :canopy}), do: "text-base-content/45"

  defp category_class(%{category: category}) when category in [:plan, :agent],
    do: "text-secondary"

  defp category_class(_entry), do: "text-base-content/45"

  @doc false
  # The card as plain text, one row per line ("✓ 0.1s Read a.py"), for Copy
  # in the side panel: something to paste into a bug report.
  def card_text(card, root \\ nil) do
    card.entries
    |> Enum.reject(&(&1.kind == :step))
    |> Enum.map(fn
      %{kind: :text} = e ->
        "  " <> String.replace(e.label, "\n", " ")

      e ->
        mark =
          case row_status(e) do
            "running" -> "…"
            "error" -> "✕"
            "denied" -> "⊘"
            _ -> "✓"
          end

        [
          mark,
          format_duration(e[:duration_ms]),
          e[:fact],
          relative_paths(e[:command] || e.label, root)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
    end)
    |> Enum.join("\n")
  end

  # Paths inside the channel's repository read relative to its root, so rows
  # never show the user's home directory; a detail the row doesn't need goes.

  # A changed-file row is labelled with the file's name and carries its path
  # (`payments.py — acme/billing/payments.py`); the path alone says both.
  @doc false
  def path_label(label, detail) when is_binary(detail) and label != "" do
    if String.ends_with?(detail, "/" <> label), do: {detail, nil}, else: {label, detail}
  end

  def path_label(label, detail), do: {label, detail}

  # A detail is noise when the label already ends with it (`Grep foo — foo`,
  # `Read a.py — a.py`), when it is an internal id (`canopy handoff_get —
  # ho_01M3…`), or when it is the text of a message the channel already shows
  # (`canopy message_send — …`).
  @doc false
  def redundant_detail?(_label, nil), do: false

  def redundant_detail?(label, detail) do
    label == detail or String.ends_with?(label, " " <> detail) or
      Regex.match?(~r/^[a-z]+_[0-9A-Z]{20,}$/, detail) or
      Regex.match?(~r/^canopy[ _](message_send|thread_reply)$/, label)
  end

  @doc false
  def relative_paths(text, root) when is_binary(text) and is_binary(root) do
    case String.trim_trailing(root, "/") do
      "" ->
        text

      root ->
        text
        |> String.replace(root <> "/", "")
        |> then(&Regex.replace(~r/#{Regex.escape(root)}(?=$|[\s"'`)])/, &1, "."))
        # Agents already run in the repository, so a leading `cd <root> &&` says nothing.
        |> then(&Regex.replace(~r/^\s*cd\s+(["']?)\.\1\s*&&\s*/, &1, ""))
    end
  end

  def relative_paths(text, _root), do: text

  # Entry keys carry paths; ids must stay selector-safe.
  defp dom_key(key), do: Regex.replace(~r/[^A-Za-z0-9_-]+/, key, "-")

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
          name={schedule_icon(s.kind)}
          class="mt-0.5 size-4 shrink-0 text-base-content/50"
        />
        <.watch_row :if={s.kind == "watch"} schedule={s} scope={@scope} />
        <div :if={s.kind != "watch"} class="min-w-0 flex-1">
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
            class="mt-0.5 text-[11px] text-base-content/60"
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
      <li :if={@schedules == []} class="py-2 text-xs text-base-content/60">{@empty}</li>
    </ul>
    """
  end

  defp schedule_icon("recurring"), do: "hero-arrow-path-mini"
  defp schedule_icon("watch"), do: "hero-eye-mini"
  defp schedule_icon(_), do: "hero-clock-mini"

  # `@devops · watching failed CI on main in acme/app · every 10 min · checked
  # 3m ago · fired 2×`, with the check's error under it while it fails.
  attr :schedule, :map, required: true
  attr :scope, :atom, required: true

  defp watch_row(assigns) do
    state = assigns.schedule.check_state || %{}

    assigns =
      assigns
      |> assign(:state, state)
      |> assign(:checked, checked_at(state["last_checked_at"]))

    ~H"""
    <div class="min-w-0 flex-1" id={"watch-#{@schedule.id}"}>
      <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <span :if={@scope == :channel} class="font-mono text-xs text-base-content/60">@{@schedule.agent.name}</span>
        <.link
          :if={@scope == :agent}
          navigate={~p"/channels/#{@schedule.channel_id}"}
          class="font-mono text-xs text-secondary hover:underline"
        >
          #{@schedule.channel.name}
        </.link>
        <span class="font-medium">watching {Canopy.GitHub.describe(@schedule.check)}</span>
        <span class="text-xs text-base-content/60">· {Canopy.Watches.describe_every(@schedule.cron)}</span>
        <span :if={@checked} class="text-xs text-base-content/60">· checked {@checked}</span>
        <span :if={(@state["fired"] || 0) > 0} class="text-xs text-base-content/60">
          · fired {@state["fired"]}×
        </span>
        <span :if={@schedule.playbook} class="text-xs text-base-content/60">
          · starts <span class="font-mono">{@schedule.playbook}</span>
        </span>
        <span
          :if={@schedule.status == "paused"}
          class="badge badge-ghost badge-xs"
          title={@schedule.status_reason}
        >
          paused
        </span>
      </div>
      <p class="mt-0.5 break-words text-xs text-base-content/75">{@schedule.instruction}</p>
      <p
        :if={@state["last_error"] && @schedule.status != "paused"}
        id={"watch-#{@schedule.id}-error"}
        class="mt-0.5 text-[11px] text-error"
      >
        {@state["last_error"]}
      </p>
      <p
        :if={@schedule.status == "paused" and @schedule.status_reason}
        class="mt-0.5 text-[11px] text-base-content/60"
      >
        {@schedule.status_reason}
      </p>
    </div>
    """
  end

  defp checked_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> Canopy.Schedules.relative(at)
      _ -> nil
    end
  end

  defp checked_at(_), do: nil

  # -- Permission cards --------------------------------------------------------

  @doc """
  A pending permission request with Once / Always / Reject. A detached card
  (the agent stopped waiting) stays answerable: an approval reaches the agent
  as a new message, and Reject becomes Dismiss.
  """
  attr :request, :map, required: true
  attr :names, :map, required: true

  def permission_card(assigns) do
    ~H"""
    <section
      id={"permission-#{@request.id}"}
      data-detached={@request.detached_at != nil}
      class={[
        "mx-3 my-2 overflow-hidden rounded-xl border border-warning/40 bg-warning/5 shadow-xs sm:mx-6",
        stale?(@request) && "opacity-70"
      ]}
    >
      <div class="flex items-center gap-2 px-4 py-2.5">
        <.icon name="hero-shield-exclamation" class="size-5 text-warning" />
        <div class="min-w-0 flex-1 text-sm">
          <span class="font-medium">@{requester_name(@request, @names)}</span>
          {if @request.detached_at, do: "asked for", else: "asks for"}
          <span class="font-semibold">{@request.permission}</span>
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
            {if @request.detached_at, do: "Dismiss", else: "Reject"}
          </button>
        </div>
      </div>
      <p
        :if={@request.detached_at}
        id={"permission-#{@request.id}-detached"}
        class="border-t border-warning/20 px-4 py-1.5 text-xs text-base-content/60"
      >
        @{requester_name(@request, @names)} stopped waiting. If you approve, a message tells it
        so and it can do it again.
      </p>
      <.diff_view
        :if={is_binary(@request.metadata["diff"]) and @request.metadata["diff"] != ""}
        id={"permission-#{@request.id}-diff"}
        diff={@request.metadata["diff"]}
        class="max-h-72 border-t border-warning/20 bg-base-100/60 py-2"
      />
    </section>
    """
  end

  @doc "A unified diff with added and removed lines tinted."
  attr :id, :string, required: true
  attr :diff, :string, required: true
  attr :class, :any, default: nil

  def diff_view(assigns) do
    assigns = assign(assigns, :lines, diff_lines(assigns.diff))

    ~H"""
    <pre id={@id} class={["overflow-auto font-mono text-xs leading-relaxed", @class]}><code class="block w-max min-w-full"><span :for={{kind, sign, rest} <- @lines} class={["block px-4", diff_row_class(kind)]} data-diff={kind}><span class={diff_sign_class(kind)}>{sign}</span>{rest}</span></code></pre>
    """
  end

  defp diff_lines(diff) do
    diff
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map(fn
      "+++" <> _ = line -> {:meta, "", line}
      "---" <> _ = line -> {:meta, "", line}
      "+" <> rest -> {:add, "+", rest}
      "-" <> rest -> {:del, "-", rest}
      "@@" <> _ = line -> {:hunk, "", line}
      "" -> {:ctx, "", " "}
      line -> {:ctx, "", line}
    end)
  end

  defp diff_row_class(:add), do: "bg-success/10"
  defp diff_row_class(:del), do: "bg-error/10"
  defp diff_row_class(:hunk), do: "text-info"
  defp diff_row_class(:meta), do: "text-base-content/60"
  defp diff_row_class(_), do: nil

  defp diff_sign_class(:add), do: "text-success"
  defp diff_sign_class(:del), do: "text-error"
  defp diff_sign_class(_), do: nil

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
        case p["by"] do
          "engine_change" ->
            "#{agent} started a fresh session: its engine changed from #{Canopy.Engine.label(p["from_engine"] || "?")} to #{Canopy.Engine.label(p["to_engine"] || "?")}"

          "user" ->
            "#{user} reset #{agent}'s session; it starts fresh on its next turn"

          by ->
            "#{by} reset #{agent}'s session; it starts fresh on its next turn"
        end

      "agent_turn_completed" ->
        verb =
          cond do
            p["outcome"] == "stopped" -> "was stopped by #{user}"
            p["outcome"] == "interrupted" -> "was interrupted by #{user}"
            p["escalated"] -> "escalated to its main model"
            p["outcome"] != "ok" and p["profile"] == "light" -> "hit an error on its light model"
            p["outcome"] != "ok" -> "stopped with an error"
            p["passed"] -> pass_verb(p["note"])
            true -> "finished"
          end

        Enum.join([agent <> " " <> verb | turn_stats(p)], " · ")

      "agent_interrupted" ->
        cond do
          p["mode"] == "now" -> "#{user} interrupted #{agent}"
          p["held"] -> "#{agent} will read your message once the card is answered"
          true -> "#{agent} will read your message after its current step"
        end

      "agent_error" ->
        "#{agent} hit an error: #{p["reason"]}"

      "delegation_created" ->
        cond do
          p["by"] != "user" -> "#{from} delegated to #{to}: #{p["description"]}"
          is_nil(p["from_agent_id"]) -> "#{user} delegated to #{to}: #{p["description"]}"
          true -> "#{user} delegated to #{to} for #{from}: #{p["description"]}"
        end

      "delegation_completed" ->
        "#{to} completed the delegation for #{from}" <> suffix(p["result"])

      "delegation_failed" ->
        "#{to} could not complete the delegation for #{from}" <> suffix(p["result"])

      "delegation_cancelled" ->
        p["note"] || "#{to}'s delegation from #{from} was cancelled"

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

      "team_added" ->
        joined =
          p["agent_ids"]
          |> List.wrap()
          |> Enum.map_join(", ", &agent_ref(names, &1, user_name))

        "@#{p["team_name"]} joined: #{joined}" <>
          if(event.agent_id, do: " (added by #{agent})", else: "")

      "channel_archived" ->
        "#{user} archived this channel"

      "channel_reopened" ->
        "#{user} reopened this channel"

      "spend_limit_changed" ->
        by = if p["by"] in ["user", nil], do: user, else: "@" <> p["by"]

        if is_number(p["limit"]),
          do: "#{by} set this channel's spend limit to #{Canopy.Costs.money(p["limit"])}",
          else: "#{by} removed this channel's spend limit"

      "brief_updated" ->
        by = if p["by"] in ["user", nil], do: user, else: agent

        if p["body"],
          do: "#{by} updated the channel brief",
          else: "#{by} cleared the channel brief"

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
        if p["kind"] == "watch",
          do: watch_fired_text(p, agent),
          else: "scheduled task fired for #{agent}: #{p["instruction"]}"

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
        "#{p["permission"]} permission #{permission_status(p["status"])}" <>
          delivered_suffix(p)

      "permission_detached" ->
        "#{agent} stopped waiting for #{p["permission"]} permission"

      "question_requested" ->
        "#{agent} asked a question"

      "question_resolved" ->
        verb = if p["status"] == "rejected", do: "dismissed", else: "answered"

        if p["by"] == "user",
          do: "#{user} #{verb} #{agent}'s question" <> delivered_suffix(p),
          else: "question #{verb}"

      "question_detached" ->
        "#{agent} stopped waiting for an answer"

      "lock_" <> _ ->
        lock_text(type, p, if(p["user"], do: user, else: agent), user, names, user_name)

      "playbook_" <> _ ->
        playbook_text(type, p, agent, user, names, user_name)

      other ->
        "#{agent} · #{other}"
    end
  end

  defp watch_fired_text(p, agent) do
    found = p["keys"] |> List.wrap() |> length()
    runs = p["runs"] || 0

    started =
      if runs > 0,
        do: "; started #{runs} playbook #{if runs == 1, do: "run", else: "runs"}",
        else: ""

    "a watch found #{found} new #{if found == 1, do: "item", else: "items"} for #{agent} (#{p["watch"]})#{started}"
  end

  defp playbook_text(
         "playbook_started",
         %{"trigger" => %{} = t} = p,
         _agent,
         _user,
         names,
         user_name
       )
       when map_size(t) > 0 do
    "a GitHub watch started the #{p["playbook"]} playbook for #{agent_ref(names, p["coordinator_agent_id"], user_name)} (#{t["key"]}) · #{p["steps"]} steps"
  end

  defp playbook_text("playbook_started", p, agent, _user, _names, _user_name),
    do:
      "#{agent} started the #{p["playbook"]} playbook · #{p["steps"]} steps" <> suffix(p["brief"])

  defp playbook_text("playbook_step_started", p, _agent, _user, names, user_name) do
    round = if (p["round"] || 1) > 1, do: " · round #{p["round"]}", else: ""

    "#{p["playbook"]}: step #{p["position"]}/#{p["total"]} #{p["title"]}" <>
      owners_text(p["owner_ids"], names, user_name) <> round
  end

  defp playbook_text("playbook_step_completed", p, _agent, _user, names, user_name) do
    next =
      if p["next"],
        do: " → #{p["next_title"]}" <> owners_text(p["next_owner_ids"], names, user_name),
        else: ""

    "#{p["playbook"]}: #{p["title"]} done#{next}" <> suffix(p["result"])
  end

  defp playbook_text("playbook_step_skipped", p, _agent, _user, names, user_name) do
    next =
      if p["next"],
        do: " → #{p["next_title"]}" <> owners_text(p["next_owner_ids"], names, user_name),
        else: ""

    "#{p["playbook"]}: skipped #{p["title"]}#{next}" <> suffix(p["result"])
  end

  defp playbook_text("playbook_approval_requested", p, _agent, _user, _names, _user_name),
    do: "#{p["playbook"]} is waiting for your sign-off on #{p["title"]}"

  defp playbook_text(
         "playbook_approval_resolved",
         %{"approved" => true} = p,
         _agent,
         user,
         _n,
         _u
       ),
       do: "#{user} approved #{p["title"]} of #{p["playbook"]}" <> suffix(p["note"])

  defp playbook_text("playbook_approval_resolved", p, _agent, user, _names, _user_name),
    do: "#{user} asked for changes on #{p["title"]} of #{p["playbook"]}" <> suffix(p["note"])

  defp playbook_text("playbook_completed", p, _agent, _user, _names, _user_name),
    do: "the #{p["playbook"]} playbook is complete" <> suffix(p["outcome"])

  defp playbook_text("playbook_cancelled", p, agent, _user, _names, _user_name),
    do: "#{agent} cancelled the #{p["playbook"]} playbook" <> suffix(p["reason"])

  defp playbook_text("playbook_coordinator_changed", p, _agent, user, names, user_name) do
    by =
      case p["by"] do
        "handoff" -> " (it followed the handoff)"
        "user" -> " (by #{user})"
        _ -> ""
      end

    "#{p["playbook"]}: lead #{agent_ref(names, p["from_agent_id"], user_name)} → #{agent_ref(names, p["to_agent_id"], user_name)}#{by}"
  end

  defp playbook_text("playbook_coordinator_kept", p, agent, _user, _names, _user_name),
    do: "#{p["playbook"]}: the lead stays #{agent}" <> suffix(p["reason"])

  defp playbook_text("playbook_stalled", p, agent, _user, _names, _user_name) do
    "#{p["playbook"]} has been on #{p["title"]} for #{Canopy.Playbooks.Runs.duration_text(p["quiet_s"] || 0)} with no activity; nudged #{agent}"
  end

  defp playbook_text(type, _p, agent, _user, _names, _user_name), do: "#{agent} · #{type}"

  defp owners_text(ids, names, user_name) do
    case List.wrap(ids) do
      [] -> ""
      ids -> " (" <> Enum.map_join(ids, ", ", &agent_ref(names, &1, user_name)) <> ")"
    end
  end

  defp lock_text("lock_granted", p, holder, _user, _names, _user_name) do
    if p["promoted"],
      do: "the `#{p["name"]}` lock passed to #{holder}" <> suffix(p["reason"]),
      else: "#{holder} took the `#{p["name"]}` lock" <> suffix(p["reason"])
  end

  defp lock_text("lock_queued", p, holder, user, names, user_name) do
    held_by =
      cond do
        p["holder_user"] -> " held by #{user}"
        p["holder_agent_id"] -> " held by #{agent_ref(names, p["holder_agent_id"], user_name)}"
        true -> ""
      end

    "#{holder} is waiting for the `#{p["name"]}` lock#{held_by} (#{ordinal(p["position"])} in line)" <>
      suffix(p["reason"])
  end

  defp lock_text("lock_released", %{"was" => "waiting"} = p, holder, _user, _names, _user_name),
    do: "#{holder} left the line for the `#{p["name"]}` lock" <> suffix(p["note"])

  defp lock_text("lock_released", p, holder, user, names, user_name) do
    lock = "the `#{p["name"]}` lock"

    released =
      case {p["released_by"], p["user"]} do
        {"agent", _} -> "#{holder} released #{lock}" <> suffix(p["note"])
        {"turn_end", _} -> "#{holder}'s turn ended, releasing #{lock}"
        {"user", true} -> "#{user} released #{lock}"
        {"user", _} -> "#{user} took #{lock} back from #{holder}" <> suffix(p["note"])
        _ -> "#{lock} was taken back from #{holder}" <> suffix(p["note"])
      end

    case p["next_agent_id"] do
      nil -> released
      next -> released <> "; next: " <> agent_ref(names, next, user_name)
    end
  end

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n), do: "#{n}th"

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

  # -- Question cards ----------------------------------------------------------

  @doc """
  A pending question from an agent's question tool. While the agent waits,
  its turn stays blocked until this is answered or dismissed, so the card
  carries the whole form: one group of options per question, and a box for an
  answer in the user's own words on every question (the only input when a
  question has no options). A detached card (the agent stopped waiting) stays
  answerable; the answer then reaches the agent as a new message.
  """
  attr :request, :map, required: true
  attr :names, :map, required: true

  attr :draft, :map, default: %{}, doc: "the form's current params (`question_draft`)"

  def question_card(assigns) do
    ~H"""
    <section
      id={"question-#{@request.id}"}
      data-detached={@request.detached_at != nil}
      class={[
        "mx-3 my-2 overflow-hidden rounded-xl border border-info/40 bg-info/5 shadow-xs sm:mx-6",
        stale?(@request) && "opacity-70"
      ]}
    >
      <div class="flex items-center gap-2 border-b border-info/20 px-4 py-2.5 text-sm">
        <.icon name="hero-question-mark-circle" class="size-5 text-info" />
        <div class="min-w-0 flex-1">
          <span class="font-medium">@{requester_name(@request, @names)}</span>
          <span :if={!@request.detached_at}>needs a decision to carry on</span>
          <span :if={@request.detached_at} id={"question-#{@request.id}-detached"}>
            stopped waiting. Your answer will be sent to it as a message.
          </span>
        </div>
      </div>
      <.question_form request={@request} draft={@draft} />
    </section>
    """
  end

  @doc """
  The answers a question form's params make, one list of strings per
  question in order (the options picked, then the user's own words), or
  `:incomplete` while a question has none.
  """
  def question_answers(request, params) do
    chosen = Map.get(params, "answers", %{})
    custom = Map.get(params, "custom", %{})

    answers =
      request.questions
      |> Enum.with_index()
      |> Enum.map(fn {_question, index} ->
        key = Integer.to_string(index)
        picked = chosen |> Map.get(key, []) |> List.wrap() |> Enum.reject(&(&1 == ""))

        case custom |> Map.get(key, "") |> to_string() |> String.trim() do
          "" -> picked
          text -> picked ++ [text]
        end
      end)

    if Enum.any?(answers, &(&1 == [])), do: :incomplete, else: answers
  end

  # The form inside a question card (standalone, or folded into the live
  # turn's card). It reports every change (`question_draft`), so Send stays
  # disabled until each question has an option picked or words typed.
  attr :request, :map, required: true
  attr :draft, :map, default: %{}

  defp question_form(assigns) do
    draft = assigns.draft || %{}

    assigns =
      assigns
      |> assign(:chosen, Map.get(draft, "answers", %{}))
      |> assign(:custom, Map.get(draft, "custom", %{}))
      |> assign(:ready?, question_answers(assigns.request, draft) != :incomplete)

    ~H"""
    <form
      id={"question-#{@request.id}-form"}
      phx-submit="answer_question"
      phx-change="question_draft"
    >
      <input type="hidden" name="request_id" value={@request.id} />

      <div
        :for={{question, index} <- Enum.with_index(@request.questions)}
        class="border-b border-info/10 px-4 py-3"
      >
        <p class="text-sm font-medium">{question["question"]}</p>

        <div :if={List.wrap(question["options"]) != []} class="mt-2 space-y-1.5">
          <label
            :for={option <- List.wrap(question["options"])}
            class="flex cursor-pointer items-start gap-2 rounded-lg px-2 py-1.5 transition-colors hover:bg-info/10"
          >
            <input
              type={if question["multiple"], do: "checkbox", else: "radio"}
              name={"answers[#{index}][]"}
              value={option["label"]}
              checked={option["label"] in List.wrap(Map.get(@chosen, to_string(index)))}
              class={[
                "mt-0.5 shrink-0",
                if(question["multiple"], do: "checkbox checkbox-xs", else: "radio radio-xs")
              ]}
            />
            <span class="min-w-0 text-sm">
              <span class="font-medium">{option["label"]}</span>
              <span :if={option["description"]} class="block text-xs text-base-content/60">
                {option["description"]}
              </span>
            </span>
          </label>
        </div>

        <%!-- Every question takes an answer in the user's own words; with no
             options it is the only answer, so it is required. --%>
        <input
          type="text"
          id={"question-#{@request.id}-custom-#{index}"}
          name={"custom[#{index}]"}
          value={Map.get(@custom, to_string(index), "")}
          placeholder={
            if List.wrap(question["options"]) == [],
              do: "Your answer",
              else: "Or answer in your own words…"
          }
          aria-label={
            if List.wrap(question["options"]) == [],
              do: "Your answer",
              else: "Or answer in your own words"
          }
          required={List.wrap(question["options"]) == []}
          autocomplete="off"
          class="mt-2 input input-sm input-bordered w-full focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
        />
      </div>

      <div class="flex items-center justify-end gap-1.5 px-4 py-2.5">
        <button
          type="button"
          id={"question-#{@request.id}-dismiss"}
          class="btn btn-ghost btn-sm"
          phx-click="reject_question"
          phx-value-id={@request.id}
        >
          Dismiss
        </button>
        <button
          type="submit"
          id={"question-#{@request.id}-send"}
          class="btn btn-sm btn-primary"
          disabled={!@ready?}
          title={if !@ready?, do: "Pick an option or type an answer first"}
        >
          Send
        </button>
      </div>
    </form>
    """
  end

  # A detached card nobody has answered for a day is dimmed; it never expires.
  defp stale?(%{detached_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :hour) >= 24

  defp stale?(_request), do: false

  defp delivered_suffix(%{"delivered" => "message"}), do: " (sent as a message)"
  defp delivered_suffix(_payload), do: ""

  defp requester_name(%{agent_session: %{agent: %{name: name}}}, _names), do: name
  defp requester_name(_request, _names), do: "agent"

  defp receipt_text(receipt) do
    [count(receipt[:tools], "tool"), format_duration(receipt[:duration_ms])]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "activity"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp turn_stats(p) do
    [
      if(p["outcome"] == "ok", do: mid_turn(p["interrupted_by"])),
      count(p["tools"], "tool"),
      count(length(List.wrap(p["files"])), "file"),
      if(is_number(p["cost"]) and p["cost"] > 0, do: format_cost(p["cost"])),
      format_duration(p["duration_ms"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The messages the user steered into a turn that finished on its own.
  defp mid_turn([_]), do: "took 1 message mid-turn"
  defp mid_turn([_ | _] = ids), do: "took #{length(ids)} messages mid-turn"
  defp mid_turn(_), do: nil

  defp schedule_timing(%{"kind" => "recurring", "cron" => cron}),
    do: Canopy.Schedules.describe_cron(cron)

  defp schedule_timing(%{"kind" => "watch", "watch" => what, "cron" => cron}),
    do: "watching #{what}, #{Canopy.Schedules.describe_cron(cron)}"

  defp schedule_timing(_), do: "once"

  defp count(n, _noun) when not is_integer(n) or n == 0, do: nil
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  @doc """
  How a pass reads after the agent's name: the agent's note becomes the
  sentence ("had nothing to add", "is holding the lock") rather than the
  internal `canopy_pass` verb. A note that is not a phrase of its own is kept
  after "had nothing to add".
  """
  def pass_verb(note) do
    note = if is_binary(note), do: note |> String.trim() |> String.trim_trailing("."), else: ""
    lower = String.downcase(note)
    [first | _] = String.split(lower, ~r/\s+/, parts: 2) ++ [""]

    cond do
      note == "" ->
        "had nothing to add"

      lower =~
          ~r/^(nothing (more |else |new )?(to add|to say|needed|to do)|no reply needed|n\/a)$/ ->
        "had nothing to add"

      String.ends_with?(first, "ing") and String.length(first) > 4 ->
        "is " <> lower_first(note)

      true ->
        "had nothing to add: " <> truncate(lower_first(note), 160)
    end
  end

  @doc """
  A pass without its subject, for a column or a divider: "nothing to add",
  "holding the lock".
  """
  def pass_phrase(note) do
    case pass_verb(note) do
      "is " <> phrase -> phrase
      "had " <> phrase -> phrase
    end
  end

  defp lower_first(<<c::utf8, rest::binary>> = text) do
    if String.upcase(rest) == rest, do: text, else: String.downcase(<<c::utf8>>) <> rest
  end

  defp lower_first(text), do: text

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
  defp event_icon("agent_interrupted"), do: "hero-forward-mini"
  defp event_icon("delegation_" <> _), do: "hero-arrow-uturn-right-mini"
  defp event_icon("handoff_" <> _), do: "hero-arrow-right-circle-mini"
  defp event_icon("task_updated"), do: "hero-clipboard-document-check-mini"
  defp event_icon("owner_changed"), do: "hero-user-circle-mini"
  defp event_icon("member_added"), do: "hero-user-plus-mini"
  defp event_icon("member_removed"), do: "hero-user-minus-mini"
  defp event_icon("team_added"), do: "hero-user-group-mini"
  defp event_icon("channel_archived"), do: "hero-archive-box-mini"
  defp event_icon("channel_reopened"), do: "hero-archive-box-x-mark-mini"
  defp event_icon("spend_limit_" <> _), do: "hero-banknotes-mini"
  defp event_icon("repository_switched"), do: "hero-folder-arrow-down-mini"
  defp event_icon("brief_updated"), do: "hero-document-text-mini"
  defp event_icon("schedule_fired"), do: "hero-bell-alert-mini"
  defp event_icon("schedule_" <> _), do: "hero-clock-mini"
  defp event_icon("permission_" <> _), do: "hero-shield-check-mini"
  defp event_icon("question_" <> _), do: "hero-question-mark-circle-mini"
  defp event_icon("lock_released"), do: "hero-lock-open-mini"
  defp event_icon("lock_" <> _), do: "hero-lock-closed-mini"
  defp event_icon("playbook_approval_" <> _), do: "hero-hand-raised-mini"
  defp event_icon("playbook_stalled"), do: "hero-bell-alert-mini"
  defp event_icon("playbook_" <> _), do: "hero-book-open-mini"
  defp event_icon(_), do: "hero-information-circle-mini"

  defp event_tone(%{event_type: "agent_error"}), do: "error"
  defp event_tone(%{event_type: "spend_limit_reached"}), do: "error"
  defp event_tone(%{event_type: "delegation_failed"}), do: "error"
  defp event_tone(%{event_type: "handoff_rejected"}), do: "warning"

  defp event_tone(%{event_type: "lock_released", payload: %{"released_by" => by}})
       when by in ~w(lease user restart),
       do: "warning"

  defp event_tone(%{event_type: "agent_turn_completed", payload: %{"outcome" => "error"}}),
    do: "error"

  defp event_tone(%{event_type: type})
       when type in ~w(handoff_accepted delegation_completed playbook_completed),
       do: "success"

  defp event_tone(%{event_type: type})
       when type in ~w(playbook_approval_requested playbook_stalled),
       do: "warning"

  defp event_tone(_), do: "muted"
end
