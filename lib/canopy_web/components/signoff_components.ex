defmodule CanopyWeb.SignoffComponents do
  @moduledoc """
  Sign-off cards: an agent (or a playbook's approval step) asks the user to
  accept or reject, or to accept one of a few options. One press answers;
  a note is optional on every press.

    * `signoff_card/1`, the full card pinned under the feed
    * `signoff_compact/1`, the same card in the run panel's held step
    * `signoff_line/1`, the one-line row a `signoff_resolved` event leaves

  Both cards post `answer_signoff` with `%{"signoff_id", "verdict", "note"}`, where
  `verdict` is the pressed button's value: `accept`, `accept:<index>` or
  `reject`. Both report the note as it is typed (`signoff_note`, on blur),
  so a note typed in one goes with a press in the other.
  """

  use CanopyWeb, :html

  import CanopyWeb.TimelineComponents, only: [attachments: 1, message_text: 1, short_time: 1]

  alias Canopy.Signoffs

  @doc """
  Who asks: `@name`, or with no agent (a deleted asker, or a backfilled run
  with no coordinator) the run's playbook, else "An agent".
  """
  def asker(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  def asker(%{run: %{playbook_name: name}}) when is_binary(name), do: name
  def asker(_signoff), do: "An agent"

  @doc "A, B, C… for a 0-based option index."
  def letter(index) when is_integer(index) and index >= 0 and index < 26, do: <<?A + index>>
  def letter(index) when is_integer(index), do: Integer.to_string(index + 1)

  # -- Full card -----------------------------------------------------------------

  attr :signoff, :map, required: true
  attr :note, :string, default: ""

  def signoff_card(assigns) do
    assigns = assign(assigns, :prefix, "signoff-#{assigns.signoff.id}")

    ~H"""
    <section
      id={@prefix}
      tabindex="-1"
      aria-labelledby={"#{@prefix}-title"}
      data-options={length(@signoff.options)}
      class="mx-3 my-2 overflow-hidden rounded-xl border border-warning/40 bg-warning/5 shadow-xs outline-none focus-visible:ring-2 focus-visible:ring-warning/50 sm:mx-6"
    >
      <header class="flex flex-wrap items-center gap-x-2 gap-y-1 border-b border-warning/20 px-4 py-2.5 text-sm">
        <.icon name="hero-hand-raised" class="size-5 shrink-0 text-warning" />
        <h3 id={"#{@prefix}-title"} class="min-w-0 flex-1">
          <span class="font-medium">{asker(@signoff)}</span>
          wants your sign-off
          <span :if={@signoff.title} class="text-base-content/60">· {@signoff.title}</span>
        </h3>
        <%!-- below sm the badge takes its own line, under the title text --%>
        <div
          :if={badge = Signoffs.badge(@signoff)}
          class="min-w-0 basis-full pl-7 sm:shrink-0 sm:basis-auto sm:pl-0"
        >
          <span
            id={"#{@prefix}-badge"}
            class="badge badge-ghost max-w-full truncate font-mono text-xs"
            title={badge}
          >
            {badge}
          </span>
        </div>
      </header>

      <div class="px-4 pt-3">
        <p class="text-sm font-medium">{@signoff.question}</p>
        <%!-- a run card's summary is the step's result (up to 20k chars) --%>
        <div
          :if={@signoff.summary}
          id={"#{@prefix}-summary"}
          class="mt-1 max-h-64 overflow-y-auto text-sm text-base-content/75"
        >
          <.message_text body={@signoff.summary} />
        </div>
        <.attachments message={@signoff} dom_prefix="signoff-" />
      </div>

      <form id={"#{@prefix}-form"} phx-submit="answer_signoff" phx-change="signoff_note">
        <.default_button />
        <input type="hidden" name="signoff_id" value={@signoff.id} />

        <ul :if={@signoff.options != []} role="list" class="space-y-1.5 px-4 pt-3">
          <li
            :for={{option, index} <- Enum.with_index(@signoff.options)}
            id={"#{@prefix}-option-#{index}"}
            class={[
              "flex items-center gap-3 rounded-lg border bg-base-100 px-3 py-2",
              if(option["recommended"], do: "border-success/40", else: "border-base-300")
            ]}
          >
            <span class="flex size-6 shrink-0 items-center justify-center rounded-md bg-base-300/70 text-xs font-semibold">
              {letter(index)}
            </span>
            <div class="min-w-0 flex-1 text-sm">
              <p class="font-medium">
                {option["label"]}
                <span :if={option["recommended"]} class="badge badge-success badge-soft badge-xs ml-1">
                  recommended
                </span>
              </p>
              <p :if={option["description"]} class="text-xs text-base-content/60">
                {option["description"]}
              </p>
            </div>
            <button
              type="submit"
              name="verdict"
              value={"accept:#{index}"}
              id={"#{@prefix}-accept-#{index}"}
              class={[
                "signoff-verdict btn btn-sm btn-success shrink-0",
                !option["recommended"] && "btn-outline"
              ]}
              aria-label={option_label(option, index)}
            >
              <.verdict_icon icon="hero-check-mini" /> Accept
            </button>
          </li>
        </ul>

        <%!-- below sm the note gets its own row, the buttons right-aligned under it --%>
        <div class="mt-3 flex flex-wrap items-center gap-2 border-t border-warning/15 px-4 py-2.5">
          <.note_input id={"#{@prefix}-note"} signoff={@signoff} note={@note} size="sm" />
          <div class="ml-auto flex gap-2">
            <%= if @signoff.options == [] do %>
              <button
                type="submit"
                name="verdict"
                value="reject"
                id={"#{@prefix}-reject"}
                class="signoff-verdict btn btn-sm btn-error"
              >
                <.verdict_icon icon="hero-x-mark-mini" /> Reject
              </button>
              <button
                type="submit"
                name="verdict"
                value="accept"
                id={"#{@prefix}-accept"}
                class="signoff-verdict btn btn-sm btn-success"
              >
                <.verdict_icon icon="hero-check-mini" /> Accept
              </button>
            <% else %>
              <button
                type="submit"
                name="verdict"
                value="reject"
                id={"#{@prefix}-reject-all"}
                class="signoff-verdict btn btn-sm btn-error btn-outline"
                aria-label="Reject all options"
              >
                <.verdict_icon icon="hero-x-mark-mini" /> Reject all
              </button>
            <% end %>
          </div>
        </div>
      </form>
    </section>
    """
  end

  # -- Compact card (run panel) ----------------------------------------------------

  attr :signoff, :map, required: true
  attr :note, :string, default: ""

  def signoff_compact(assigns) do
    ~H"""
    <div id="playbook-signoff" data-signoff={@signoff.id} class="mt-2">
      <form id="playbook-signoff-form" phx-submit="answer_signoff" phx-change="signoff_note">
        <.default_button />
        <input type="hidden" name="signoff_id" value={@signoff.id} />

        <%= if @signoff.options == [] do %>
          <.note_input id="playbook-signoff-note" signoff={@signoff} note={@note} size="xs" />
          <div class="mt-1.5 flex items-center gap-1.5">
            <button
              type="submit"
              name="verdict"
              value="reject"
              id="playbook-signoff-reject"
              class="signoff-verdict btn btn-xs btn-error"
            >
              <.verdict_icon icon="hero-x-mark-micro" class="size-3.5" /> Reject
            </button>
            <button
              type="submit"
              name="verdict"
              value="accept"
              id="playbook-signoff-accept"
              class="signoff-verdict btn btn-xs btn-success"
            >
              <.verdict_icon icon="hero-check-micro" class="size-3.5" /> Accept
            </button>
            <a
              href={"#signoff-#{@signoff.id}"}
              id="playbook-signoff-show"
              phx-click="show_signoff"
              phx-value-id={@signoff.id}
              class="link link-hover ml-auto text-xs text-base-content/60"
            >
              Show card ↓
            </a>
          </div>
        <% else %>
          <%!-- no note box here; one typed in the timeline card still goes --%>
          <input type="hidden" name="note" value={@note} />
          <p class="text-xs text-base-content/70">{@signoff.question}</p>
          <div class="mt-1.5 flex flex-wrap gap-1.5">
            <button
              :for={{option, index} <- Enum.with_index(@signoff.options)}
              type="submit"
              name="verdict"
              value={"accept:#{index}"}
              id={"playbook-signoff-accept-#{index}"}
              class={[
                "signoff-verdict btn btn-xs btn-success",
                !option["recommended"] && "btn-outline"
              ]}
              aria-label={option_label(option, index)}
              title={option["label"]}
            >
              <.verdict_icon icon="hero-check-micro" class="size-3.5" /> {letter(index)}
            </button>
            <button
              type="submit"
              name="verdict"
              value="reject"
              id="playbook-signoff-reject-all"
              class="signoff-verdict btn btn-xs btn-error btn-outline"
              aria-label="Reject all options"
            >
              <.verdict_icon class="size-3.5" /> Reject all
            </button>
          </div>
          <a
            href={"#signoff-#{@signoff.id}"}
            id="playbook-signoff-show"
            phx-click="show_signoff"
            phx-value-id={@signoff.id}
            class="link link-hover mt-1 block text-xs text-base-content/60"
          >
            Show the options in the timeline ↓
          </a>
        <% end %>
      </form>
    </div>
    """
  end

  # While a press is in flight, LiveView disables every button in the form
  # and marks only the pressed one `.phx-submit-loading`; app.css keeps that
  # one coloured and swaps its icon for the spinner.
  attr :icon, :string, default: nil
  attr :class, :string, default: "size-4"

  defp verdict_icon(assigns) do
    ~H"""
    <.icon :if={@icon} name={@icon} class={["signoff-icon", @class]} /><span
      class={["signoff-spinner loading loading-spinner", @class]}
      aria-hidden="true"
    ></span>
    """
  end

  # A form's first submit button is its default: Enter in the note would
  # otherwise press the first real one (Reject). Implicit submission does
  # nothing when the default button is disabled.
  defp default_button(assigns) do
    ~H"""
    <button type="submit" disabled hidden aria-hidden="true" tabindex="-1"></button>
    """
  end

  attr :id, :string, required: true
  attr :signoff, :map, required: true
  attr :note, :string, default: ""
  attr :size, :string, values: ~w(sm xs)

  defp note_input(assigns) do
    ~H"""
    <label for={@id} class="sr-only">{note_label(@signoff)}</label>
    <input
      type="text"
      id={@id}
      name="note"
      value={@note}
      maxlength="2000"
      autocomplete="off"
      phx-debounce="blur"
      placeholder="Add a note (optional)…"
      class={[
        "input input-bordered min-w-0 flex-1",
        if(@size == "xs", do: "input-xs w-full", else: "input-sm basis-full sm:basis-0")
      ]}
    />
    """
  end

  defp note_label(%{agent: %{name: name}}) when is_binary(name),
    do: "Note for @#{name} (optional)"

  defp note_label(_signoff), do: "Note (optional)"

  defp option_label(option, index) do
    "Accept #{letter(index)}: #{option["label"]}" <>
      if(option["recommended"], do: " (recommended)", else: "")
  end

  # -- Collapsed row -----------------------------------------------------------------

  @doc """
  The row a `signoff_resolved` event leaves where the card was, drawn from
  the payload alone (stream items aren't re-read). A freestanding answer was
  posted as the user's own message, which already says it, so its row is
  hidden.
  """
  attr :id, :string, required: true
  attr :event, :map, required: true

  def signoff_line(%{event: %{payload: %{"delivered" => "message"}}} = assigns) do
    ~H"""
    <div id={@id}>
      <div id={"signoff-resolved-#{@event.ref_id}"} data-status={@event.payload["status"]} hidden>
      </div>
    </div>
    """
  end

  def signoff_line(assigns) do
    assigns = assign(assigns, :p, assigns.event.payload)

    ~H"""
    <div id={@id}>
      <div
        id={"signoff-resolved-#{@event.ref_id}"}
        data-status={@p["status"]}
        class={[
          "mx-3 my-1 flex items-center gap-2 rounded-lg border px-4 py-2 text-sm sm:mx-6",
          @p["status"] == "accepted" && "border-success/30 bg-success/5",
          @p["status"] != "accepted" && "border-error/30 bg-error/5"
        ]}
      >
        <.icon
          name={if @p["status"] == "accepted", do: "hero-check-mini", else: "hero-x-mark-mini"}
          class={[
            "size-4 shrink-0",
            if(@p["status"] == "accepted", do: "text-success", else: "text-error")
          ]}
        />
        <span class="min-w-0 flex-1">
          {resolved_parts(@p)}
          <span :if={note = present(@p["note"])} class="text-base-content/60">— “{note}”</span>
        </span>
        <time
          class="shrink-0 text-xs text-base-content/50"
          title={DateTime.to_iso8601(@event.inserted_at)}
        >
          {short_time(@event.inserted_at)}
        </time>
      </div>
    </div>
    """
  end

  defp resolved_parts(p) do
    assigns = %{p: p, subject: subject(p)}

    ~H"""
    <%= cond do %>
      <% @p["status"] == "accepted" and is_integer(@p["choice_index"]) -> %>
        <b>You accepted</b>
        <span class="font-medium">{letter(@p["choice_index"])} · {@p["choice"]}</span> for {@subject}
      <% @p["status"] == "accepted" -> %>
        <b>You accepted</b> {@subject}
      <% (@p["options_count"] || 0) > 0 -> %>
        <b>You rejected all</b> options for {@subject}
      <% true -> %>
        <b>You rejected</b> {@subject}
    <% end %>
    """
  end

  @doc "Plain text of a resolved row, for tests and the activity log."
  def resolved_text(p) do
    s = subject(p)

    text =
      cond do
        p["status"] == "accepted" and is_integer(p["choice_index"]) ->
          "You accepted #{letter(p["choice_index"])} · #{p["choice"]} for #{s}"

        p["status"] == "accepted" ->
          "You accepted #{s}"

        (p["options_count"] || 0) > 0 ->
          "You rejected all options for #{s}"

        true ->
          "You rejected #{s}"
      end

    case present(p["note"]) do
      nil -> text
      note -> text <> " — “#{note}”"
    end
  end

  # "@designer's Design approval", with whatever of the two is known.
  defp subject(%{"agent" => agent, "title" => title}) when is_binary(agent) and is_binary(title),
    do: "@#{agent}'s #{title}"

  defp subject(%{"agent" => agent}) when is_binary(agent), do: "@#{agent}'s sign-off"
  defp subject(%{"title" => title}) when is_binary(title), do: title
  defp subject(_payload), do: "the sign-off"

  @doc "The one-line text of a `signoff_requested` or `signoff_withdrawn` event."
  def event_line("signoff_requested", p, agent_name) do
    who =
      cond do
        is_binary(agent_name) -> "@" <> agent_name
        is_binary(p["playbook"]) -> p["playbook"]
        true -> "An agent"
      end

    "#{who} asked for your sign-off" <> if(p["title"], do: " on #{p["title"]}", else: "")
  end

  def event_line("signoff_resolved", p, _agent_name), do: resolved_text(p)

  def event_line("signoff_withdrawn", p, _agent_name) do
    subject =
      case p do
        %{"agent" => agent} when is_binary(agent) -> "@#{agent}'s sign-off"
        _ -> "The sign-off"
      end

    "#{subject}" <>
      if(p["title"], do: " on #{p["title"]}", else: "") <>
      " was withdrawn" <> if(p["reason"], do: " (#{p["reason"]})", else: "")
  end

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp present(_), do: nil
end
