defmodule CanopyWeb.ChannelLive.Transcript do
  @moduledoc """
  An agent's engine session in a channel, read back from the engine
  (`/channels/:id/agents/:agent_id/transcript`): every prompt Canopy sent,
  the system text, the model's text and reasoning, tool calls with their
  results, steps, compactions, and Canopy's turn dividers between them
  (`Canopy.Transcripts`). Everything shown was redacted first.

  Params: `session=<engine session id>` (default: the current one, else the
  newest), `turn=<turn summary event id>` (lands on that turn, highlighted),
  `entry=<entry id>` (highlighted when on the page).

  Entries are a stream, 50 at a time; Load older / Load newer page through.
  A tool row opens on click: the LiveView keeps the loaded tool bodies, the
  row renders its body only while open. Kind filters and the text clamps are
  browser-side. While the current session is open, the page follows it: an
  engine event for the session fetches what was added (debounced), and
  Follow keeps the newest entry in view; otherwise an "N new" pill says so.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Channels, Engine, Timeline, Transcripts}
  alias Canopy.Runtime.Activity
  alias CanopyWeb.TimelineComponents

  @follow_types [:step_completed, :tool_completed, :agent_completed, :agent_error]

  @impl true
  def mount(%{"id" => id, "agent_id" => agent_id}, _session, socket) do
    channel = Channels.get!(id)
    agent = Agents.get!(agent_id)

    {:ok,
     socket
     |> assign(:page_title, "@#{agent.name} · Transcript")
     |> assign(:channel, channel)
     |> assign(:agent, agent)
     |> assign(:sessions, Transcripts.list_sessions(channel.id, agent.id))
     |> assign(:session, nil)
     |> assign(:followed, nil)
     |> assign(:status, :loading)
     |> assign(:load_ref, nil)
     |> assign(:before, nil)
     |> assign(:after, nil)
     |> assign(:newer?, false)
     |> assign(:system_prompts, [])
     |> assign(:total, 0)
     |> assign(:compactions, 0)
     |> assign(:shown, 0)
     |> assign(:tools, %{})
     |> assign(:open, MapSet.new())
     |> assign(:highlight, nil)
     |> assign(:follow?, false)
     |> assign(:new_count, 0)
     |> assign(:refresh_timer, nil)
     |> stream_configure(:entries, dom_id: &dom_id/1)
     |> stream(:entries, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sessions = socket.assigns.sessions
    turn = turn_event(socket, params["turn"])

    {session, opts, highlight} =
      case turn && Transcripts.locate_turn(sessions, turn) do
        {session, opts} ->
          {session, opts, "transcript-turn-" <> turn.id}

        nil ->
          session =
            Enum.find(sessions, &(&1.engine_session_id == params["session"])) ||
              List.first(sessions)

          {session, [], params["entry"] && "transcript-entry-" <> params["entry"]}
      end

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:highlight, highlight)
     |> follow_session(session)
     |> load(opts)}
  end

  # Only a turn of this agent in this channel.
  defp turn_event(_socket, nil), do: nil

  defp turn_event(socket, id) do
    case Timeline.get(id) do
      %{event_type: "agent_turn_completed", channel_id: cid, agent_id: aid} = event
      when cid == socket.assigns.channel.id and aid == socket.assigns.agent.id ->
        event

      _ ->
        nil
    end
  end

  # The current session is the one that grows; any other is history.
  defp follow_session(socket, session) do
    sid = session && session.kind == :current && session.engine_session_id

    cond do
      not connected?(socket) or socket.assigns.followed == sid ->
        socket

      true ->
        if old = socket.assigns.followed,
          do: Phoenix.PubSub.unsubscribe(Canopy.PubSub, Engine.session_topic(old))

        if sid, do: Engine.subscribe_session(sid)
        assign(socket, :followed, sid || nil)
    end
  end

  # -- Loading ----------------------------------------------------------------------

  defp load(%{assigns: %{session: nil}} = socket, _opts) do
    socket
    |> assign(:status, :none)
    |> stream(:entries, [], reset: true)
  end

  defp load(socket, opts) do
    ref = make_ref()
    session = socket.assigns.session

    socket
    |> assign(:status, :loading)
    |> assign(:load_ref, ref)
    |> assign(:tools, %{})
    |> assign(:open, MapSet.new())
    |> assign(:new_count, 0)
    |> stream(:entries, [], reset: true)
    |> start_async(:page, fn ->
      {ref, Transcripts.page(session, Keyword.put(opts, :limit, page_size()))}
    end)
  end

  defp fetch(socket, name, opts) do
    ref = socket.assigns.load_ref
    session = socket.assigns.session

    start_async(socket, name, fn ->
      {ref, Transcripts.page(session, Keyword.put(opts, :limit, page_size()))}
    end)
  end

  @impl true
  def handle_async(_name, {:ok, {ref, _result}}, %{assigns: %{load_ref: current}} = socket)
      when ref != current,
      do: {:noreply, socket}

  def handle_async(:page, {:ok, {_ref, {:ok, page}}}, socket) do
    socket =
      socket
      |> assign(:status, :ok)
      |> assign(:before, page.before)
      |> assign(:after, page.after)
      |> assign(:newer?, page.newer?)
      |> assign(:system_prompts, page.system_prompts)
      |> assign(:total, page.total)
      |> assign(:compactions, page.compactions)
      |> assign(:shown, length(page.entries))
      |> keep_tools(page.entries)
      |> stream(:entries, page.entries, reset: true)

    socket =
      cond do
        socket.assigns.highlight ->
          push_event(socket, "transcript:scroll", %{id: socket.assigns.highlight})

        page.entries != [] ->
          push_event(socket, "transcript:bottom", %{})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_async(:page, {:ok, {_ref, {:error, reason}}}, socket),
    do: {:noreply, assign(socket, :status, {:error, reason})}

  def handle_async(:page, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :status, {:error, :failed})}

  def handle_async(:older, {:ok, {_ref, {:ok, page}}}, socket) do
    {:noreply,
     socket
     |> assign(:before, page.before)
     |> assign(:shown, socket.assigns.shown + length(page.entries))
     |> keep_tools(page.entries)
     |> then(fn socket ->
       page.entries
       |> Enum.reverse()
       |> Enum.reduce(socket, &stream_insert(&2, :entries, &1, at: 0))
     end)}
  end

  def handle_async(name, {:ok, {_ref, {:ok, page}}}, socket) when name in [:newer, :live] do
    count = length(page.entries)

    socket =
      socket
      |> assign(:after, page.after)
      |> assign(:newer?, page.newer?)
      |> assign(:system_prompts, page.system_prompts)
      |> assign(:total, page.total)
      |> assign(:compactions, page.compactions)
      |> assign(:shown, socket.assigns.shown + count)
      |> keep_tools(page.entries)
      |> stream(:entries, page.entries)

    socket =
      cond do
        name == :newer or count == 0 -> socket
        socket.assigns.follow? -> push_event(socket, "transcript:bottom", %{})
        true -> update(socket, :new_count, &(&1 + count))
      end

    {:noreply, socket}
  end

  # A page that could not be read later on keeps what is shown.
  def handle_async(_name, _result, socket), do: {:noreply, socket}

  # Tool bodies stay with the view so a row can open; nothing else does.
  defp keep_tools(socket, entries) do
    tools =
      for %{kind: :tool} = entry <- entries, into: socket.assigns.tools, do: {entry.id, entry}

    assign(socket, :tools, tools)
  end

  # -- Events -----------------------------------------------------------------------

  @impl true
  def handle_event("older", _params, %{assigns: %{before: cursor}} = socket)
      when is_binary(cursor),
      do: {:noreply, fetch(socket, :older, before: cursor)}

  def handle_event("newer", _params, %{assigns: %{after: cursor}} = socket)
      when is_binary(cursor),
      do: {:noreply, fetch(socket, :newer, after: cursor)}

  def handle_event(event, _params, socket) when event in ["older", "newer"],
    do: {:noreply, socket}

  def handle_event("pick_session", %{"session" => sid}, socket) do
    {:noreply, push_patch(socket, to: transcript_path(socket.assigns, session: sid))}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    case Map.fetch(socket.assigns.tools, id) do
      {:ok, entry} ->
        open = socket.assigns.open

        open =
          if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)

        {:noreply, socket |> assign(:open, open) |> stream_insert(:entries, entry)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("follow", _params, socket) do
    follow? = not socket.assigns.follow?
    socket = socket |> assign(:follow?, follow?) |> assign(:new_count, 0)

    {:noreply, if(follow?, do: push_event(socket, "transcript:bottom", %{}), else: socket)}
  end

  def handle_event("show_new", _params, socket) do
    {:noreply, socket |> assign(:new_count, 0) |> push_event("transcript:bottom", %{})}
  end

  # -- Following ------------------------------------------------------------------

  @impl true
  def handle_info({:engine_event, %{type: type}}, socket) when type in @follow_types do
    if socket.assigns.refresh_timer do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, :refresh_timer, Process.send_after(self(), :refresh, refresh_ms()))}
    end
  end

  def handle_info(:refresh, socket) do
    socket = assign(socket, :refresh_timer, nil)

    cond do
      # reading back through history: the Load newer button says there is more
      socket.assigns.newer? ->
        {:noreply, socket}

      socket.assigns.status == :ok and is_binary(socket.assigns.after) ->
        {:noreply, fetch(socket, :live, after: socket.assigns.after)}

      # nothing on disk yet when the page opened
      socket.assigns.status != :loading ->
        {:noreply, load(socket, [])}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Render -----------------------------------------------------------------------

  # Entries per page, and how long following waits for more events before
  # it reads (tests shorten both).
  defp page_size, do: Application.get_env(:canopy, :transcript_page_size, 50)
  defp refresh_ms, do: Application.get_env(:canopy, :transcript_refresh_ms, 500)

  defp dom_id(%{kind: :turn, turn: %{event_id: id}}), do: "transcript-turn-" <> id
  defp dom_id(%{id: id}), do: "transcript-entry-" <> id

  defp transcript_path(assigns, query) do
    ~p"/channels/#{assigns.channel.id}/agents/#{assigns.agent.id}/transcript?#{query}"
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:engine_label, assigns.session && Engine.label(assigns.session.engine))
      |> assign(:system, List.first(assigns.system_prompts))

    ~H"""
    <Layouts.app
      flash={@flash}
      repositories={@repositories}
      agents={@agents}
      dms={@dms}
      unread={@unread}
      threads_unread={@threads_unread}
      attention={@attention}
      schedule_counts={@schedule_counts}
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
      palette={@palette}
      setup={@setup}
      socket={@socket}
    >
      <Layouts.page
        title={"@#{@agent.name} · Transcript"}
        subtitle={channel_label(@channel)}
        max_width="max-w-4xl"
      >
        <:actions>
          <.link
            navigate={~p"/channels/#{@channel.id}"}
            id="transcript-back"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left-mini" class="size-4" /> Channel
          </.link>
        </:actions>

        <div id="transcript" class="flex min-w-0 flex-col gap-3" phx-hook=".TranscriptScroll">
          <section
            id="transcript-meta"
            class="flex flex-col gap-2 rounded-xl border border-base-300 bg-base-200 px-4 py-3 text-xs"
          >
            <p
              :if={@session}
              id="transcript-summary"
              class="flex flex-wrap items-center gap-x-2 gap-y-1 text-base-content/70"
            >
              <span class="font-semibold text-base-content">{@engine_label}</span>
              <span>·</span>
              <span>session <code class="font-mono">{short_id(@session.engine_session_id)}</code></span>
              <span :if={@session.at}>· {session_time(@session)}</span>
              <span :if={@status == :ok}>· {ngettext("1 entry", "%{count} entries", @total)}</span>
              <span :if={@status == :ok and @compactions > 0}>
                · {ngettext("1 compaction", "%{count} compactions", @compactions)}
              </span>
            </p>

            <form
              :if={length(@sessions) > 1}
              id="transcript-session-form"
              phx-change="pick_session"
              class="flex items-center gap-2"
            >
              <label for="transcript-session-picker" class="text-base-content/60">Session</label>
              <select
                id="transcript-session-picker"
                name="session"
                class="select select-xs w-full max-w-md border-base-300 bg-base-100"
              >
                <option
                  :for={session <- @sessions}
                  value={session.engine_session_id}
                  selected={@session && session.engine_session_id == @session.engine_session_id}
                >
                  {session_label(session)}
                </option>
              </select>
            </form>

            <div
              :if={@status == :ok}
              id="transcript-filters"
              class="flex flex-wrap items-center gap-1.5"
              role="group"
              aria-label="Show"
            >
              <span class="mr-1 text-base-content/60">Show</span>
              <.filter kind="prompt" label="Prompts" pressed />
              <.filter kind="text" label="Text" pressed />
              <.filter kind="tool" label="Tools" pressed />
              <.filter kind="note" label="Engine notes" pressed={false} />
              <button
                :if={@session && @session.kind == :current}
                type="button"
                id="transcript-follow"
                phx-click="follow"
                aria-pressed={to_string(@follow?)}
                class={[
                  "btn btn-xs ml-auto gap-1",
                  @follow? && "btn-primary btn-soft",
                  !@follow? && "btn-ghost"
                ]}
                title="Keep the newest entry in view as the agent works"
              >
                <span class={[
                  "size-1.5 rounded-full",
                  @follow? && "bg-success",
                  !@follow? && "bg-base-content/30"
                ]} /> Follow live
              </button>
            </div>
          </section>

          <section
            :if={@system && @status == :ok}
            id="transcript-system"
            class="flex flex-col gap-1 text-xs"
          >
            <details id="transcript-system-canopy" class="group rounded-lg border border-base-300">
              <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-1.5 text-base-content/70 hover:text-base-content">
                <.icon
                  name="hero-chevron-right-mini"
                  class="size-4 transition group-open:rotate-90"
                /> System prompt (Canopy, {chars(@system.canopy)})
              </summary>
              <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-words border-t border-base-300 px-3 py-2 font-mono text-[11px] text-base-content/80">{@system.canopy}</pre>
            </details>
            <details
              :if={@system.engine not in [nil, []]}
              id="transcript-system-engine"
              class="group rounded-lg border border-base-300"
            >
              <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-1.5 text-base-content/70 hover:text-base-content">
                <.icon
                  name="hero-chevron-right-mini"
                  class="size-4 transition group-open:rotate-90"
                />
                {@engine_label} built-in ({ngettext(
                  "1 section",
                  "%{count} sections",
                  length(@system.engine)
                )})
              </summary>
              <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-words border-t border-base-300 px-3 py-2 font-mono text-[11px] text-base-content/70">{Enum.join(@system.engine, "\n\n")}</pre>
            </details>
          </section>

          <%= case @status do %>
            <% :loading -> %>
              <div id="transcript-loading" class="flex flex-col gap-2" aria-busy="true">
                <div
                  :for={w <- ~w(w-2/3 w-1/2 w-5/6 w-1/3)}
                  class={["h-4 animate-pulse rounded bg-base-300/60", w]}
                />
              </div>
            <% :none -> %>
              <Layouts.empty_state
                id="transcript-empty"
                icon="hero-document-text"
                title="No turns yet"
              >
                @{@agent.name} hasn't worked in this channel yet.
              </Layouts.empty_state>
            <% {:error, reason} -> %>
              <.unavailable id="transcript-error" reason={reason} label={@engine_label} />
            <% :ok -> %>
              <Layouts.empty_state
                :if={@shown == 0}
                id="transcript-empty"
                icon="hero-document-text"
                title="No turns yet"
              >
                The session has no entries yet.
              </Layouts.empty_state>
          <% end %>

          <button
            :if={@status == :ok and @before}
            type="button"
            id="transcript-load-older"
            phx-click="older"
            class="btn btn-sm btn-ghost self-center"
          >
            <.icon name="hero-chevron-up-mini" class="size-4" /> Load older
          </button>

          <ol
            id="transcript-entries"
            phx-update="stream"
            class={[
              "transcript-list hide-note flex min-w-0 flex-col gap-1",
              @status != :ok && "hidden"
            ]}
          >
            <li
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              data-kind={entry.kind}
              class="min-w-0"
            >
              <.entry
                entry={entry}
                open={MapSet.member?(@open, entry.id)}
                highlight={@highlight == dom_id}
                channel_id={@channel.id}
                engine_label={@engine_label}
              />
            </li>
          </ol>

          <div
            :if={@status == :ok}
            class="sticky bottom-0 flex items-center justify-center gap-2 bg-base-100/90 py-2 backdrop-blur"
          >
            <button
              :if={@newer?}
              type="button"
              id="transcript-load-newer"
              phx-click="newer"
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-chevron-down-mini" class="size-4" /> Load newer
            </button>
            <button
              :if={@new_count > 0}
              type="button"
              id="transcript-new"
              phx-click="show_new"
              class="btn btn-xs btn-primary btn-soft rounded-full"
            >
              ↓ {ngettext("1 new entry", "%{count} new entries", @new_count)}
            </button>
          </div>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".TranscriptScroll">
          export default {
            mounted() {
              const scroller = () => this.el.closest(".overflow-y-auto")
              this.handleEvent("transcript:scroll", ({id}) => {
                requestAnimationFrame(() => {
                  const el = document.getElementById(id)
                  if (el) el.scrollIntoView({block: "center"})
                })
              })
              this.handleEvent("transcript:bottom", () => {
                requestAnimationFrame(() => {
                  const s = scroller()
                  if (s) s.scrollTop = s.scrollHeight
                })
              })
            }
          }
        </script>
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :pressed, :boolean, default: true

  # Browser-side: a class on the list hides the kind's rows (app.css).
  defp filter(assigns) do
    ~H"""
    <button
      type="button"
      id={"transcript-filter-#{@kind}"}
      aria-pressed={to_string(@pressed)}
      class="btn btn-xs btn-ghost gap-1 border-base-300 aria-pressed:border aria-pressed:bg-base-100 aria-[pressed=false]:text-base-content/50"
      phx-click={
        JS.toggle_class("hide-#{@kind}", to: "#transcript-entries")
        |> JS.toggle_attribute({"aria-pressed", "true", "false"})
      }
    >
      <.icon name="hero-check-mini" class="size-3.5 [[aria-pressed=false]_&]:invisible" />
      {@label}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :reason, :any, required: true
  attr :label, :string, default: nil

  defp unavailable(%{reason: :not_found} = assigns) do
    ~H"""
    <Layouts.empty_state
      id={@id}
      icon="hero-archive-box-x-mark"
      title={"#{@label} no longer has this session"}
    >
      Engines remove old sessions (Claude Code after <code>cleanupPeriodDays</code>, 30 days by default), and Canopy keeps no copy.
    </Layouts.empty_state>
    """
  end

  defp unavailable(%{reason: :unreachable} = assigns) do
    ~H"""
    <Layouts.empty_state id={@id} icon="hero-signal-slash" title={"Can't reach #{@label}"}>
      Check that it is running; its address is in <.link navigate={~p"/settings"} class="link">Settings</.link>.
    </Layouts.empty_state>
    """
  end

  defp unavailable(%{reason: :unsupported} = assigns) do
    ~H"""
    <Layouts.empty_state id={@id} icon="hero-no-symbol" title="This engine can't show transcripts" />
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <Layouts.empty_state
      id={@id}
      icon="hero-exclamation-triangle"
      title="Couldn't read this transcript"
    >
      {@label} answered something Canopy did not expect.
    </Layouts.empty_state>
    """
  end

  attr :entry, :map, required: true
  attr :open, :boolean, default: false
  attr :highlight, :boolean, default: false
  attr :channel_id, :string, required: true
  attr :engine_label, :string, default: nil

  defp entry(%{entry: %{kind: :turn}} = assigns) do
    ~H"""
    <div class={[
      "mt-3 flex items-center gap-2 rounded-lg px-1 py-1 text-[11px] font-medium",
      @highlight && "bg-primary/10 text-primary ring-1 ring-primary/30",
      !@highlight && "text-base-content/60"
    ]}>
      <span class="h-px min-w-4 flex-1 bg-base-300" />
      <span class="min-w-0 text-center">{turn_text(@entry)}</span>
      <.link
        navigate={~p"/channels/#{@channel_id}?#{[activity: @entry.turn.event_id]}"}
        class="btn btn-ghost btn-xs btn-square shrink-0"
        title="Open this turn's activity in the channel"
        aria-label="Open this turn's activity in the channel"
      >
        <.icon name="hero-arrow-top-right-on-square-mini" class="size-3.5" />
      </.link>
      <span class="h-px min-w-4 flex-1 bg-base-300" />
    </div>
    """
  end

  defp entry(%{entry: %{kind: :prompt}} = assigns) do
    ~H"""
    <div class={[
      "rounded-lg border px-3 py-2",
      @entry.steered? && "border-secondary/40 bg-secondary/5",
      !@entry.steered? && "border-base-300 bg-base-200/60",
      @highlight && "ring-2 ring-primary/40"
    ]}>
      <.entry_head entry={@entry} icon="hero-arrow-up-circle-mini" label="Prompt">
        <span :if={@entry.steered?} class="badge badge-xs badge-secondary badge-soft">
          sent mid-turn
        </span>
      </.entry_head>
      <div :if={@entry.attachments != []} class="mt-1 flex flex-wrap gap-1">
        <span
          :for={attachment <- @entry.attachments}
          class="badge badge-sm badge-ghost gap-1 font-normal"
        >
          <.icon
            name={if attachment.kind == :image, do: "hero-photo-mini", else: "hero-paper-clip-mini"}
            class="size-3.5"
          />
          {attachment.name || attachment.mime || to_string(attachment.kind)}
        </span>
      </div>
      <.clamped :if={@entry.text} id={@entry.id} text={@entry.text} lines={3} plain />
    </div>
    """
  end

  defp entry(%{entry: %{kind: kind}} = assigns) when kind in [:text, :reasoning] do
    ~H"""
    <div class={["px-3 py-1.5", @highlight && "rounded-lg ring-2 ring-primary/40"]}>
      <.entry_head
        entry={@entry}
        icon={
          if @entry.kind == :text,
            do: "hero-chat-bubble-left-ellipsis-mini",
            else: "hero-light-bulb-mini"
        }
        label={if @entry.kind == :text, do: "Text", else: "Reasoning"}
      />
      <div class={["mt-0.5 text-sm", @entry.kind == :reasoning && "italic text-base-content/70"]}>
        <.clamped id={@entry.id} text={@entry.text} lines={6} />
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :thinking_hidden}} = assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 px-3 py-0.5 text-xs text-base-content/45">
      <.icon name="hero-light-bulb-mini" class="size-3.5" />
      Thought — {@engine_label || "the engine"} doesn't record the text
    </p>
    """
  end

  defp entry(%{entry: %{kind: :tool}} = assigns) do
    ~H"""
    <div class={[
      "rounded-lg border",
      @entry.tool.status in [:error, :denied] && "border-error/30 bg-error/5",
      @entry.tool.status not in [:error, :denied] && "border-base-300/70",
      @highlight && "ring-2 ring-primary/40"
    ]}>
      <button
        type="button"
        id={"transcript-entry-#{@entry.id}-toggle"}
        phx-click="toggle"
        phx-value-id={@entry.id}
        aria-expanded={to_string(@open)}
        class="flex w-full min-w-0 items-center gap-2 px-3 py-1.5 text-left text-xs transition hover:bg-base-300/30"
      >
        <.icon name="hero-wrench-screwdriver-mini" class="size-4 shrink-0 text-base-content/50" />
        <span class="shrink-0 font-mono font-medium">{tool_name(@entry.tool.name)}</span>
        <span class="min-w-0 flex-1 truncate text-base-content/70">{@entry.tool.title}</span>
        <span
          :if={@entry.redacted?}
          id={"transcript-entry-#{@entry.id}-redacted"}
          class="badge badge-xs badge-warning badge-soft shrink-0"
          title="Secrets in this entry were masked"
        >
          redacted
        </span>
        <span class={["shrink-0", status_class(@entry.tool.status)]}>
          {status_mark(@entry.tool.status)}
        </span>
        <span :if={@entry.tool.duration_ms} class="shrink-0 tabular-nums text-base-content/50">
          {seconds(@entry.tool.duration_ms)}
        </span>
        <time :if={@entry.at} class="shrink-0 text-[10px] text-base-content/40 max-sm:hidden">
          {clock(@entry.at)}
        </time>
        <.icon
          name="hero-chevron-right-mini"
          class={["size-4 shrink-0 text-base-content/40 transition", @open && "rotate-90"]}
        />
      </button>
      <div
        :if={@open}
        id={"transcript-entry-#{@entry.id}-body"}
        class="grid min-w-0 gap-2 border-t border-base-300/70 p-2 md:grid-cols-2"
      >
        <div class="min-w-0">
          <p class="mb-0.5 text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
            Input
          </p>
          <pre class="max-h-80 overflow-auto rounded-md bg-base-200 p-2 font-mono text-[11px]">{present(@entry.tool.input) || "—"}</pre>
        </div>
        <div class="min-w-0">
          <p class="mb-0.5 text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
            Output<span :if={@entry.tool.truncated?} class="font-normal normal-case"> (truncated)</span>
          </p>
          <pre class="max-h-80 overflow-auto rounded-md bg-base-200 p-2 font-mono text-[11px]">{present(@entry.tool.output) || if(@entry.tool.status == :running, do: "no result", else: "—")}</pre>
        </div>
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :step}} = assigns) do
    ~H"""
    <p class="truncate px-3 text-[10px] text-base-content/45">
      · step · {step_text(@entry.step)}
    </p>
    """
  end

  defp entry(%{entry: %{kind: :compaction}} = assigns) do
    ~H"""
    <div class={[
      "my-2 rounded-lg border border-warning/40 bg-warning/5 px-3 py-2 text-xs",
      @highlight && "ring-2 ring-primary/40"
    ]}>
      <p class="flex flex-wrap items-center gap-1.5 font-semibold text-warning">
        <.icon name="hero-arrows-pointing-in-mini" class="size-4" />
        Context compacted · {@entry.compaction.trigger}
        <span :if={@entry.compaction.pre_tokens} class="font-normal text-base-content/70">
          · {TimelineComponents.format_tokens(@entry.compaction.pre_tokens)} → {TimelineComponents.format_tokens(
            @entry.compaction.post_tokens || 0
          )} tokens
        </span>
        <time :if={@entry.at} class="ml-auto font-normal text-base-content/50">
          {clock(@entry.at)}
        </time>
      </p>
      <p class="mt-0.5 text-base-content/60">
        The agent saw only the summary from here on; earlier entries stay readable above.
      </p>
      <details
        :if={@entry.compaction.summary}
        id={"transcript-entry-#{@entry.id}-summary"}
        class="mt-1"
      >
        <summary class="cursor-pointer text-base-content/70 hover:text-base-content">Summary</summary>
        <div class="mt-1 text-sm">
          <TimelineComponents.message_text body={@entry.compaction.summary} />
        </div>
      </details>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :system_changed}} = assigns) do
    ~H"""
    <details class="mx-3 my-1 text-xs">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 text-info">
        <.icon name="hero-adjustments-horizontal-mini" class="size-3.5" /> System prompt changed
        <time :if={@entry.at} class="text-[10px] text-base-content/40">{clock(@entry.at)}</time>
      </summary>
      <pre class="mt-1 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md bg-base-200 p-2 font-mono text-[11px]">{@entry.text}</pre>
    </details>
    """
  end

  defp entry(assigns) do
    ~H"""
    <div class="px-3 py-1 text-xs text-base-content/55">
      <.entry_head entry={@entry} icon="hero-cpu-chip-mini" label="Engine" />
      <.clamped :if={@entry.text} id={@entry.id} text={@entry.text} lines={3} plain />
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block

  defp entry_head(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
      <.icon name={@icon} class="size-3.5" />
      {@label}
      <time :if={@entry.at} class="font-normal normal-case tracking-normal">{clock(@entry.at)}</time>
      {render_slot(@inner_block)}
      <span
        :if={@entry.redacted?}
        id={"transcript-entry-#{@entry.id}-redacted"}
        class="badge badge-xs badge-warning badge-soft normal-case tracking-normal"
        title="Secrets in this entry were masked"
      >
        redacted
      </span>
    </p>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :lines, :integer, required: true
  attr :plain, :boolean, default: false

  # Long text starts clamped; "more" lifts the clamp in the browser.
  defp clamped(assigns) do
    assigns =
      assigns
      |> assign(:long?, long?(assigns.text, assigns.lines))
      |> assign(:clamp, if(assigns.lines == 3, do: "line-clamp-3", else: "line-clamp-6"))

    ~H"""
    <div
      id={"transcript-entry-#{@id}-text"}
      class={["mt-0.5 min-w-0 break-words", @long? && @clamp]}
    >
      <%= if @plain do %>
        <p class="whitespace-pre-wrap text-sm">{@text}</p>
      <% else %>
        <TimelineComponents.message_text body={@text} />
      <% end %>
    </div>
    <button
      :if={@long?}
      type="button"
      class="link link-hover mt-0.5 text-[11px] text-base-content/60"
      phx-click={JS.toggle_class(@clamp, to: "#transcript-entry-#{@id}-text")}
    >
      more / less
    </button>
    """
  end

  # -- Helpers ----------------------------------------------------------------------

  defp long?(text, lines),
    do: length(String.split(text, "\n")) > lines or String.length(text) > lines * 110

  defp channel_label(channel) do
    if Channels.dm?(channel), do: Channels.dm_label(channel), else: "#" <> channel.name
  end

  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "…"
  defp short_id(id), do: id

  defp stamp(%DateTime{} = at),
    do: at |> Canopy.Schedules.When.to_local_naive() |> Calendar.strftime("%b %-d %H:%M")

  defp stamp(_at), do: "—"

  defp clock(at),
    do: at |> Canopy.Schedules.When.to_local_naive() |> Calendar.strftime("%H:%M:%S")

  defp session_time(%{kind: :current, at: at}), do: "started " <> stamp(at)
  defp session_time(%{kind: :reset, at: at}), do: "reset " <> stamp(at)
  defp session_time(%{kind: :earlier, at: at}), do: "last turn " <> stamp(at)
  defp session_time(%{at: at}), do: "started " <> stamp(at)

  defp session_label(%{kind: :current} = s),
    do: "Current · #{session_time(s)} · #{short_id(s.engine_session_id)}"

  defp session_label(%{kind: :reset} = s),
    do: "Reset · #{session_time(s)} · #{short_id(s.engine_session_id)}"

  defp session_label(%{kind: :earlier} = s),
    do: "Earlier · #{session_time(s)} · #{short_id(s.engine_session_id)}"

  defp session_label(%{kind: :delegated} = s),
    do: "Delegated (old) · #{s.delegation_id || short_id(s.engine_session_id)} · #{stamp(s.at)}"

  defp chars(nil), do: "empty"

  defp chars(text) when byte_size(text) >= 1000,
    do: "#{Float.round(byte_size(text) / 1000, 1)}k chars"

  defp chars(text), do: "#{String.length(text)} chars"

  @triggers %{
    "user" => "your message",
    "agent" => "an agent's message",
    "delegation" => "a delegation",
    "handoff" => "a handoff",
    "scheduled" => "a schedule",
    "watch" => "a watch",
    "playbook" => "a playbook",
    "playbook_nudge" => "a playbook nudge",
    "lock" => "a lock",
    "escalation" => "an escalation"
  }

  defp turn_text(%{at: at, turn: turn}) do
    [
      "Turn",
      at && TimelineComponents.short_time(at),
      Map.get(@triggers, turn.trigger) && "woken by " <> @triggers[turn.trigger],
      Map.get(turn, :light?) && "light model",
      Map.get(turn, :escalated?) && "escalated",
      Map.get(turn, :passed?) && TimelineComponents.pass_phrase(Map.get(turn, :pass_note)),
      turn.steered > 0 &&
        ngettext("took 1 message mid-turn", "took %{count} messages mid-turn", turn.steered),
      is_integer(turn.tools) && turn.tools > 0 && ngettext("1 call", "%{count} calls", turn.tools),
      is_number(turn.cost) && turn.cost > 0 && Activity.format_cost(turn.cost),
      TimelineComponents.format_duration(turn.duration_ms),
      turn.outcome not in [nil, "ok"] && turn.outcome
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp step_text(step) do
    tokens = step.tokens || %{}

    [
      tokens["input"] && "#{TimelineComponents.format_tokens(tokens["input"])} in",
      tokens["output"] && "#{TimelineComponents.format_tokens(tokens["output"])} out",
      step.model,
      is_number(step.cost) && step.cost > 0 && Activity.format_cost(step.cost),
      Map.get(step, :files, []) != [] &&
        "changed " <> Enum.map_join(step.files, ", ", &Path.basename/1)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp present(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp present(_), do: nil

  defp tool_name("mcp__canopy__" <> name), do: "canopy_" <> name
  defp tool_name(name), do: name

  defp status_mark(:ok), do: "✓"
  defp status_mark(:error), do: "✕"
  defp status_mark(:denied), do: "denied"
  defp status_mark(_), do: "…"

  defp status_class(:ok), do: "text-success"
  defp status_class(:running), do: "text-base-content/50"
  defp status_class(_), do: "text-error"

  defp seconds(ms) when ms < 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp seconds(ms), do: TimelineComponents.format_duration(ms)
end
