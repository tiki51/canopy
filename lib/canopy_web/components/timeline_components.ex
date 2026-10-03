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

  attr :mentions, :any,
    default: MapSet.new(),
    doc: "agent and team names highlighted as @mentions in bodies"

  attr :thread_open, :boolean, default: false

  attr :root, :string,
    default: nil,
    doc: "the repository path; tool paths inside it show relative"

  def timeline_item(%{event: %{event_type: "message"}} = assigns) do
    ~H"""
    <div id={@id}>
      <.message_item
        message={@event.message}
        names={@names}
        user_name={@user_name}
        replies={@replies}
        channels={@channels}
        mentions={@mentions}
        repliable
        thread_open={@thread_open}
        inline_reply={not is_nil(@event.message.thread_id)}
      />
    </div>
    """
  end

  def timeline_item(%{event: %{event_type: "agent_turn_completed"}} = assigns) do
    assigns =
      assigns
      |> assign(:final_text, assigns.event.payload["final_text"])
      |> then(fn assigns ->
        entries = visible(Activity.from_payload(assigns.event.payload["activity"]))
        assign(assigns, :entries, drop_closing_note(entries, assigns.final_text))
      end)

    ~H"""
    <div id={@id} data-activity={activity_class(@event)}>
      <.turn_card
        event={@event}
        names={@names}
        user_name={@user_name}
        entries={@entries}
        final_text={@final_text}
        root={@root}
        mentions={@mentions}
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
  attr :repliable, :boolean, default: false, doc: "show the Reply in thread affordance"
  attr :thread_open, :boolean, default: false
  attr :channels, :map, default: %{}
  attr :mentions, :any, default: MapSet.new()

  def message_item(%{message: %{kind: "system"}} = assigns) do
    ~H"""
    <.system_line
      id={"message-#{@message.id}"}
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
            class="rounded-full bg-base-300/70 px-1.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60"
            title="The agent's final turn text"
          >
            reply
          </span>
          <span
            :if={@inline_reply}
            class="text-[11px] text-base-content/60"
            title="A reply in a thread that is not loaded"
          >
            in a thread
          </span>
          <time
            class="text-[11px] text-base-content/60"
            title={DateTime.to_iso8601(@message.inserted_at)}
          >
            {short_time(@message.inserted_at)}
          </time>
          <button
            :if={@repliable}
            type="button"
            id={"reply-#{@message.id}"}
            class="ml-auto flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] font-medium text-base-content/60 opacity-0 transition hover:bg-base-300/60 hover:text-base-content focus:opacity-100 group-hover:opacity-100"
            phx-click="reply_in_thread"
            phx-value-id={@message.id}
            title="Reply in a thread"
          >
            <.icon name="hero-chat-bubble-left-right-mini" class="size-3.5" /> Reply
          </button>
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
          <.attachments message={@message} />
        </div>

        <div :if={@replies != []} class="mt-1.5">
          <%!-- Open state lives on the server: a client-side toggle would be
               undone by the next patch, and a thread re-renders whenever it
               gains a reply. --%>
          <button
            type="button"
            id={"thread-toggle-#{@message.id}"}
            class="flex items-center gap-1 text-xs font-medium text-primary transition hover:underline"
            phx-click="toggle_thread"
            phx-value-id={@message.id}
            aria-expanded={to_string(@thread_open)}
          >
            <.icon name="hero-chat-bubble-left-right-mini" class="size-3.5" />
            {ngettext("1 reply", "%{count} replies", length(@replies))}
          </button>
          <div
            id={"thread-#{@message.id}"}
            hidden={not @thread_open}
            class="mt-2 border-l-2 border-base-300 pl-3"
          >
            <div :for={reply <- @replies} class="-mx-3 sm:-mx-6">
              <.message_item
                message={reply}
                names={@names}
                user_name={@user_name}
                channels={@channels}
                mentions={@mentions}
                repliable
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
  attr :root, :string, default: nil

  def telemetry_card(assigns) do
    assigns = assign(assigns, :entries, visible(assigns.card.entries))

    ~H"""
    <details
      id={"telemetry-#{@agent_id}"}
      phx-hook="KeepOpen"
      class="group/card mx-3 my-2 overflow-hidden sm:mx-6 rounded-xl border border-secondary/40 bg-secondary/10 shadow-xs"
      data-live="true"
    >
      <summary
        id={"telemetry-toggle-#{@agent_id}"}
        class="flex cursor-pointer select-none list-none items-center gap-2 px-4 py-2 text-sm transition hover:bg-secondary/15 [&::-webkit-details-marker]:hidden"
      >
        <Layouts.status_dot status={:busy} />
        <span class="font-medium text-secondary">@{@name} is {Activity.verb(@card)}…</span>
        <span class="ml-auto flex items-center gap-3 text-[11px] text-base-content/60">
          <span :if={@card.tool_count > 0}>{count(@card.tool_count, "tool")}</span>
          <span :if={@card.cost > 0}>{format_cost(@card.cost)}</span>
          <.chevron />
        </span>
      </summary>
      <div class="border-t border-secondary/20 px-4 py-2">
        <.activity_list id={"telemetry-#{@agent_id}"} entries={@entries} root={@root} />
        <p :if={@entries == []} class="text-xs text-base-content/60">
          Waiting for the first tool call…
        </p>
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
  attr :root, :string, default: nil
  attr :mentions, :any, default: MapSet.new()

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
        <.activity_list id={"turn-#{@event.id}"} entries={@entries} root={@root} />
        <div
          :if={@final_text}
          id={"turn-#{@event.id}-note"}
          class={["border-t border-dashed border-base-300 pt-2", @entries != [] && "mt-2"]}
        >
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/60">
            Closing note
          </p>
          <.message_text body={@final_text} mentions={@mentions} />
        </div>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :root, :string, default: nil

  defp activity_list(assigns) do
    assigns =
      assign(assigns, :entries, Enum.map(assigns.entries, &relative_entry(&1, assigns.root)))

    ~H"""
    <ol :if={@entries != []} class="flex flex-col gap-0.5 font-mono text-xs">
      <li
        :for={entry <- @entries}
        id={"#{@id}-#{dom_key(entry.key)}"}
        class={["flex items-start gap-2 text-base-content/75", entry.kind == :text && "my-1"]}
        data-kind={entry.kind}
      >
        <.icon name={entry_icon(entry)} class={["mt-0.5 size-3.5 shrink-0", entry_class(entry)]} />
        <%!-- The agent's own words between tool calls: prose, wrapped, in place. --%>
        <p
          :if={entry.kind == :text}
          class="min-w-0 whitespace-pre-wrap break-words font-sans leading-relaxed text-base-content/80"
        >
          {entry.label}
        </p>
        <span :if={entry.kind != :text} class="min-w-0 truncate">
          <span class="text-base-content">{entry.label}</span>
          <span :if={entry.detail} class="text-base-content/60">— {entry.detail}</span>
        </span>
      </li>
    </ol>
    """
  end

  # Step rows ("step tool_use — 218 tokens") are model-call bookkeeping; Costs
  # counts them, the activity list leaves them out.
  defp visible(entries), do: Enum.reject(entries, &(&1.kind == :step))

  # The turn's closing text is shown under the card as its closing note; the
  # same text in the activity list would say it twice.
  defp drop_closing_note(entries, final_text) when is_binary(final_text) do
    note = String.trim(final_text)

    Enum.reject(entries, fn entry ->
      entry.kind == :text and
        (String.trim(entry.label) == note or
           (String.ends_with?(entry.label, "…") and
              String.starts_with?(note, String.trim(String.trim_trailing(entry.label, "…")))))
    end)
  end

  defp drop_closing_note(entries, _final_text), do: entries

  # Paths inside the channel's repository read relative to its root, so rows
  # never show the user's home directory; a detail the row doesn't need goes.
  defp relative_entry(%{kind: :text} = entry, _root), do: entry

  defp relative_entry(entry, root) do
    {label, detail} =
      path_label(relative_paths(entry.label, root), relative_paths(entry.detail, root))

    %{entry | label: label, detail: if(redundant_detail?(label, detail), do: nil, else: detail)}
  end

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
        "#{if p["by"] == "user", do: user, else: p["by"]} reset #{agent}'s session; it starts fresh on its next turn"

      "agent_turn_completed" ->
        verb =
          cond do
            p["outcome"] == "stopped" -> "was stopped by #{user}"
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

      other ->
        "#{agent} · #{other}"
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
      <form id={"question-#{@request.id}-form"} phx-submit="answer_question">
        <input type="hidden" name="request_id" value={@request.id} />

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

        <div
          :for={{question, index} <- Enum.with_index(@request.questions)}
          class="border-b border-info/10 px-4 py-3"
        >
          <p class="text-sm font-medium">{question["question"]}</p>
          <p :if={question["header"]} class="mt-0.5 text-xs text-base-content/60">
            {question["header"]}
          </p>

          <div :if={List.wrap(question["options"]) != []} class="mt-2 space-y-1.5">
            <label
              :for={option <- List.wrap(question["options"])}
              class="flex cursor-pointer items-start gap-2 rounded-lg px-2 py-1.5 transition-colors hover:bg-info/10"
            >
              <input
                type={if question["multiple"], do: "checkbox", else: "radio"}
                name={"answers[#{index}][]"}
                value={option["label"]}
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
            class="mt-2 input input-sm input-bordered w-full"
          />
        </div>

        <div class="flex items-center justify-end gap-1.5 px-4 py-2.5">
          <button
            type="button"
            id={"question-#{@request.id}-dismiss"}
            class="btn btn-xs btn-ghost text-error"
            phx-click="reject_question"
            phx-value-id={@request.id}
          >
            Dismiss
          </button>
          <button type="submit" id={"question-#{@request.id}-send"} class="btn btn-xs btn-primary">
            Send
          </button>
        </div>
      </form>
    </section>
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
  defp event_icon("team_added"), do: "hero-user-group-mini"
  defp event_icon("channel_archived"), do: "hero-archive-box-mini"
  defp event_icon("channel_reopened"), do: "hero-archive-box-x-mark-mini"
  defp event_icon("spend_limit_" <> _), do: "hero-banknotes-mini"
  defp event_icon("repository_switched"), do: "hero-folder-arrow-down-mini"
  defp event_icon("schedule_fired"), do: "hero-bell-alert-mini"
  defp event_icon("schedule_" <> _), do: "hero-clock-mini"
  defp event_icon("permission_" <> _), do: "hero-shield-check-mini"
  defp event_icon("question_" <> _), do: "hero-question-mark-circle-mini"
  defp event_icon("lock_released"), do: "hero-lock-open-mini"
  defp event_icon("lock_" <> _), do: "hero-lock-closed-mini"
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

  defp event_tone(%{event_type: type}) when type in ~w(handoff_accepted delegation_completed),
    do: "success"

  defp event_tone(_), do: "muted"

  defp entry_icon(%{kind: :tool, status: :running}), do: "hero-arrow-path-mini"
  defp entry_icon(%{kind: :tool, status: :error}), do: "hero-x-circle-mini"
  defp entry_icon(%{kind: :tool}), do: "hero-wrench-screwdriver-mini"
  defp entry_icon(%{kind: :file}), do: "hero-pencil-square-mini"
  defp entry_icon(%{kind: :step}), do: "hero-flag-mini"
  defp entry_icon(%{kind: :diff}), do: "hero-document-text-mini"
  defp entry_icon(%{kind: :text}), do: "hero-chat-bubble-bottom-center-text-mini"
  defp entry_icon(_), do: "hero-information-circle-mini"

  defp entry_class(%{kind: :tool, status: :running}), do: "animate-spin text-success"
  defp entry_class(%{kind: :tool, status: :error}), do: "text-error"
  defp entry_class(%{kind: :file}), do: "text-warning"
  defp entry_class(%{kind: :text, status: :running}), do: "text-secondary"
  defp entry_class(%{kind: :text}), do: "text-secondary/60"
  defp entry_class(_), do: "text-base-content/40"
end
