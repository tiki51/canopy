defmodule CanopyWeb.ChannelLive do
  @moduledoc """
  The main screen: one channel's header, feed, live agent telemetry, permission
  cards, pending handoffs, task form, the repository's locks, and the composer.

  `?msg=<message id>` points at a message in the feed (search results link
  there): it is scrolled to and flashed, and one older than the loaded feed
  opens a window of history around it. While the feed shows history, new
  events are held back and counted on the Jump to latest pill; Load newer
  pages forward, and the pill (or sending a message) returns to the live
  feed. A thread reply opens in its thread instead (`?thread=…&reply=…`).

  A thread opens in the side panel beside the feed (`?thread=<message id>`,
  with `&reply=<id>` to point at one reply): its own stream, its own composer,
  and the live card and cards of an agent working for it. The feed shows only
  a thread's root and its summary row. The side panel is one slot shared by
  every panel kind; only one is open at a time. The other kind is an
  agent's activity (`?activity=<turn event id>`, or `?activity=live:<agent
  id>` for a turn still running, which moves to the finished turn's id when
  it ends). A URL naming both opens the thread.

  Activity cards (the live card of a working agent, a finished turn's card)
  render only their header until opened. What is open lives here: `act`
  holds the open live cards (by agent), the open finished cards (by event),
  the open rows (`{card id, row key}`), the details loaded for finished
  cards, and whether this browser opens live cards by itself. A live card
  that was open when its turn ends arrives open as the finished card.
  Finished cards are stream items, so a change to one re-inserts it.

  The process subscribes to the channel topic *before* loading the feed so no
  event can slip between the query and the subscription. Live navigation between
  channels reuses this process, so all per-channel state is (re)built in
  `handle_params/3`.
  """

  use CanopyWeb, :live_view

  import CanopyWeb.TimelineComponents

  alias Canopy.{
    Agents,
    Channels,
    Costs,
    Documents,
    Messages,
    Handoffs,
    Locks,
    Playbooks,
    PermissionRequests,
    QuestionRequests,
    Reactions,
    Repositories,
    Runtime,
    Schedules,
    Settings,
    Tasks,
    Teams,
    Threads,
    Timeline,
    Unread,
    Users
  }

  alias Canopy.Engine.Event
  alias Canopy.Playbooks.{Run, Runs}
  alias Canopy.Runtime.{Activity, Commands}
  alias Canopy.Timeline.ActivityDetails
  alias CanopyWeb.{Nav, PlaybookComponents, PlaybookStart}
  alias Canopy.Tasks.Task

  @page_size 100
  # events either side of a message a link points at, when it is older than the feed
  @history_window 50
  @thread_page 200
  @archived_answer "This channel is archived. Unarchive (Reopen) the channel to answer."
  @branch_interval 15_000
  # streamed text renders at most this often (ms); tool events render at once
  @text_flush_ms 100

  # -- Lifecycle ---------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Schedules.subscribe()
      Documents.subscribe()
      Teams.subscribe()
      Playbooks.subscribe()
      Runs.subscribe()
    end

    {:ok,
     socket
     |> assign(:channel, nil)
     |> assign(:compact?, true)
     # the pinned brief opened up; this browser remembers it (Pref hook)
     |> assign(:brief_expanded?, false)
     |> assign(:branch_timer, nil)
     |> assign(:picked, [])
     |> assign(:thread_picked, [])
     |> assign(:library, nil)
     |> assign(:thread, nil)
     |> assign(:activity, nil)
     # the Details panel, which this browser remembers from lg up (Pref hook);
     # `details_wide?` once the browser says it is that wide
     |> assign(:details?, false)
     |> assign(:details_wide?, false)
     |> assign(:act, new_act(false))
     |> assign(:pending_text, %{})
     |> assign(:first_page, nil)
     |> assign(:seen_runs, nil)
     |> allow_upload(:files,
       accept: :any,
       max_entries: Messages.max_attachments(),
       max_file_size: Documents.max_bytes(),
       auto_upload: true
     )
     |> allow_upload(:thread_files,
       accept: :any,
       max_entries: Messages.max_attachments(),
       max_file_size: Documents.max_bytes(),
       auto_upload: true
     )
     |> stream_configure(:timeline, dom_id: &"evt-#{&1.id}")
     |> stream_configure(:thread, dom_id: &"thread-evt-#{&1.id}")
     |> stream(:timeline, [])
     |> stream(:thread, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    socket =
      case socket.assigns.channel do
        %{id: ^id} -> socket
        _ -> load_channel(socket, id)
      end

    params = reply_params(params)

    {:noreply,
     socket
     |> attach_from_params(params)
     |> panel_from_params(params)
     |> yield_to_panel()
     |> message_from_params(params)
     |> stream_first_page()}
  end

  # A newly loaded channel's feed goes in once the params have had their say:
  # a link to an old message replaces the first page with history around it.
  defp stream_first_page(%{assigns: %{first_page: events}} = socket) when is_list(events),
    do: socket |> assign(:first_page, nil) |> stream(:timeline, events, reset: true)

  defp stream_first_page(socket), do: socket

  # `?msg=` naming a thread reply opens it where it lives: its thread.
  defp reply_params(%{"msg" => id} = params)
       when is_binary(id) and not is_map_key(params, "thread") do
    case Messages.get(id) do
      %{thread_id: root_id} when is_binary(root_id) ->
        params |> Map.delete("msg") |> Map.merge(%{"thread" => root_id, "reply" => id})

      _ ->
        params
    end
  end

  defp reply_params(params), do: params

  # `?msg=msg_…` points at a message in the feed: it is scrolled to and
  # flashed; one older than the loaded feed opens a window of history around
  # it first. A link is followed once, not again on every patch.
  defp message_from_params(%{assigns: %{msg_target: id}} = socket, %{"msg" => id}), do: socket

  defp message_from_params(socket, %{"msg" => id}) when is_binary(id) do
    socket = assign(socket, :msg_target, id)

    case Timeline.for_message(id) do
      %{channel_id: channel_id, in_channel: true} = event
      when channel_id == socket.assigns.channel.id ->
        socket
        |> then(
          &if(MapSet.member?(&1.assigns.message_ids, id), do: &1, else: open_history(&1, event))
        )
        |> push_event("timeline:highlight", %{id: "evt-" <> event.id})

      _ ->
        put_flash(socket, :error, "That message isn't in this channel.")
    end
  end

  defp message_from_params(socket, _params), do: assign(socket, :msg_target, nil)

  # The feed becomes a window of history around `event`. When that window
  # already reaches the newest event, the feed is simply live again.
  defp open_history(socket, event) do
    channel_id = cid(socket)

    events =
      Timeline.list_around(channel_id, event.id,
        before: @history_window,
        after: @history_window,
        scope: :channel
      )

    newest = List.last(events)
    latest = channel_id |> Timeline.list(limit: 1, scope: :channel) |> List.first()

    socket
    |> reset_feed(events)
    |> assign(:has_earlier?, Enum.count(events, &(&1.id < event.id)) >= @history_window)
    |> assign(:window, if(latest && latest.id != newest.id, do: :history, else: :live))
    |> assign(:newest_event_id, newest.id)
    |> assign(:held, 0)
  end

  # Back to the live feed: its newest page, pinned to the bottom.
  defp to_latest(socket) do
    events = Timeline.list(cid(socket), limit: @page_size, scope: :channel)

    socket
    |> reset_feed(events)
    |> assign(:has_earlier?, length(events) >= @page_size)
    |> assign(:window, :live)
    |> assign(:newest_event_id, nil)
    |> assign(:held, 0)
    |> push_event("timeline:bottom", %{})
  end

  # The feed's stream and what is known about what it holds, replaced.
  defp reset_feed(socket, events) do
    socket
    |> assign(:first_page, nil)
    |> assign(:summaries, Messages.thread_summaries(root_ids(events)))
    |> assign(:message_ids, message_ids(events))
    |> assign(:turn_ids, turn_ids(events))
    |> assign(:receipts, Map.merge(socket.assigns.receipts, receipts(events)))
    |> assign(:oldest_event_id, events |> List.first() |> then(&(&1 && &1.id)))
    |> stream(:timeline, events, reset: true)
  end

  # Another page of the feed (earlier or newer), added to what it holds.
  defp merge_feed(socket, events) do
    socket
    |> assign(
      :summaries,
      Map.merge(socket.assigns.summaries, Messages.thread_summaries(root_ids(events)))
    )
    |> assign(:message_ids, MapSet.union(socket.assigns.message_ids, message_ids(events)))
    |> assign(:turn_ids, MapSet.union(socket.assigns.turn_ids, turn_ids(events)))
    |> assign(:receipts, Map.merge(receipts(events), socket.assigns.receipts))
  end

  # The side panel shows one thing: a thread, or an agent's activity.
  defp panel_from_params(socket, %{"activity" => target} = params)
       when not is_map_key(params, "thread") do
    socket |> close_thread() |> open_activity(target)
  end

  defp panel_from_params(socket, params),
    do: socket |> close_activity() |> thread_from_params(params)

  # `?activity=live:<agent>` shows a running turn; once the agent is no
  # longer working (a reload after it finished), its latest turn instead.
  defp open_activity(socket, "live:" <> agent_id) do
    cond do
      Map.has_key?(socket.assigns.telemetry, agent_id) ->
        socket |> close_activity() |> assign(:activity, %{kind: :live, agent_id: agent_id})

      turn = Timeline.last_turn(cid(socket), agent_id) ->
        push_patch(socket, to: activity_path(cid(socket), turn.id), replace: true)

      true ->
        socket
        |> close_activity()
        |> put_flash(:error, "That agent has no activity in this channel.")
    end
  end

  defp open_activity(socket, event_id) do
    case Timeline.get(event_id) do
      %{event_type: "agent_turn_completed", channel_id: channel_id} = event
      when channel_id == socket.assigns.channel.id ->
        socket
        |> close_activity()
        |> assign(:activity, %{kind: :turn, event: event})
        |> refresh_turn(event)

      _ ->
        socket
        |> close_activity()
        |> put_flash(:error, "That activity is not in this channel.")
    end
  end

  defp close_activity(%{assigns: %{activity: %{kind: :turn, event: event}}} = socket),
    do: socket |> assign(:activity, nil) |> refresh_turn(event)

  defp close_activity(socket), do: assign(socket, :activity, nil)

  defp panel_open?(%{assigns: assigns}), do: assigns.thread != nil or assigns.activity != nil

  # The side panel holds one thing: a thread or an activity closes Details,
  # and closing them later leaves the slot empty (it is not restored).
  defp yield_to_panel(%{assigns: %{details?: true}} = socket) do
    if panel_open?(socket), do: hide_details(socket), else: socket
  end

  defp yield_to_panel(socket), do: socket

  # Details takes the side panel: a thread or an activity in it closes (the
  # plain channel path), and this browser remembers it open.
  defp show_details(socket) do
    socket
    |> then(&if(panel_open?(&1), do: push_patch(&1, to: ~p"/channels/#{cid(&1)}"), else: &1))
    |> assign(:details?, true)
    |> push_event("pref", %{key: "channel-details", value: "open"})
  end

  # Closing Details closes what was open in it, so it reopens collapsed.
  defp hide_details(socket) do
    socket
    |> assign(:details?, false)
    |> assign(
      editing_task?: false,
      editing_members?: false,
      editing_playbook?: false,
      editing_schedules?: false,
      editing_budget?: false,
      taking_lock?: false
    )
    |> push_event("pref", %{key: "channel-details", value: "closed"})
  end

  # A toggle in Details flips its part while Details is showing; from
  # anywhere else (the palette, an old link) it opens Details on that part,
  # whatever the flag was.
  defp toggle_in_details(socket, flag, section) do
    if socket.assigns.details? and not panel_open?(socket) do
      assign(socket, flag, not Map.fetch!(socket.assigns, flag))
    else
      socket
      |> show_details()
      |> assign(flag, true)
      |> push_event("details:focus", %{section: section})
    end
  end

  # A header chip opens Details at its section, opening what it controls.
  defp open_section(socket, "spend"), do: assign(socket, :editing_budget?, true)
  defp open_section(socket, "playbook"), do: assign(socket, :editing_playbook?, true)
  defp open_section(socket, _section), do: socket

  @doc false
  def activity_path(channel_id, target), do: ~p"/channels/#{channel_id}?#{[activity: target]}"

  # What is open on the activity cards; reset with the channel.
  defp new_act(auto_open?) do
    %{
      open_live: MapSet.new(),
      open_turns: MapSet.new(),
      open_rows: MapSet.new(),
      details: %{},
      auto_open?: auto_open?
    }
  end

  # `/channels/:id?attach=doc_…` arrives from the Files page's "Share to":
  # the document lands in the composer as a picked file, ready to send.
  defp attach_from_params(socket, %{"attach" => id}) do
    case Documents.get(id) do
      nil -> put_flash(socket, :error, "That file no longer exists.")
      document -> pick(socket, document)
    end
  end

  defp attach_from_params(socket, _params), do: socket

  # `?thread=msg_…` opens that thread in the side panel; any message of the
  # thread will do, and the root is loaded from the database, so a thread
  # older than the loaded feed opens too. `&reply=msg_…` points at one reply.
  # Without the param the panel is closed.
  defp thread_from_params(socket, %{"thread" => id} = params) do
    case Messages.thread_root(id) do
      %{channel_id: channel_id} = root when channel_id == socket.assigns.channel.id ->
        open_thread(socket, root, target_from(params["reply"] || id, root))

      _ ->
        socket
        |> close_thread()
        |> put_flash(:error, "That thread is not in this channel.")
    end
  end

  defp thread_from_params(socket, _params), do: close_thread(socket)

  # A link to a reply (`&reply=`, or `?thread=` naming a reply) marks that
  # reply, when it is in the thread.
  defp target_from(id, %{id: id}), do: nil

  defp target_from(id, %{id: root_id}) do
    case Messages.get(id) do
      %{thread_id: ^root_id} -> id
      _ -> nil
    end
  end

  # Another thread starts with an empty composer: the draft (cleared by the
  # Composer hook when the form's data-scope changes), the picked files, and
  # the uploads in flight belong to the thread they were meant for. The same
  # thread again (a link to one of its replies) keeps them.
  defp open_thread(socket, root, target) do
    previous = open_root(socket.assigns)
    user = socket.assigns.user
    :ok = Threads.mark_read(root.id, user)
    events = Timeline.list_thread(root.id, limit: @thread_page)

    socket
    |> assign(:thread, %{
      root: root,
      following?: Threads.following?(root.id, user),
      count: reply_count(root.id),
      target: target,
      # the messages the panel has rendered: only those are re-rendered in place
      loaded: message_ids(events)
    })
    |> assign(:receipts, Map.merge(socket.assigns.receipts, receipts(events)))
    |> stream(:thread, events, reset: true)
    |> then(fn socket ->
      if previous == root.id,
        do: socket,
        else:
          socket
          |> reset_thread_composer()
          |> push_event("composer:focus", %{id: "thread-composer-input"})
    end)
    |> refresh_thread_unread()
    |> refresh_roots([previous, root.id])
  end

  defp reset_thread_composer(socket) do
    socket.assigns.uploads.thread_files.entries
    |> Enum.reduce(socket, &cancel_upload(&2, :thread_files, &1.ref))
    |> assign(:thread_picked, [])
    |> assign_thread_composer("")
  end

  defp close_thread(%{assigns: %{thread: nil}} = socket), do: socket

  defp close_thread(socket) do
    previous = open_root(socket.assigns)

    socket
    |> assign(:thread, nil)
    |> reset_thread_composer()
    |> stream(:thread, [], reset: true)
    |> refresh_roots([previous])
  end

  defp open_root(%{thread: %{root: %{id: id}}}), do: id
  defp open_root(_assigns), do: nil

  defp reply_count(root_id),
    do: get_in(Messages.thread_summaries([root_id]), [root_id, :count]) || 0

  defp pick(socket, document, target \\ "main") do
    key = picked_key(target)
    picked = Map.fetch!(socket.assigns, key)

    if Enum.any?(picked, &(&1.id == document.id)),
      do: socket,
      else: assign(socket, key, picked ++ [document])
  end

  defp load_channel(socket, id) do
    socket = leave_channel(socket)

    if connected?(socket) do
      :ok = Timeline.subscribe(id)
      {:ok, _pid} = Runtime.ensure_channel(id)
    end

    channel = Channels.get!(id)
    members = Channels.members(channel)
    user = Users.local()
    Unread.mark_read(id, user)
    names = Map.new(Agents.list(), &{&1.id, &1.name})
    events = Timeline.list(id, limit: @page_size, scope: :channel)
    statuses = Runtime.status(id)

    agent_statuses =
      Map.new(members, fn member -> {member.id, Map.get(statuses, member.id, :idle)} end)

    telemetry =
      for {agent_id, status} when status in [:busy, :awaiting_user] <- agent_statuses,
          into: %{} do
        {agent_id, Runtime.telemetry(id, agent_id)}
      end

    auto_open? = socket.assigns.act.auto_open?

    act =
      if auto_open?,
        do: %{new_act(true) | open_live: MapSet.new(Map.keys(telemetry))},
        else: new_act(false)

    socket
    |> assign(:page_title, channel_title(channel))
    |> assign(:channel, channel)
    |> assign(:members, members)
    |> assign(:member_names, Enum.map(members, & &1.name))
    |> assign_mention_sources(channel)
    |> assign(:user, user)
    |> assign(:names, names)
    |> assign(:agent_statuses, agent_statuses)
    |> assign(:paused?, Runtime.paused?(id))
    |> assign(:stopped?, Runtime.stopped?(id))
    |> assign(:telemetry, telemetry)
    |> assign(:act, act)
    |> assign(:pending_text, %{})
    |> assign(:activity, nil)
    |> assign(:receipts, receipts(events))
    |> assign(:turn_ids, turn_ids(events))
    |> assign(:turn_threads, Runtime.turn_threads(id))
    |> assign(:steers, Runtime.steers(id))
    |> then(&assign(&1, :queued, queued_of(&1.assigns.steers)))
    |> assign(:interrupt_on?, Settings.interrupt_on_mention?())
    |> assign(:message_ids, message_ids(events))
    |> assign(:summaries, Messages.thread_summaries(root_ids(events)))
    |> assign(:thread_unread, thread_unread(Map.put(socket.assigns, :user, user)))
    |> assign(:thread, nil)
    |> assign(:thread_picked, [])
    |> stream(:thread, [], reset: true)
    |> assign(:oldest_event_id, events |> List.first() |> then(&(&1 && &1.id)))
    |> assign(:has_earlier?, length(events) >= @page_size)
    |> assign(:window, :live)
    |> assign(:newest_event_id, nil)
    |> assign(:held, 0)
    |> assign(:msg_target, nil)
    |> assign(:pending_handoffs, Handoffs.pending_for_channel(id))
    |> assign(:pending_permissions, PermissionRequests.pending_for_channel(id))
    |> assign(:pending_questions, QuestionRequests.pending_for_channel(id))
    |> assign(:question_drafts, %{})
    |> assign_cards()
    |> assign(:editing_task?, false)
    |> close_brief_form()
    |> assign(:brief_history, nil)
    |> assign(:brief_viewing, nil)
    |> assign(:editing_members?, false)
    |> assign(:addable_agents, [])
    |> assign(:addable_teams, [])
    |> assign(:editing_budget?, false)
    |> assign(:spent, Costs.channel_total(id))
    |> assign(:editing_schedules?, false)
    |> assign(:schedules, Schedules.list_for_channel(id))
    |> assign(:taking_lock?, false)
    |> assign(:editing_playbook?, false)
    |> assign_run()
    |> assign(:lock_form, to_form(%{"name" => Locks.default_name(), "reason" => ""}, as: :lock))
    |> watch_locks()
    |> assign(:changes, nil)
    |> assign_task(Tasks.for_channel(id))
    |> assign_composer("")
    |> assign_branch()
    |> assign(:first_page, events)
    |> schedule_branch_refresh()
  end

  # The channel's playbook run (if one is in progress) for the header chip and
  # the panel; without one, the start form and the last few finished runs.
  defp assign_run(socket, params \\ %{}) do
    channel = socket.assigns.channel
    run = Runs.active_for_channel(channel.id)
    playbooks = Playbooks.list(enabled: true)

    socket
    |> assign(:run, run)
    |> assign(:run_playbooks, playbooks)
    |> assign(:run_agents, Canopy.Agents.list_active())
    |> assign(
      :recent_runs,
      if(run, do: [], else: channel.id |> Runs.list_for_channel(3) |> Enum.reject(&Run.live?/1))
    )
    |> assign(:start_form, PlaybookStart.form(params, playbooks, channel))
    |> first_view_of_run()
  end

  # The run panel opens by itself, in Details, the first time this browser
  # sees a run (the Pref hook reports the runs seen, `seen_runs`); after that
  # it starts collapsed and the header chip opens it. Until the browser has
  # reported, nothing opens; below lg (Details is an overlay there) or with
  # a thread or activity in the side panel, Details stays as it is.
  defp first_view_of_run(%{assigns: %{run: %{id: id}, seen_runs: seen}} = socket)
       when is_list(seen) do
    if id in seen do
      socket
    else
      seen = Enum.take([id | seen], 50)

      socket
      |> assign(:seen_runs, seen)
      |> assign(:editing_playbook?, true)
      |> push_event("pref", %{key: "playbook-seen", value: Enum.join(seen, ",")})
      |> then(fn socket ->
        if socket.assigns.details_wide? and not panel_open?(socket),
          do:
            socket
            |> assign(:details?, true)
            |> push_event("details:focus", %{section: "playbook"}),
          else: socket
      end)
    end
  end

  defp first_view_of_run(socket), do: socket

  defp leave_channel(%{assigns: %{channel: nil}} = socket), do: socket

  defp leave_channel(%{assigns: %{channel: channel, branch_timer: timer}} = socket) do
    if connected?(socket), do: Timeline.unsubscribe(channel.id)
    if timer, do: Process.cancel_timer(timer)
    socket |> unwatch_locks() |> assign(:branch_timer, nil)
  end

  # Locks belong to the repository, so every channel on it shows the same
  # ones; the view follows the repository's lock topic (a DM can move).
  defp watch_locks(%{assigns: %{channel: channel}} = socket) do
    repository_id = channel.repository_id

    socket =
      if Map.get(socket.assigns, :locks_repository_id) == repository_id do
        socket
      else
        socket = unwatch_locks(socket)
        if connected?(socket), do: Locks.subscribe(repository_id)
        assign(socket, :locks_repository_id, repository_id)
      end

    socket
    |> assign(:locks, Locks.list(repository_id))
    |> assign(:now, DateTime.utc_now())
  end

  defp unwatch_locks(socket) do
    case Map.get(socket.assigns, :locks_repository_id) do
      nil ->
        socket

      repository_id ->
        if connected?(socket), do: Locks.unsubscribe(repository_id)
        assign(socket, :locks_repository_id, nil)
    end
  end

  # The feed holds a thread's root and, when one was also sent to the
  # channel, a reply; never the rest of the thread.
  defp message_ids(events) do
    for %{event_type: "message", message: %{id: id}} <- events, into: MapSet.new(), do: id
  end

  defp root_ids(events) do
    for %{event_type: "message", message: %{id: id, thread_id: nil}} <- events, do: id
  end

  # The finished turns the feed holds, so a change to one re-renders it in
  # place (and a turn outside the loaded page is never appended).
  defp turn_ids(events) do
    for %{event_type: "agent_turn_completed", id: id, in_channel: true} <- events,
        into: MapSet.new(),
        do: id
  end

  # message id => the turn that posted it, for the receipt chip on the message.
  defp receipts(events) do
    for %{event_type: "agent_turn_completed", payload: payload} = event <- events,
        message_id <- List.wrap(payload["message_ids"]),
        is_binary(message_id),
        into: %{} do
      {message_id, receipt(event)}
    end
  end

  defp receipt(%{id: id, payload: payload}),
    do: %{event_id: id, tools: payload["tools"], duration_ms: payload["duration_ms"]}

  # The followed threads with unread replies, from the map CanopyWeb.Nav keeps
  # current (`Nav.refresh_unread/1`), so the dots cost no query of their own.
  defp thread_unread(assigns) do
    case Map.get(assigns, :thread_unread_summary) do
      %{} = summary -> summary |> Map.keys() |> MapSet.new()
      nil -> assigns.user |> Unread.thread_summary() |> Map.keys() |> MapSet.new()
    end
  end

  # Stream items are rendered once, when they are inserted: an assign the item
  # depends on (a summary, the open thread, a working agent, an unread dot)
  # does not re-render it. Re-insert the roots that changed, if loaded; a root
  # outside the loaded feed would otherwise be appended to it.
  defp refresh_roots(socket, root_ids) do
    root_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(socket.assigns.message_ids, &1))
    |> Enum.reduce(socket, fn root_id, socket ->
      case Timeline.for_message(root_id) do
        nil -> socket
        event -> stream_insert(socket, :timeline, event)
      end
    end)
  end

  # The read state changed here: the rail's badge, then the dots, follow.
  defp refresh_thread_unread(socket), do: socket |> Nav.refresh_unread() |> apply_thread_unread()

  # The unread dots follow Nav's current map; the roots whose dot changed
  # re-render.
  defp apply_thread_unread(socket) do
    unread = thread_unread(socket.assigns)
    changed = MapSet.symmetric_difference(unread, socket.assigns.thread_unread)

    socket
    |> assign(:thread_unread, unread)
    |> refresh_roots(MapSet.to_list(changed))
  end

  defp assign_task(socket, task) do
    form = if task, do: to_form(Tasks.change(task), id: "task-form"), else: nil
    socket |> assign(:task, task) |> assign(:task_form, form)
  end

  defp assign_composer(socket, body) do
    assign(socket, :composer, to_form(%{"body" => body}, as: :message, id: "composer-form"))
  end

  defp assign_thread_composer(socket, body) do
    assign(
      socket,
      :thread_composer,
      to_form(%{"body" => body}, as: :message, id: "thread-composer-form")
    )
  end

  # The library picks into the composer it was opened from: the channel's
  # ("main") or the thread panel's ("thread").
  defp load_library(socket, q, target \\ nil) do
    target = target || (socket.assigns.library && socket.assigns.library.target) || "main"
    picked = socket.assigns |> Map.fetch!(picked_key(target)) |> Enum.map(& &1.id)
    documents = Documents.list(search: q, limit: 30) |> Enum.reject(&(&1.id in picked))
    assign(socket, :library, %{q: q, documents: documents, target: target})
  end

  defp picked_key("thread"), do: :thread_picked
  defp picked_key(_main), do: :picked

  # A mention of an agent that is not in the channel wakes nobody; say so and
  # point at /i, instead of leaving the user waiting. When the outsiders all
  # came in through one team mention, one `/i @team` brings them all.
  defp outsider_hint(socket, %Messages.Message{mentions: ids} = message) when ids != [] do
    members = MapSet.new(socket.assigns.members, & &1.id)
    outsider_ids = Enum.reject(ids, &MapSet.member?(members, &1))

    outsiders =
      outsider_ids
      |> Enum.map(&Map.get(socket.assigns.names, &1))
      |> Enum.reject(&is_nil/1)

    case outsiders do
      [] ->
        socket

      names ->
        mentions = Enum.map_join(names, ", ", &("@" <> &1))

        invites =
          case outsider_team(message, outsider_ids) do
            nil -> Enum.map_join(names, " ", &("/i @" <> &1))
            team -> "/i @" <> team
          end

        put_flash(
          socket,
          :info,
          "#{mentions} #{if length(names) == 1, do: "is", else: "are"} not in this channel, so that mention woke nobody. Invite with #{invites}."
        )
    end
  end

  # `/i @team` with no message joins the team quietly: say who came in.
  defp outsider_hint(socket, {:invite_team, team, added}) do
    put_flash(
      socket,
      :info,
      "Invited @#{team.name}: #{Enum.map_join(added, ", ", &("@" <> &1.name))} joined. Mention @#{team.name} when you need them."
    )
  end

  defp outsider_hint(socket, {:playbook, run}) do
    where =
      if run.channel_id == socket.assigns.channel.id,
        do: "",
        else: " in ##{run.channel.name}"

    put_flash(
      socket,
      :info,
      "Started #{run.playbook_name}#{where}; @#{run.coordinator.name} coordinates it."
    )
  end

  defp outsider_hint(socket, _result), do: socket

  # The one team mention every outsider came in through, if there is one.
  defp outsider_team(%Messages.Message{team_mentions: teams}, outsider_ids)
       when outsider_ids != [] do
    Enum.find_value(teams || [], fn %{"name" => name, "agent_ids" => ids} ->
      if Enum.all?(outsider_ids, &(&1 in ids)), do: name
    end)
  end

  defp outsider_team(_message, _ids), do: nil

  # Turns every finished upload into a document and returns the ids, in the
  # order the files were added. Entries that fail to store are skipped and
  # reported as a flash by the caller.
  defp store_uploads(socket, upload) do
    consume_uploaded_entries(socket, upload, fn %{path: path}, entry ->
      result =
        Documents.create(%{
          filename: entry.client_name,
          mime: entry.client_type,
          source: {:path, path},
          user_id: socket.assigns.user.id,
          origin_channel_id: cid(socket)
        })

      case result do
        {:ok, document} -> {:ok, document.id}
        {:error, _} -> {:ok, nil}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp assign_branch(%{assigns: %{channel: channel}} = socket) do
    branch =
      case Repositories.current_branch(channel.repository) do
        {:ok, branch} -> branch
        {:error, _} -> nil
      end

    assign(socket, :branch, branch)
  end

  defp schedule_branch_refresh(socket) do
    if connected?(socket) do
      assign(socket, :branch_timer, Process.send_after(self(), :refresh_branch, @branch_interval))
    else
      socket
    end
  end

  # -- PubSub ------------------------------------------------------------------

  @impl true
  def handle_info({:timeline, %Timeline.Event{channel_id: cid} = event}, socket)
      when cid == socket.assigns.channel.id do
    if event.event_type == "message", do: Unread.mark_read(cid, socket.assigns.user)

    {:noreply,
     socket
     |> turn_finished(event)
     |> insert_event(event)
     |> thread_event(event)
     |> react_to(event)}
  end

  # A reply arrived: CanopyWeb.Nav has refreshed the unread map by now (its
  # copy of the event was already queued), so the dots follow without a query.
  def handle_info(:thread_dots, socket), do: {:noreply, apply_thread_unread(socket)}

  # A thread read, followed, or unfollowed elsewhere (Nav refreshed the map):
  # the dots and the open panel's bell follow.
  def handle_info({:thread_reads, root_id}, socket) do
    socket =
      case socket.assigns.thread do
        %{root: %{id: ^root_id}} = thread ->
          assign(socket, :thread, %{
            thread
            | following?: Threads.following?(root_id, socket.assigns.user)
          })

        _ ->
          socket
      end

    {:noreply, apply_thread_unread(socket)}
  end

  # A turn started working for a thread (or for the channel), or ended: the
  # live card moves between the feed and the panel, and the summary rows of
  # the threads it leaves and enters re-render.
  def handle_info({:turn_thread, agent_id, thread_id}, socket) do
    previous = Map.get(socket.assigns.turn_threads, agent_id)

    turn_threads =
      if thread_id,
        do: Map.put(socket.assigns.turn_threads, agent_id, thread_id),
        else: Map.delete(socket.assigns.turn_threads, agent_id)

    {:noreply,
     socket
     |> assign(:turn_threads, turn_threads)
     |> refresh_roots([previous, thread_id])}
  end

  # Activity means the agent is working, unless it is blocked on a card: only
  # the runtime's own status change ends that. Streamed text is held and
  # folded at most every #{@text_flush_ms} ms (one render per batch, not per
  # token); any other event folds the held text first, keeping the order.
  def handle_info({:telemetry, agent_id, %Event{type: :text_delta} = event}, socket) do
    pending = socket.assigns.pending_text

    unless Map.has_key?(pending, agent_id),
      do: Process.send_after(self(), {:flush_text, agent_id}, @text_flush_ms)

    {:noreply,
     socket
     |> assign(:pending_text, Map.update(pending, agent_id, [event], &[event | &1]))
     |> mark_working(agent_id)}
  end

  def handle_info({:telemetry, agent_id, %Event{} = event}, socket) do
    socket = flush_text(socket, agent_id)
    card = Activity.fold(event, live_card(socket, agent_id))
    {:noreply, socket |> put_live(agent_id, card) |> mark_working(agent_id)}
  end

  def handle_info({:flush_text, agent_id}, socket), do: {:noreply, flush_text(socket, agent_id)}

  # The user's messages steered into an agent's turn (nil: none any more).
  def handle_info({:steer, agent_id, nil}, socket),
    do: {:noreply, put_steers(socket, Map.delete(socket.assigns.steers, agent_id))}

  # The chip lives on the agent's live card: one that has shown nothing yet
  # appears with it.
  def handle_info({:steer, agent_id, info}, socket) do
    {:noreply,
     socket
     |> put_steers(Map.put(socket.assigns.steers, agent_id, info))
     |> put_live(agent_id, live_card(socket, agent_id))
     |> mark_working(agent_id)}
  end

  def handle_info({:agent_status, agent_id, status}, socket) do
    socket =
      if status in [:busy, :awaiting_user] do
        socket
      else
        card_id = "telemetry-" <> agent_id
        act = socket.assigns.act

        socket
        |> put_steers(Map.delete(socket.assigns.steers, agent_id))
        |> assign(:telemetry, Map.delete(socket.assigns.telemetry, agent_id))
        |> assign(:pending_text, Map.delete(socket.assigns.pending_text, agent_id))
        |> assign(:act, %{
          act
          | open_live: MapSet.delete(act.open_live, agent_id),
            open_rows: drop_rows(act.open_rows, card_id)
        })
      end

    {:noreply,
     assign(socket, :agent_statuses, Map.put(socket.assigns.agent_statuses, agent_id, status))}
  end

  # A message's reactions changed (here or anywhere): redraw it where it is
  # shown, the feed or the open thread's panel, in place. A reaction is no
  # event: nothing is marked read and the nav is left alone. A message outside
  # what is loaded picks its reactions up when it loads.
  def handle_info({:reactions, %{channel_id: cid, message_id: message_id}}, socket)
      when cid == socket.assigns.channel.id do
    {:noreply, redraw_message(socket, message_id)}
  end

  # A document was deleted somewhere: redraw the messages that carried it.
  def handle_info({:document_deleted, id, message_ids}, socket) do
    socket =
      socket
      |> assign(:picked, Enum.reject(socket.assigns.picked, &(&1.id == id)))
      |> assign(:thread_picked, Enum.reject(socket.assigns.thread_picked, &(&1.id == id)))
      |> then(fn socket ->
        if socket.assigns.library,
          do: load_library(socket, socket.assigns.library.q),
          else: socket
      end)

    {:noreply, Enum.reduce(message_ids, socket, &redraw_message(&2, &1))}
  end

  def handle_info({:schedules, :changed, cid}, socket) do
    if cid == socket.assigns.channel.id,
      do: {:noreply, assign(socket, :schedules, Schedules.list_for_channel(cid))},
      else: {:noreply, socket}
  end

  def handle_info({:playbook_runs, :changed, cid}, socket) do
    if cid == socket.assigns.channel.id,
      do: {:noreply, assign_run(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:playbooks, :changed}, socket), do: {:noreply, assign_run(socket)}

  def handle_info({:chatter, status}, socket),
    do:
      {:noreply,
       socket
       |> assign(:paused?, status in [:paused, :stopped])
       |> assign(:stopped?, status == :stopped)}

  # the same tick keeps the lock ages current
  def handle_info(:refresh_branch, socket) do
    {:noreply,
     socket
     |> assign_branch()
     |> assign(:now, DateTime.utc_now())
     |> schedule_branch_refresh()}
  end

  def handle_info({:locks_changed, repository_id}, socket) do
    if repository_id == socket.assigns.channel.repository_id,
      do: {:noreply, watch_locks(socket)},
      else: {:noreply, socket}
  end

  # a team created, edited, or deleted: the composer and the Members panel follow
  def handle_info({:teams, :changed}, socket) do
    socket = assign_mention_sources(socket, socket.assigns.channel)

    {:noreply, if(socket.assigns.editing_members?, do: refresh_members(socket), else: socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp mark_working(socket, agent_id) do
    statuses =
      Map.update(socket.assigns.agent_statuses, agent_id, :busy, fn
        :awaiting_user -> :awaiting_user
        _ -> :busy
      end)

    assign(socket, :agent_statuses, statuses)
  end

  # The agent's live card, or a fresh one for a turn this view has not seen
  # yet (opened at once when this browser opens live cards by itself).
  defp live_card(socket, agent_id) do
    case Map.get(socket.assigns.telemetry, agent_id) do
      nil -> Map.put(Activity.new(), :model, Runtime.model_label(agent_id))
      card -> card
    end
  end

  defp flush_text(socket, agent_id) do
    case Map.pop(socket.assigns.pending_text, agent_id) do
      {nil, _} ->
        socket

      {events, pending} ->
        card =
          events |> Enum.reverse() |> Enum.reduce(live_card(socket, agent_id), &Activity.fold/2)

        socket |> assign(:pending_text, pending) |> put_live(agent_id, card)
    end
  end

  # A card this view had not shown yet opens at once when this browser opens
  # live cards by itself; after that it stays as the reader left it.
  defp put_live(socket, agent_id, card) do
    %{telemetry: telemetry, act: act} = socket.assigns

    socket = assign(socket, :telemetry, Map.put(telemetry, agent_id, card))

    if act.auto_open? and not Map.has_key?(telemetry, agent_id),
      do: assign(socket, :act, %{act | open_live: MapSet.put(act.open_live, agent_id)}),
      else: socket
  end

  defp drop_rows(rows, card_id), do: MapSet.reject(rows, &match?({^card_id, _}, &1))

  # A turn just ended. Its card arrives open when the live card was open
  # (with its open rows, and the details the live card already holds); the
  # messages it posted gain their receipt chip; a side panel following the
  # live turn moves to the finished one.
  defp turn_finished(socket, %{event_type: "agent_turn_completed", agent_id: agent_id} = event)
       when is_binary(agent_id) do
    socket
    |> carry_over(event)
    |> add_receipts(event)
    |> then(fn socket ->
      case socket.assigns.activity do
        %{kind: :live, agent_id: ^agent_id} ->
          push_patch(socket, to: activity_path(cid(socket), event.id), replace: true)

        _ ->
          socket
      end
    end)
  end

  defp turn_finished(socket, _event), do: socket

  defp carry_over(socket, %{agent_id: agent_id, id: id}) do
    act = socket.assigns.act

    if MapSet.member?(act.open_live, agent_id) do
      live_id = "telemetry-" <> agent_id

      rows =
        for {^live_id, key} <- act.open_rows, into: act.open_rows, do: {"turn-" <> id, key}

      details =
        case Map.get(socket.assigns.telemetry, agent_id) do
          %{details: live} -> Map.put(act.details, id, live)
          _ -> act.details
        end

      assign(socket, :act, %{
        act
        | open_turns: MapSet.put(act.open_turns, id),
          open_rows: rows,
          details: details
      })
    else
      socket
    end
  end

  defp add_receipts(socket, %{payload: payload} = event) do
    ids = for id <- List.wrap(payload["message_ids"]), is_binary(id), do: id
    entry = receipt(event)

    socket =
      assign(socket, :receipts, Map.merge(socket.assigns.receipts, Map.new(ids, &{&1, entry})))

    # messages already shown re-render with their chip
    Enum.reduce(ids, socket, fn message_id, socket ->
      in_feed? = MapSet.member?(socket.assigns.message_ids, message_id)
      in_panel? = loaded_in_panel?(socket, message_id)

      case (in_feed? or in_panel?) && Timeline.for_message(message_id) do
        %Timeline.Event{} = message_event ->
          socket
          |> then(&if(in_feed?, do: stream_insert(&1, :timeline, message_event), else: &1))
          |> then(&if(in_panel?, do: stream_insert(&1, :thread, message_event), else: &1))

        _ ->
          socket
      end
    end)
  end

  # A finished card changed (opened, a row opened, highlighted): re-insert it
  # where it shows, the feed or the open thread's panel.
  defp refresh_turn(socket, %Timeline.Event{} = event) do
    socket
    |> then(fn socket ->
      if event.in_channel and MapSet.member?(socket.assigns.turn_ids, event.id),
        do: stream_insert(socket, :timeline, event),
        else: socket
    end)
    |> then(fn socket ->
      if event.thread_id && event.thread_id == open_root(socket.assigns),
        do: stream_insert(socket, :thread, event),
        else: socket
    end)
  end

  # Only the thread shows what stays in it.
  defp insert_event(socket, %{in_channel: false}), do: socket

  # Reading history: new events wait, counted on the Jump to latest pill.
  defp insert_event(%{assigns: %{window: :history}} = socket, _event),
    do: update(socket, :held, &(&1 + 1))

  defp insert_event(socket, %{event_type: "agent_turn_completed", id: id} = event) do
    socket
    |> assign(:turn_ids, MapSet.put(socket.assigns.turn_ids, id))
    |> stream_insert(:timeline, event)
  end

  defp insert_event(socket, %{event_type: "message", message: %{id: message_id}} = event) do
    socket
    |> assign(:message_ids, MapSet.put(socket.assigns.message_ids, message_id))
    |> stream_insert(:timeline, event)
  end

  defp insert_event(socket, event), do: stream_insert(socket, :timeline, event)

  # What a thread's event changes. A reply updates its root's summary row
  # (one summary, for that root), joins the open panel and is read there, and
  # the unread dots follow once Nav has refreshed its map. A turn line only
  # joins the open panel.
  defp thread_event(socket, %{thread_id: nil}), do: socket

  defp thread_event(socket, %{event_type: "message", thread_id: root_id} = event) do
    summary = Map.get(Messages.thread_summaries([root_id]), root_id)

    socket =
      if summary,
        do: assign(socket, :summaries, Map.put(socket.assigns.summaries, root_id, summary)),
        else: socket

    socket =
      if in_open_thread?(socket, event),
        do: socket |> insert_in_panel(event) |> panel_reply(summary),
        else: socket

    send(self(), :thread_dots)
    reinsert_root(socket, root_id)
  end

  defp thread_event(socket, event) do
    if in_open_thread?(socket, event), do: insert_in_panel(socket, event), else: socket
  end

  defp in_open_thread?(socket, event) do
    root_id = open_root(socket.assigns)
    not is_nil(root_id) and (event.thread_id == root_id or event.ref_id == root_id)
  end

  defp insert_in_panel(socket, %{event_type: "message", ref_id: id} = event) do
    %{thread: thread} = socket.assigns

    socket
    |> assign(:thread, %{thread | loaded: MapSet.put(thread.loaded, id)})
    |> stream_insert(:thread, event)
  end

  defp insert_in_panel(socket, event), do: stream_insert(socket, :thread, event)

  defp loaded_in_panel?(%{assigns: %{thread: %{loaded: loaded}}}, message_id),
    do: MapSet.member?(loaded, message_id)

  defp loaded_in_panel?(_socket, _message_id), do: false

  # A reply in the open thread is read as it arrives; the count under the root
  # follows, and so does the bell (the reply may have made the user follow).
  defp panel_reply(socket, summary) do
    %{root: root} = thread = socket.assigns.thread
    :ok = Threads.mark_read(root.id, socket.assigns.user)

    assign(socket, :thread, %{
      thread
      | count: (summary && summary.count) || thread.count,
        following?: Threads.following?(root.id, socket.assigns.user)
    })
  end

  # Re-renders a message where it is loaded (the feed, the open panel, or
  # both); a message in neither is left out, never appended.
  defp redraw_message(socket, message_id) do
    in_feed? = MapSet.member?(socket.assigns.message_ids, message_id)
    in_panel? = loaded_in_panel?(socket, message_id)

    case (in_feed? or in_panel?) && Timeline.for_message(message_id) do
      %Timeline.Event{} = event ->
        socket
        |> then(&if(in_feed?, do: stream_insert(&1, :timeline, event), else: &1))
        |> then(&if(in_panel?, do: stream_insert(&1, :thread, event), else: &1))

      _ ->
        socket
    end
  end

  # The messages steered into working turns, each marked Queued under its
  # row until the turn ends; a message whose mark changed re-renders.
  defp put_steers(socket, steers) do
    before = queued_of(socket.assigns.steers)
    now = queued_of(steers)

    changed =
      for id <- Enum.uniq(Map.keys(before) ++ Map.keys(now)),
          Map.get(before, id) != Map.get(now, id),
          do: id

    socket
    |> assign(:steers, steers)
    |> assign(:queued, now)
    |> then(&Enum.reduce(changed, &1, fn id, socket -> reinsert_root(socket, id) end))
  end

  defp queued_of(steers) do
    for {_agent_id, info} <- steers,
        {message_id, held?} <- Map.get(info, :queued, %{}),
        into: %{},
        do: {message_id, if(held?, do: :held, else: :next_step)}
  end

  defp queued_mark(queued, %{event_type: "message", ref_id: message_id}),
    do: Map.get(queued, message_id)

  defp queued_mark(_queued, _event), do: nil

  # The root's row, where it is shown: its summary row in the feed, the reply
  # count under it in the panel. One read of its event serves both.
  defp reinsert_root(socket, root_id) do
    in_feed? = MapSet.member?(socket.assigns.message_ids, root_id)
    in_panel? = open_root(socket.assigns) == root_id

    case (in_feed? or in_panel?) && Timeline.for_message(root_id) do
      %Timeline.Event{} = event ->
        socket
        |> then(&if(in_feed?, do: stream_insert(&1, :timeline, event), else: &1))
        |> then(&if(in_panel?, do: stream_insert(&1, :thread, event), else: &1))

      _ ->
        socket
    end
  end

  defp react_to(socket, %{event_type: type}) when type in ~w(owner_changed handoff_accepted) do
    socket
    |> refresh_channel()
    |> refresh_handoffs()
    |> assign_task(Tasks.for_channel(cid(socket)))
  end

  defp react_to(socket, %{event_type: type}) when type in ~w(handoff_requested handoff_rejected),
    do: refresh_handoffs(socket)

  defp react_to(socket, %{event_type: type})
       when type in ~w(member_added member_removed team_added),
       do: refresh_members(socket)

  defp react_to(socket, %{event_type: type}) when type in ~w(channel_archived channel_reopened),
    do: socket |> refresh_channel() |> Nav.refresh_nav()

  defp react_to(socket, %{event_type: "repository_switched"}),
    do: socket |> refresh_channel() |> assign_branch() |> watch_locks() |> Nav.refresh_nav()

  defp react_to(socket, %{event_type: "agent_turn_completed"}),
    do: assign(socket, :spent, Costs.channel_total(cid(socket)))

  defp react_to(socket, %{event_type: "spend_limit_" <> _}),
    do: socket |> refresh_channel() |> assign(:spent, Costs.channel_total(cid(socket)))

  # an agent's edit (or another window's) shows at once; an open editor keeps
  # what was typed and says the brief moved under it
  defp react_to(socket, %{event_type: "brief_updated"} = event) do
    socket = refresh_channel(socket)

    socket
    |> assign(:brief_conflict, if(socket.assigns.editing_brief?, do: event, else: nil))
    |> then(&if(&1.assigns.brief_history, do: load_brief_history(&1), else: &1))
  end

  defp react_to(socket, %{event_type: "task_updated"}),
    do: assign_task(socket, Tasks.for_channel(cid(socket)))

  defp react_to(socket, %{event_type: "permission_" <> _}), do: refresh_permissions(socket)
  defp react_to(socket, %{event_type: "question_" <> _}), do: refresh_questions(socket)
  defp react_to(socket, _event), do: socket

  defp refresh_channel(socket) do
    channel = Channels.get!(cid(socket))
    assign(socket, :channel, channel)
  end

  defp open_brief_form(socket, text) do
    socket
    |> assign(:editing_brief?, true)
    |> assign(:brief_conflict, nil)
    |> assign_brief_form(text, nil)
  end

  defp close_brief_form(socket) do
    socket
    |> assign(:editing_brief?, false)
    |> assign(:brief_form, nil)
    |> assign(:brief_text, "")
    |> assign(:brief_conflict, nil)
  end

  defp assign_brief_form(socket, text, action) do
    changeset =
      socket.assigns.channel
      |> Channels.change_brief(%{"brief" => text})
      |> Map.put(:action, action)

    socket
    |> assign(:brief_text, text)
    |> assign(:brief_form, to_form(changeset, as: "brief", id: "brief-form"))
  end

  defp save_brief(socket, text, done) do
    case Channels.set_brief(socket.assigns.channel, text, "user") do
      {:ok, channel} ->
        socket
        |> assign(:channel, channel)
        |> close_brief_form()
        |> then(&if(&1.assigns.brief_history, do: load_brief_history(&1), else: &1))
        |> put_flash(:info, done)

      {:error, changeset} ->
        socket
        |> assign(:editing_brief?, true)
        |> assign(:brief_text, text)
        |> assign(
          :brief_form,
          to_form(Map.put(changeset, :action, :validate), as: "brief", id: "brief-form")
        )
    end
  end

  defp load_brief_history(socket),
    do: assign(socket, :brief_history, Channels.brief_history(cid(socket)))

  defp refresh_members(socket) do
    members = Channels.members(cid(socket))

    socket
    |> assign(:members, members)
    |> assign(:member_names, Enum.map(members, & &1.name))
    |> assign(:addable_agents, Channels.addable_agents(cid(socket)))
    |> assign(:addable_teams, Teams.addable(cid(socket)))
  end

  # What the composer suggests after `@` and `#`, and the map that turns
  # `#name` in bodies into links. In a channel every active agent is offered
  # (mentioning a non-member only hints at /i); a DM keeps its own set.
  # `mention_names` are the agents and teams the composer and the timeline
  # highlight as `@mentions`; `team_members` lets the composer tell a team
  # that would wake someone here from one that wouldn't.
  defp assign_mention_sources(socket, channel) do
    agent_names =
      if channel.kind == "dm",
        do: socket.assigns.member_names,
        else: Enum.map(Agents.list_active(), & &1.name)

    channels =
      Channels.list()
      |> Enum.reject(&(&1.kind == "dm"))
      |> Enum.sort_by(&{&1.repository_id != channel.repository_id, &1.name})

    links =
      Enum.reduce(channels, %{}, fn c, acc -> Map.put_new(acc, c.name, c.id) end)

    channel_names =
      channels
      |> Enum.filter(&(&1.status == "open"))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

    # teams are offered after agents, outside DMs (a DM keeps its own set)
    teams = if channel.kind == "dm", do: [], else: Teams.list()
    team_names = Enum.map(teams, & &1.name)

    team_members =
      Map.new(teams, &{&1.name, Enum.map(Teams.active_members(&1), fn agent -> agent.name end)})

    socket
    |> assign(:agent_names, agent_names)
    |> assign(:team_names, team_names)
    |> assign(:team_members, team_members)
    |> assign(:mention_names, MapSet.new(agent_names ++ team_names))
    |> assign(:channel_names, channel_names)
    |> assign(:channel_links, links)
  end

  defp refresh_handoffs(socket),
    do: assign(socket, :pending_handoffs, Handoffs.pending_for_channel(cid(socket)))

  defp refresh_permissions(socket) do
    socket
    |> assign(:pending_permissions, PermissionRequests.pending_for_channel(cid(socket)))
    |> assign_cards()
  end

  defp refresh_questions(socket) do
    socket
    |> assign(:pending_questions, QuestionRequests.pending_for_channel(cid(socket)))
    |> assign_cards()
  end

  defp drop_question(socket, id) do
    socket
    |> assign(:pending_questions, Enum.reject(socket.assigns.pending_questions, &(&1.id == id)))
    |> assign(:question_drafts, Map.delete(socket.assigns.question_drafts, id))
    |> assign_cards()
  end

  defp drop_permission(socket, id) do
    socket
    |> assign(
      :pending_permissions,
      Enum.reject(socket.assigns.pending_permissions, &(&1.id == id))
    )
    |> assign_cards()
  end

  # What the pending cards imply, worked out once per change: the agents still
  # blocked on a card (the banner above the composer and the composer's hint).
  defp assign_cards(socket) do
    %{pending_questions: questions, pending_permissions: permissions, names: names} =
      socket.assigns

    assign(socket, :waiting_on_user, waiting_on_user(questions, permissions, names))
  end

  # The agents a pending card still blocks (not detached), for the banner
  # above the composer and the composer's hint: `[{name, dom_id}]`, one per
  # agent, pointing at its first card.
  defp waiting_on_user(questions, permissions, names) do
    (Enum.map(questions, &{&1, "question-#{&1.id}"}) ++
       Enum.map(permissions, &{&1, "permission-#{&1.id}"}))
    |> Enum.filter(fn {request, _} -> is_nil(request.detached_at) end)
    |> Enum.sort_by(fn {request, _} -> request.inserted_at end, DateTime)
    |> Enum.map(fn {request, dom_id} -> {card_agent_name(request, names), dom_id} end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp card_agent_name(%{agent_session: %{agent: %{name: name}}}, _names), do: name

  defp card_agent_name(%{agent_session: %{agent_id: id}}, names),
    do: Map.get(names, id, "agent")

  defp card_agent_name(_request, _names), do: "agent"

  # One list of chosen labels per question, in question order. A free-text
  # answer rides along with whatever was ticked, and is enough on its own;
  # every question needs something, since the engine expects an answer for each.
  defp cid(socket), do: socket.assigns.channel.id

  # Whether a mention of a working agent reaches it mid-turn: the setting,
  # read now, flipped for this message by Alt+Enter or the send menu
  # (`"interrupt" => "toggle"`). With the setting off nothing interrupts.
  defp interrupt_opts(params) do
    on? = Settings.interrupt_on_mention?()
    [interrupt: on? and params["interrupt"] != "toggle"]
  end

  # The agents a mention would interrupt (the composer's hint): working, not
  # waiting on a card; none while interrupts are off.
  defp working_names(false, _statuses, _names), do: []

  defp working_names(true, statuses, names),
    do: for({agent_id, :busy} <- statuses, name = Map.get(names, agent_id), do: name)

  # One send path for both composers: `:main` (the channel's) and `:thread`
  # (the thread panel's), each with its own uploads and picked files. On a
  # failed send the text stays in the composer and the stored files go.
  defp submit(socket, body, composer, opts) do
    {upload, picked_key, input} =
      case composer do
        :main -> {:files, :picked, "composer-input"}
        :thread -> {:thread_files, :thread_picked, "thread-composer-input"}
      end

    text = String.trim(body)
    entries = socket.assigns.uploads[upload].entries
    picked = socket.assigns |> Map.fetch!(picked_key) |> Enum.map(& &1.id)

    cond do
      text == "" and entries == [] and picked == [] ->
        {:noreply, socket}

      Enum.any?(entries, &(not &1.done?)) ->
        {:noreply,
         put_flash(socket, :error, "A file is still uploading, or failed; wait or remove it.")}

      true ->
        documents = store_uploads(socket, upload)

        case Runtime.post_user_message(
               cid(socket),
               text,
               [attachments: documents ++ picked] ++ opts
             ) do
          {:ok, result} ->
            {:noreply,
             socket
             |> reset_composer(composer)
             |> assign(picked_key, [])
             |> outsider_hint(result)
             |> push_event("composer:clear", %{id: input})
             |> then(&if(composer == :main and history?(&1), do: to_latest(&1), else: &1))}

          {:error, reason} ->
            # the files were stored for a message that never happened
            documents
            |> Enum.map(&Documents.get/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.each(&Documents.delete/1)

            {:noreply,
             socket |> reset_composer(composer, body) |> put_flash(:error, to_string(reason))}
        end
    end
  end

  defp reset_composer(socket, composer, body \\ "")
  defp reset_composer(socket, :main, body), do: assign_composer(socket, body)
  defp reset_composer(socket, :thread, body), do: assign_thread_composer(socket, body)

  @excerpt_chars 80

  # The quoted parent of a reply sent to the channel: one line, Markdown stripped.
  defp excerpt(%{body: body}) when is_binary(body) do
    case CanopyWeb.Markdown.plain(body) do
      "" -> "(no text)"
      text -> String.slice(text, 0, @excerpt_chars)
    end
  end

  defp excerpt(_message), do: "(no text)"

  # -- Events ------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}} = params, socket) do
    submit(socket, body, :main, interrupt_opts(params))
  end

  # The thread panel's composer: the reply lands in the open thread, and the
  # composer stays there for the next one. "Also send to channel" shows it in
  # the feed too.
  def handle_event("send_thread", %{"message" => %{"body" => body}} = params, socket) do
    case socket.assigns.thread do
      nil ->
        {:noreply, socket}

      %{root: root} ->
        submit(
          socket,
          body,
          :thread,
          [thread_id: root.id, to_channel: params["also_send"] == "true"] ++
            interrupt_opts(params)
        )
    end
  end

  # Uploads only progress through a phx-change; the composer text never
  # round-trips, so there is nothing to validate.
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref} = params, socket) do
    upload = if params["upload"] == "thread_files", do: :thread_files, else: :files
    {:noreply, cancel_upload(socket, upload, ref)}
  end

  # The user's reaction, from a chip or the picker. The broadcast redraws the
  # message, the way a posted message arrives through the timeline.
  def handle_event("toggle_reaction", %{"id" => id, "emoji" => key}, socket) do
    case Messages.get(id) do
      %{channel_id: cid} when cid == socket.assigns.channel.id ->
        case Reactions.toggle(id, {:user, socket.assigns.user.id}, key) do
          {:ok, _} -> {:noreply, socket}
          {:error, reason} -> {:noreply, put_flash(socket, :error, reaction_error(reason))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "That message is not in this channel.")}
    end
  end

  # Esc in the side panel (see the SidePanel hook) closes it.
  def handle_event("close_panel", _params, socket) do
    if panel_open?(socket),
      do: {:noreply, push_patch(socket, to: ~p"/channels/#{cid(socket)}")},
      else: {:noreply, hide_details(socket)}
  end

  # The header's Details button; the palette's Show and Hide channel details
  # say which (`open`).
  def handle_event("toggle_details", params, socket) do
    open? =
      case params do
        %{"open" => open} -> open in [true, "true"]
        _ -> panel_open?(socket) or not socket.assigns.details?
      end

    {:noreply, if(open?, do: show_details(socket), else: hide_details(socket))}
  end

  def handle_event("open_details", %{"section" => section}, socket) do
    {:noreply,
     socket
     |> show_details()
     |> open_section(section)
     |> push_event("details:focus", %{section: section})}
  end

  def handle_event("toggle_take_lock", _params, socket),
    do: {:noreply, assign(socket, :taking_lock?, not socket.assigns.taking_lock?)}

  def handle_event("toggle_follow", _params, socket) do
    case socket.assigns.thread do
      nil ->
        {:noreply, socket}

      %{root: root} = thread ->
        # from what is stored, not what the panel last showed
        following? = not Threads.following?(root.id, socket.assigns.user)
        :ok = Threads.follow(root.id, socket.assigns.user, following?)

        {:noreply,
         socket
         |> assign(:thread, %{thread | following?: following?})
         |> refresh_thread_unread()}
    end
  end

  # -- Attach from the library --------------------------------------------------

  def handle_event("open_library", params, socket),
    do: {:noreply, load_library(socket, "", params["target"] || "main")}

  def handle_event("close_library", _params, socket),
    do: {:noreply, assign(socket, :library, nil)}

  def handle_event("search_library", %{"q" => q}, socket),
    do: {:noreply, load_library(socket, q)}

  def handle_event("pick_document", %{"id" => id}, socket) do
    target = (socket.assigns.library && socket.assigns.library.target) || "main"

    case Documents.get(id) do
      nil -> {:noreply, socket}
      document -> {:noreply, socket |> pick(document, target) |> assign(:library, nil)}
    end
  end

  def handle_event("unpick_document", %{"id" => id} = params, socket) do
    key = picked_key(params["target"])
    {:noreply, assign(socket, key, Enum.reject(Map.fetch!(socket.assigns, key), &(&1.id == id)))}
  end

  def handle_event("abort", %{"agent-id" => agent_id}, socket) do
    case Runtime.abort(cid(socket), agent_id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Abort requested.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Abort failed: #{inspect(reason)}")}
    end
  end

  def handle_event("interrupt_now", %{"agent-id" => agent_id}, socket) do
    case Runtime.interrupt_now(cid(socket), agent_id) do
      :ok ->
        {:noreply, socket}

      {:error, :nothing_pending} ->
        {:noreply, put_flash(socket, :info, "Nothing to interrupt: the agent already read it.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Interrupt failed: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_all", _params, socket) do
    {:ok, %{aborted: aborted}} = Runtime.stop_all(cid(socket))

    {:noreply,
     put_flash(
       socket,
       :info,
       "Stopped: #{aborted} #{if aborted == 1, do: "turn", else: "turns"} aborted. Reply or press Continue to resume."
     )}
  end

  def handle_event("toggle_activity", _params, socket) do
    compact? = not socket.assigns.compact?

    {:noreply,
     socket
     |> assign(:compact?, compact?)
     |> push_event("pref", %{
       key: "timeline-activity",
       value: if(compact?, do: "compact", else: "full")
     })}
  end

  # the browser remembers the choice (see the Pref hook)
  def handle_event("pref", %{"key" => "timeline-activity", "value" => value}, socket),
    do: {:noreply, assign(socket, :compact?, value != "full")}

  # Open live activity cards by themselves (this browser): the cards showing
  # now open too.
  def handle_event("pref", %{"key" => "activity-open-live", "value" => value}, socket),
    do: {:noreply, set_auto_open(socket, value == "true")}

  def handle_event("pref", %{"key" => "playbook-seen", "value" => value}, socket) do
    seen = value |> to_string() |> String.split(",", trim: true)
    {:noreply, socket |> assign(:seen_runs, seen) |> first_view_of_run()}
  end

  def handle_event("pref", %{"key" => "channel-brief", "value" => value}, socket),
    do: {:noreply, assign(socket, :brief_expanded?, value == "expanded")}

  # Details as this browser left it, from lg up (`media` is false below). A
  # thread or activity open on arrival wins, and Details stays closed.
  def handle_event("pref", %{"key" => "channel-details", "value" => value} = params, socket) do
    wide? = params["media"] != false
    socket = assign(socket, :details_wide?, wide?)

    cond do
      not wide? or value != "open" -> {:noreply, assign(socket, :details?, false)}
      panel_open?(socket) -> {:noreply, hide_details(socket)}
      true -> {:noreply, assign(socket, :details?, true)}
    end
  end

  def handle_event("toggle_brief", _params, socket) do
    expanded? = not socket.assigns.brief_expanded?

    {:noreply,
     socket
     |> assign(:brief_expanded?, expanded?)
     |> push_event("pref", %{
       key: "channel-brief",
       value: if(expanded?, do: "expanded", else: "collapsed")
     })}
  end

  def handle_event("toggle_brief_form", _params, socket) do
    if socket.assigns.editing_brief?,
      do: {:noreply, close_brief_form(socket)},
      else: {:noreply, open_brief_form(socket, socket.assigns.channel.brief || "")}
  end

  def handle_event("validate_brief", %{"brief" => %{"brief" => text}}, socket),
    do: {:noreply, assign_brief_form(socket, text, :validate)}

  def handle_event("save_brief", %{"brief" => %{"brief" => text}}, socket),
    do:
      {:noreply,
       save_brief(socket, text, "Brief saved. Every agent here gets it from its next prompt.")}

  def handle_event("clear_brief", _params, socket),
    do: {:noreply, save_brief(socket, "", "Brief cleared.")}

  def handle_event("toggle_brief_history", _params, socket) do
    if socket.assigns.brief_history,
      do: {:noreply, socket |> assign(:brief_history, nil) |> assign(:brief_viewing, nil)},
      else: {:noreply, load_brief_history(socket)}
  end

  def handle_event("view_brief_version", %{"id" => id}, socket) do
    viewing = if socket.assigns.brief_viewing == id, do: nil, else: id
    {:noreply, assign(socket, :brief_viewing, viewing)}
  end

  # a restore is an edit like any other: it records a new version
  def handle_event("restore_brief", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.brief_history || [], &(&1.id == id)) do
      %{payload: %{"body" => body}} when is_binary(body) ->
        {:noreply, save_brief(socket, body, "Brief restored.")}

      _ ->
        {:noreply, put_flash(socket, :error, "That version is no longer available.")}
    end
  end

  def handle_event("toggle_auto_open_live", _params, socket) do
    on? = not socket.assigns.act.auto_open?

    {:noreply,
     socket
     |> set_auto_open(on?)
     |> push_event("pref", %{key: "activity-open-live", value: to_string(on?)})}
  end

  # A card's header opens or closes it. A live card is keyed by its agent; a
  # finished card is a stream item, re-inserted to show the change. Closing
  # a card closes its rows (and forgets the details it loaded).
  def handle_event("toggle_activity_card", %{"card" => "telemetry-" <> agent_id}, socket) do
    act = socket.assigns.act

    act =
      if MapSet.member?(act.open_live, agent_id),
        do: %{
          act
          | open_live: MapSet.delete(act.open_live, agent_id),
            open_rows: drop_rows(act.open_rows, "telemetry-" <> agent_id)
        },
        else: %{act | open_live: MapSet.put(act.open_live, agent_id)}

    {:noreply, assign(socket, :act, act)}
  end

  def handle_event("toggle_activity_card", %{"card" => "turn-" <> event_id}, socket) do
    case channel_turn(socket, event_id) do
      nil ->
        {:noreply, socket}

      event ->
        act = socket.assigns.act

        act =
          if MapSet.member?(act.open_turns, event_id),
            do: %{
              act
              | open_turns: MapSet.delete(act.open_turns, event_id),
                open_rows: drop_rows(act.open_rows, "turn-" <> event_id),
                details: Map.delete(act.details, event_id)
            },
            else: %{act | open_turns: MapSet.put(act.open_turns, event_id)}

        {:noreply, socket |> assign(:act, act) |> refresh_turn(event)}
    end
  end

  def handle_event("toggle_activity_card", _params, socket), do: {:noreply, socket}

  # A row opens to its detail. A live row's detail is on the live card; a
  # finished row's comes from the turn's stored details, read once per card.
  def handle_event("toggle_activity_row", %{"card" => card_id, "key" => key}, socket) do
    act = socket.assigns.act
    row = {card_id, key}
    open? = MapSet.member?(act.open_rows, row)
    rows = if open?, do: MapSet.delete(act.open_rows, row), else: MapSet.put(act.open_rows, row)

    case card_id do
      "turn-" <> event_id ->
        case channel_turn(socket, event_id) do
          nil ->
            {:noreply, socket}

          event ->
            details =
              if open? or Map.has_key?(act.details, event_id),
                do: act.details,
                else: Map.put(act.details, event_id, ActivityDetails.fetch(event_id))

            {:noreply,
             socket
             |> assign(:act, %{act | open_rows: rows, details: details})
             |> refresh_turn(event)}
        end

      _live ->
        {:noreply, assign(socket, :act, %{act | open_rows: rows})}
    end
  end

  def handle_event("pref", _params, socket), do: {:noreply, socket}

  def handle_event("switch_repository", %{"repository_id" => repository_id}, socket) do
    case Runtime.switch_dm_repository(cid(socket), repository_id, "user") do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> assign_branch()
         |> watch_locks()
         |> Nav.refresh_nav()
         |> put_flash(
           :info,
           "Moved to #{channel.repository.name}. Agents continue there on their next turn."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not move this conversation.")}
    end
  end

  def handle_event("reset_session", %{"agent-id" => agent_id}, socket) do
    case Runtime.reset_session(cid(socket), agent_id, "user") do
      :ok ->
        {:noreply, put_flash(socket, :info, "Session reset. The next turn starts fresh.")}

      {:error, :busy} ->
        {:noreply,
         put_flash(socket, :error, "Wait for the current turn to finish, or abort it first.")}

      {:error, :no_session} ->
        {:noreply,
         put_flash(socket, :info, "No session yet; the next turn already starts fresh.")}
    end
  end

  def handle_event("respond_permission", %{"id" => id, "reply" => reply}, socket)
      when reply in ~w(once always reject) do
    case Runtime.respond_permission(cid(socket), id, String.to_existing_atom(reply)) do
      {:ok, _request} ->
        {:noreply, drop_permission(socket, id)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, @archived_answer)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not answer permission: #{inspect(reason)}")}
    end
  end

  def handle_event("answer_question", %{"request_id" => id} = params, socket) do
    request = Enum.find(socket.assigns.pending_questions, &(&1.id == id))

    case request && question_answers(request, params) do
      nil ->
        {:noreply, socket}

      :incomplete ->
        {:noreply, put_flash(socket, :error, "Answer every question before sending.")}

      answers ->
        case Runtime.respond_question(cid(socket), id, {:answered, answers}) do
          {:ok, _request} ->
            {:noreply, drop_question(socket, id)}

          {:error, :archived} ->
            {:noreply, put_flash(socket, :error, @archived_answer)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not answer: #{inspect(reason)}")}
        end
    end
  end

  # The question form's state, kept so a re-render keeps what was picked and
  # Send is enabled once every question has an answer.
  def handle_event("question_draft", %{"request_id" => id} = params, socket) do
    draft = Map.take(params, ["answers", "custom"])

    {:noreply,
     assign(socket, :question_drafts, Map.put(socket.assigns.question_drafts, id, draft))}
  end

  def handle_event("reject_question", %{"id" => id}, socket) do
    case Runtime.respond_question(cid(socket), id, :rejected) do
      {:ok, _request} ->
        {:noreply, drop_question(socket, id)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not dismiss the question: #{inspect(reason)}")}
    end
  end

  def handle_event("accept_handoff", %{"id" => id}, socket) do
    case Handoffs.accept(Handoffs.get!(id)) do
      {:ok, handoff} ->
        {:noreply,
         socket
         |> refresh_channel()
         |> refresh_handoffs()
         |> assign_task(Tasks.for_channel(cid(socket)))
         |> put_flash(:info, "@#{handoff.to_agent.name} now owns this task.")}

      {:error, :not_pending} ->
        {:noreply,
         socket |> refresh_handoffs() |> put_flash(:error, "That handoff was already decided.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not accept the handoff.")}
    end
  end

  def handle_event("reject_handoff", %{"handoff_id" => id} = params, socket) do
    reason =
      case String.trim(params["reason"] || "") do
        "" -> "rejected by #{socket.assigns.user.display_name}"
        reason -> reason
      end

    case Handoffs.reject(Handoffs.get!(id), reason) do
      {:ok, _handoff} ->
        {:noreply, socket |> refresh_handoffs() |> put_flash(:info, "Handoff rejected.")}

      {:error, :not_pending} ->
        {:noreply,
         socket |> refresh_handoffs() |> put_flash(:error, "That handoff was already decided.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not reject the handoff.")}
    end
  end

  # The toggles below open their part of Details (`toggle_in_details`), so
  # the palette (and an old link) always lands somewhere visible.
  def handle_event("toggle_task_form", _params, socket) do
    {:noreply,
     socket
     |> toggle_in_details(:editing_task?, "task")
     |> assign_task(socket.assigns.task)}
  end

  def handle_event("continue_chatter", _params, socket) do
    :ok = Runtime.continue(cid(socket))
    {:noreply, assign(socket, :paused?, false)}
  end

  def handle_event("toggle_playbook", _params, socket),
    do: {:noreply, toggle_in_details(socket, :editing_playbook?, "playbook")}

  def handle_event("start_validate", %{"start" => params}, socket),
    do: {:noreply, assign_run(socket, params)}

  def handle_event("start_playbook", %{"start" => params}, socket) do
    case PlaybookStart.start(params, socket.assigns.channel) do
      {:ok, %{channel_id: channel_id} = run} when channel_id != socket.assigns.channel.id ->
        {:noreply,
         socket
         |> put_flash(:info, "Started #{run.playbook_name} in ##{run.channel.name}.")
         |> push_navigate(to: ~p"/channels/#{channel_id}")}

      {:ok, run} ->
        {:noreply,
         socket
         |> assign_run()
         |> put_flash(
           :info,
           "Started #{run.playbook_name}; @#{run.coordinator.name} coordinates it."
         )}

      {:error, reason} ->
        {:noreply, socket |> assign_run(params) |> put_flash(:error, reason)}
    end
  end

  def handle_event("cancel_playbook_run", %{"id" => id}, socket) do
    with %Run{} = run <- Runs.get(id),
         {:ok, _run, :cancelled} <-
           Runs.cancel(run, :user, "cancelled by #{socket.assigns.user.display_name}") do
      {:noreply, assign_run(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
      _ -> {:noreply, assign_run(socket)}
    end
  end

  def handle_event("approve_playbook_step", %{"id" => id}, socket) do
    with %Run{} = run <- Runs.get(id),
         {:ok, _run, _what} <- Runs.approve(run) do
      {:noreply, assign_run(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
      _ -> {:noreply, assign_run(socket)}
    end
  end

  def handle_event("request_playbook_changes", %{"run_id" => id, "note" => note}, socket) do
    with %Run{} = run <- Runs.get(id),
         {:ok, _run, _what} <- Runs.request_changes(run, note) do
      {:noreply, assign_run(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, String.capitalize(reason) <> ".")}
      _ -> {:noreply, assign_run(socket)}
    end
  end

  def handle_event("reassign_coordinator", %{"run_id" => id, "agent_id" => agent_id}, socket) do
    with %Run{} = run <- Runs.get(id),
         %Canopy.Agents.Agent{} = agent <- Canopy.Agents.get(agent_id),
         {:ok, _run, _what} <- Runs.reassign(run, agent, "user") do
      {:noreply, assign_run(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
      _ -> {:noreply, assign_run(socket)}
    end
  end

  def handle_event("toggle_schedules", _params, socket),
    do: {:noreply, toggle_in_details(socket, :editing_schedules?, "schedules")}

  def handle_event("cancel_schedule", %{"id" => id}, socket) do
    case Schedules.get(id) do
      nil ->
        {:noreply, socket}

      schedule ->
        {:ok, _} = Schedules.cancel(schedule, "cancelled by #{socket.assigns.user.display_name}")
        {:noreply, assign(socket, :schedules, Schedules.list_for_channel(cid(socket)))}
    end
  end

  def handle_event("toggle_locks", _params, socket),
    do: handle_event("open_details", %{"section" => "locks"}, socket)

  # The user's way out of a stuck lock: whoever holds it lets go now, and the
  # next in line is woken. Also how the user releases a lock they took.
  def handle_event("force_release", %{"name" => name}, socket) do
    %{channel: channel, user: user} = socket.assigns

    socket =
      case Locks.force_release(channel.repository_id, name, user) do
        {:ok, nil} ->
          put_flash(socket, :info, "Released `#{name}`; nobody was waiting.")

        {:ok, next} ->
          put_flash(socket, :info, "Released `#{name}`; #{Locks.holder_name(next)} has it now.")

        {:error, :not_found} ->
          put_flash(socket, :error, "Nobody holds `#{name}` any more.")

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, watch_locks(socket)}
  end

  # A lock the user holds by hand ("don't touch the tree, I'm testing"):
  # agents that ask for it wait until the user releases it.
  def handle_event("take_lock", %{"lock" => %{"name" => name} = params}, socket) do
    %{channel: channel, user: user} = socket.assigns

    socket =
      case Locks.acquire_for_user(user, channel, name, params["reason"]) do
        {:granted, claim} ->
          socket
          |> assign(:taking_lock?, false)
          |> assign(
            :lock_form,
            to_form(%{"name" => Locks.default_name(), "reason" => ""}, as: :lock)
          )
          |> put_flash(
            :info,
            "You hold `#{claim.name}`. Agents that ask for it wait until you release it."
          )

        {:already_held, claim} ->
          put_flash(socket, :info, "You already hold `#{claim.name}`.")

        {:error, {:held, holder}} ->
          put_flash(
            socket,
            :error,
            "`#{holder.name}` is held by #{Locks.holder_name(holder)}. Force release it first, or wait."
          )

        {:error, %Ecto.Changeset{}} ->
          put_flash(socket, :error, "Could not take that lock.")

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, watch_locks(socket)}
  end

  def handle_event("toggle_members", _params, socket) do
    socket = toggle_in_details(socket, :editing_members?, "agents")

    {:noreply, if(socket.assigns.editing_members?, do: refresh_members(socket), else: socket)}
  end

  def handle_event("toggle_budget", _params, socket),
    do: {:noreply, toggle_in_details(socket, :editing_budget?, "spend")}

  # Only the user changes a limit: this event has no agent counterpart.
  def handle_event("set_spend_limit", %{"spend_limit" => value}, socket) do
    case Channels.set_spend_limit(socket.assigns.channel, value) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> assign(:editing_budget?, false)
         |> put_flash(
           :info,
           if(channel.spend_limit,
             do: "Spend limit set to #{Costs.money(channel.spend_limit)}.",
             else: "Spend limit removed."
           )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "The limit must be a positive amount in dollars.")}
    end
  end

  def handle_event("clear_spend_limit", _params, socket) do
    {:ok, channel} = Channels.set_spend_limit(socket.assigns.channel, nil)

    {:noreply,
     socket
     |> assign(:channel, channel)
     |> assign(:editing_budget?, false)
     |> put_flash(:info, "Spend limit removed.")}
  end

  def handle_event("add_member", %{"agent_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_member", %{"agent_id" => agent_id}, socket) do
    case Channels.add_agent(socket.assigns.channel, agent_id) do
      {:ok, _} -> {:noreply, refresh_members(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add that agent.")}
    end
  end

  def handle_event("invite_team", %{"team_id" => ""}, socket), do: {:noreply, socket}

  # Inviting a team into the channel is quiet, like adding an agent: nobody
  # wakes until someone mentions them.
  def handle_event("invite_team", %{"team_id" => team_id}, socket) do
    names = fn agents -> Enum.map_join(agents, ", ", &("@" <> &1.name)) end

    with %Teams.Team{} = team <- Teams.get(team_id),
         {:ok, %{added: added, already: already}} <-
           Channels.add_team(socket.assigns.channel, team, "user") do
      note =
        cond do
          added == [] ->
            "Everyone on @#{team.name} is already here."

          already == [] ->
            "Added #{names.(added)}."

          true ->
            "Added #{names.(added)} (#{names.(already)} #{if length(already) == 1, do: "was", else: "were"} already here)."
        end

      {:noreply, socket |> refresh_members() |> put_flash(:info, note)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not add that team.")}
    end
  end

  def handle_event("remove_member", %{"agent-id" => agent_id}, socket) do
    case Channels.remove_agent(socket.assigns.channel, agent_id) do
      {:ok, _} ->
        {:noreply, refresh_members(socket)}

      {:error, :owner} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The owner cannot be removed. Hand the task off first with /handoff @agent."
         )}
    end
  end

  def handle_event("archive_channel", _params, socket) do
    {:ok, channel} = Channels.archive(socket.assigns.channel)

    {:noreply,
     socket
     |> assign(:channel, channel)
     |> assign(:editing_members?, false)
     |> assign(:editing_task?, false)
     |> Nav.refresh_nav()
     |> put_flash(:info, "##{channel.name} archived. Reopen it any time from its header.")}
  end

  def handle_event("reopen_channel", _params, socket) do
    {:ok, channel} = Channels.reopen(socket.assigns.channel)
    {:noreply, socket |> assign(:channel, channel) |> Nav.refresh_nav()}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    changeset =
      socket.assigns.task
      |> Tasks.change(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :task_form, to_form(changeset, id: "task-form"))}
  end

  def handle_event("save_task", %{"task" => params}, socket) do
    case Tasks.update(socket.assigns.task, params) do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign_task(task)
         |> assign(:editing_task?, false)
         |> put_flash(:info, "Task updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :task_form, to_form(changeset, id: "task-form"))}
    end
  end

  # The Changes modal; a file chip or an edit row of an activity card opens
  # it on that file (`path`, relative to the repository).
  def handle_event("open_changes", params, socket) do
    changes =
      case Repositories.status(socket.assigns.channel.repository) do
        {:ok, lines} ->
          %{files: Enum.map(lines, &status_line/1), selected: nil, diff: nil, error: nil}

        {:error, reason} ->
          %{files: [], selected: nil, diff: nil, error: reason}
      end

    socket = assign(socket, :changes, changes)

    case params["path"] do
      path when is_binary(path) and path != "" -> {:noreply, select_file(socket, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_changes", _params, socket),
    do: {:noreply, assign(socket, :changes, nil)}

  def handle_event("select_file", %{"path" => path}, socket),
    do: {:noreply, select_file(socket, path)}

  def handle_event("load_earlier", _params, socket) do
    older =
      Timeline.list(cid(socket),
        limit: @page_size,
        before: socket.assigns.oldest_event_id,
        scope: :channel
      )

    {:noreply,
     socket
     |> merge_feed(older)
     |> assign(
       :oldest_event_id,
       older |> List.first() |> then(&(&1 && &1.id)) || socket.assigns.oldest_event_id
     )
     |> assign(:has_earlier?, length(older) >= @page_size)
     |> stream(:timeline, Enum.reverse(older), at: 0)}
  end

  # History pages forward; the newest page makes the feed live again.
  def handle_event("load_newer", _params, %{assigns: %{window: :history}} = socket) do
    newer =
      Timeline.list_after(cid(socket), socket.assigns.newest_event_id,
        limit: @page_size,
        scope: :channel
      )

    socket = socket |> merge_feed(newer) |> stream(:timeline, newer)

    {:noreply,
     if length(newer) < @page_size do
       socket |> assign(:window, :live) |> assign(:held, 0) |> assign(:newest_event_id, nil)
     else
       assign(socket, :newest_event_id, List.last(newer).id)
     end}
  end

  def handle_event("load_newer", _params, socket), do: {:noreply, socket}

  def handle_event("jump_to_latest", _params, socket), do: {:noreply, to_latest(socket)}

  defp history?(socket), do: socket.assigns.window == :history

  defp select_file(socket, path) do
    changes = socket.assigns.changes || %{files: [], selected: nil, diff: nil, error: nil}

    diff =
      case Repositories.file_diff(socket.assigns.channel.repository, path) do
        {:ok, ""} -> "(no textual diff)"
        {:ok, patch} -> patch
        {:error, reason} -> "Could not read diff: #{reason}"
      end

    assign(socket, :changes, %{changes | selected: path, diff: diff})
  end

  defp set_auto_open(socket, on?) do
    act = socket.assigns.act

    open_live =
      if on?,
        do: MapSet.union(act.open_live, MapSet.new(Map.keys(socket.assigns.telemetry))),
        else: act.open_live

    assign(socket, :act, %{act | auto_open?: on?, open_live: open_live})
  end

  # A finished turn of this channel, or nil.
  defp channel_turn(socket, event_id) do
    case Timeline.get(event_id) do
      %{event_type: "agent_turn_completed", channel_id: channel_id} = event
      when channel_id == socket.assigns.channel.id ->
        event

      _ ->
        nil
    end
  end

  # `git status --porcelain`: two status columns, a space, then the path.
  defp status_line(line) do
    %{
      status: String.slice(line, 0, 2) |> String.trim(),
      path: line |> String.slice(3..-1//1) |> String.trim()
    }
  end

  # -- Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
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
      agent_statuses={@agent_statuses}
    >
      <div id="channel-layout" class="flex min-h-0 flex-1 overflow-hidden">
        <%!-- A container, so the header drops its button labels when the side
           panel narrows the column, not only on a narrow window. --%>
        <div id="channel-main" class="@container/main flex min-w-0 flex-1 flex-col overflow-hidden">
          <.channel_header
            channel={@channel}
            members={@members}
            agent_statuses={@agent_statuses}
            schedule_count={Enum.count(@schedules, &(&1.status == "active"))}
            spent={@spent}
            locks={@locks}
            now={@now}
            run={@run}
            names={@names}
            details?={@details? and !@thread and !@activity}
          />

          <.brief_panel
            channel={@channel}
            editing?={@editing_brief?}
            form={@brief_form}
            text={@brief_text}
            expanded?={@brief_expanded?}
            history={@brief_history}
            viewing={@brief_viewing}
            conflict={@brief_conflict}
            agents={Enum.count(@members, & &1.active)}
            names={@names}
            user_name={@user.display_name}
            channel_links={@channel_links}
            mention_names={@mention_names}
          />
          <%!-- remembers whether the pinned brief is open, for this browser --%>
          <span id="channel-brief-pref" phx-hook="Pref" data-pref="channel-brief" hidden />
          <%!-- remembers whether Details is open, from lg up; below lg it is a
               full-screen overlay and never opens by itself. Before the
               playbook runs seen, which may open it. --%>
          <span
            id="channel-details-pref"
            phx-hook="Pref"
            data-pref="channel-details"
            data-pref-media="(min-width: 1024px)"
            hidden
          />
          <%!-- remembers "Routine activity", for this browser --%>
          <span id="timeline-activity-pref" phx-hook="Pref" data-pref="timeline-activity" hidden />
          <%!-- the playbook runs this browser has seen: a new one's panel opens once --%>
          <span
            id="playbook-seen-pref"
            phx-hook="Pref"
            data-pref="playbook-seen"
            data-pref-always="true"
            hidden
          />

          <.handoff_banner
            :for={handoff <- @pending_handoffs}
            handoff={handoff}
            names={@names}
            user_name={@user.display_name}
          />

          <div
            id="timeline-scroll"
            class="relative flex-1 overflow-y-auto scroll-smooth"
            phx-hook="TimelineScroll"
            data-feed="#timeline"
            data-highlights
          >
            <div :if={@has_earlier?} class="flex justify-center py-2">
              <button
                type="button"
                id="load-earlier"
                class="btn btn-xs btn-ghost text-base-content/60"
                phx-click="load_earlier"
              >
                Load earlier
              </button>
            </div>

            <div
              id="timeline"
              phx-update="stream"
              class={["flex flex-col py-2", @compact? && "timeline-compact"]}
            >
              <div
                id="timeline-empty"
                class="hidden only:flex flex-col items-center gap-1 px-3 py-16 text-center text-sm text-base-content/60"
              >
                <.icon name="hero-chat-bubble-oval-left-ellipsis" class="size-8 opacity-40" />
                Nothing here yet. Say something to wake the owner, or mention an agent.
              </div>
              <.timeline_item
                :for={{id, event} <- @streams.timeline}
                id={id}
                event={event}
                names={@names}
                user_name={@user.display_name}
                root={repo_root(@channel)}
                thread={
                  feed_thread(
                    event,
                    @channel,
                    @summaries,
                    @thread,
                    @thread_unread,
                    @turn_threads,
                    @names
                  )
                }
                channels={@channel_links}
                mentions={@mention_names}
                activity={turn_ui(@act, @activity, event)}
                receipt={receipt_of(@receipts, event)}
                queued={queued_mark(@queued, event)}
                reactable={!Channels.archived?(@channel)}
              />
            </div>

            <div :if={@window == :history} class="flex justify-center py-2">
              <button
                type="button"
                id="load-newer"
                class="btn btn-xs btn-ghost text-base-content/60"
                phx-click="load_newer"
              >
                Load newer
              </button>
            </div>

            <%!-- A turn working for a thread shows its live card and its cards in
             the thread panel; the feed keeps the channel's own. --%>
            <.telemetry_card
              :for={{agent_id, card} <- @telemetry}
              :if={place(@turn_threads, agent_id, @thread) == :feed}
              agent_id={agent_id}
              name={Map.get(@names, agent_id, "agent")}
              card={card}
              root={repo_root(@channel)}
              channel_id={@channel.id}
              status={Map.get(@agent_statuses, agent_id, :busy)}
              open?={MapSet.member?(@act.open_live, agent_id)}
              open_rows={rows_of(@act.open_rows, "telemetry-" <> agent_id)}
              highlight={live_in_panel?(@activity, agent_id)}
              auto_open?={@act.auto_open?}
              steer={Map.get(@steers, agent_id)}
              question={live_question(@pending_questions, agent_id)}
              draft={draft_for(@question_drafts, live_question(@pending_questions, agent_id))}
            />

            <.permission_card
              :for={request <- @pending_permissions}
              :if={place(@turn_threads, card_agent_id(request), @thread) != :panel}
              request={request}
              names={@names}
            />
            <.question_card
              :for={request <- @pending_questions}
              :if={
                place(@turn_threads, card_agent_id(request), @thread) != :panel and
                  !folded_question?(request, @pending_questions, @telemetry, @turn_threads, @thread)
              }
              request={request}
              names={@names}
              draft={Map.get(@question_drafts, request.id, %{})}
            />
          </div>

          <div :if={@window == :history} class="relative z-10 h-0">
            <button
              type="button"
              id="jump-to-latest"
              class="btn btn-sm btn-primary absolute bottom-3 left-1/2 -translate-x-1/2 gap-1 rounded-full shadow-lg"
              phx-click="jump_to_latest"
            >
              <.icon name="hero-arrow-down-mini" class="size-4" /> Jump to latest
              <span :if={@held > 0} id="jump-to-latest-count" class="font-normal opacity-80">
                · {@held} new
              </span>
            </button>
          </div>

          <.limit_bar
            :if={limit_reached?(@channel, @spent) and !Channels.archived?(@channel)}
            channel={@channel}
            spent={@spent}
          />
          <.paused_bar :if={@paused? and !Channels.archived?(@channel)} stopped?={@stopped?} />
          <.awaiting_bar :if={!Channels.archived?(@channel)} waiting={@waiting_on_user} />
          <.composer
            :if={!Channels.archived?(@channel)}
            id="composer"
            class={(@thread || @activity || @details?) && "max-lg:hidden"}
            submit="send"
            waiting={@waiting_on_user}
            interrupt={@interrupt_on?}
            working={working_names(@interrupt_on?, @agent_statuses, @names)}
            form={@composer}
            agent_names={@agent_names}
            member_names={@member_names}
            team_names={@team_names}
            team_members={@team_members}
            channel_names={@channel_names}
            channel_refs={Map.keys(@channel_links)}
            upload={@uploads.files}
            picked={@picked}
            dm={Channels.dm?(@channel)}
            placeholder="Message the channel — @mention an agent to wake it, #name a channel"
          />
          <.archived_bar :if={Channels.archived?(@channel)} channel={@channel} />
        </div>

        <.thread_panel
          :if={@thread}
          thread={@thread}
          stream={@streams.thread}
          channel={@channel}
          names={@names}
          user_name={@user.display_name}
          compact?={@compact?}
          channel_links={@channel_links}
          mention_names={@mention_names}
          telemetry={
            for {agent_id, card} <- @telemetry,
                place(@turn_threads, agent_id, @thread) == :panel,
                do: {agent_id, card}
          }
          permissions={
            Enum.filter(
              @pending_permissions,
              &(place(@turn_threads, card_agent_id(&1), @thread) == :panel)
            )
          }
          questions={
            Enum.filter(
              @pending_questions,
              &(place(@turn_threads, card_agent_id(&1), @thread) == :panel)
            )
          }
          drafts={@question_drafts}
          waiting={@waiting_on_user}
          form={@thread_composer}
          agent_names={@agent_names}
          member_names={@member_names}
          team_names={@team_names}
          team_members={@team_members}
          channel_names={@channel_names}
          upload={@uploads.thread_files}
          picked={@thread_picked}
          act={@act}
          activity={@activity}
          receipts={@receipts}
          queued={@queued}
          agent_statuses={@agent_statuses}
          steers={@steers}
          interrupt={@interrupt_on?}
          working={working_names(@interrupt_on?, @agent_statuses, @names)}
        />

        <.activity_panel
          :if={@activity}
          activity={@activity}
          channel={@channel}
          names={@names}
          user_name={@user.display_name}
          telemetry={@telemetry}
          agent_statuses={@agent_statuses}
          act={@act}
          mentions={@mention_names}
        />

        <.details_panel
          :if={@details? and !@thread and !@activity}
          channel={@channel}
          task={@task}
          task_form={@task_form}
          editing_task?={@editing_task?}
          branch={@branch}
          repositories={@repositories}
          names={@names}
          user_name={@user.display_name}
          members={@members}
          agent_statuses={@agent_statuses}
          telemetry={@telemetry}
          awaiting={awaiting_since(@pending_permissions, @pending_questions)}
          steers={@steers}
          editing_members?={@editing_members?}
          addable={@addable_agents}
          addable_teams={@addable_teams}
          locks={@locks}
          now={@now}
          lock_form={@lock_form}
          taking_lock?={@taking_lock?}
          run={@run}
          editing_playbook?={@editing_playbook?}
          start_form={@start_form}
          playbooks={@run_playbooks}
          run_agents={@run_agents}
          recent_runs={@recent_runs}
          schedules={@schedules}
          editing_schedules?={@editing_schedules?}
          spent={@spent}
          editing_budget?={@editing_budget?}
          compact?={@compact?}
        />
      </div>
      <%!-- remembers "Open live activity automatically" for this browser --%>
      <span id="activity-open-live-pref" phx-hook="Pref" data-pref="activity-open-live" hidden />
      <.library_picker :if={@library} library={@library} />

      <.changes_modal :if={@changes} changes={@changes} repository={@channel.repository} />
    </Layouts.app>
    """
  end

  defp channel_title(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp channel_title(channel), do: "#" <> channel.name

  @doc false
  # `/channels/:id?thread=<root>`, with `&reply=<id>` to point at one reply.
  def thread_path(channel_id, root_id, reply_id \\ nil)

  def thread_path(channel_id, root_id, nil),
    do: ~p"/channels/#{channel_id}?#{[thread: root_id]}"

  def thread_path(channel_id, root_id, reply_id),
    do: ~p"/channels/#{channel_id}?#{[thread: root_id, reply: reply_id]}"

  # What a feed message shows about threads (see `timeline_item/1`): Reply in
  # thread and Copy link; a root's summary row; for a reply also sent to the
  # channel, the thread it belongs to.
  defp feed_thread(
         %{event_type: "message", message: %{kind: kind} = message},
         channel,
         summaries,
         thread,
         unread,
         turn_threads,
         names
       )
       when kind != "system" do
    root_id = message.thread_id || message.id
    open? = open_root(%{thread: thread}) == root_id
    working = for {agent_id, ^root_id} <- turn_threads, do: Map.get(names, agent_id, "agent")

    summary =
      case {message.thread_id, Map.get(summaries, root_id)} do
        {nil, %{} = summary} ->
          Map.merge(summary, %{
            root_id: root_id,
            open?: open?,
            unread?: MapSet.member?(unread, root_id),
            working: Enum.sort(working)
          })

        _ ->
          nil
      end

    parent =
      if message.thread_id do
        %{href: thread_path(channel.id, root_id, message.id), excerpt: excerpt(message.thread)}
      end

    %{
      href: thread_path(channel.id, root_id),
      link: thread_path(channel.id, root_id, message.thread_id && message.id),
      summary: summary,
      parent: parent,
      highlight: open? and is_nil(message.thread_id)
    }
  end

  defp feed_thread(_event, _channel, _summaries, _thread, _unread, _turn_threads, _names),
    do: %{}

  # What a message in the thread panel shows: Copy link, the reply count under
  # the root, and the mark on the reply a link pointed at.
  defp panel_thread(%{event_type: "message", message: message}, channel, thread) do
    root_id = thread.root.id

    %{
      link: thread_path(channel.id, root_id, if(message.id != root_id, do: message.id)),
      divider: if(message.id == root_id, do: thread.count),
      target: thread.target == message.id
    }
  end

  defp panel_thread(_event, _channel, _thread), do: %{}

  # Where an agent's live card and cards go: the panel when its turn works for
  # the open thread, nowhere but the summary row when it works for another
  # thread (cards still show in the feed, since they wait on the user), the
  # feed otherwise.
  defp place(turn_threads, agent_id, thread) do
    case {Map.get(turn_threads, agent_id), open_root(%{thread: thread})} do
      {nil, _} -> :feed
      {root_id, root_id} -> :panel
      _ -> :elsewhere
    end
  end

  defp card_agent_id(%{agent_session: %{agent_id: id}}), do: id
  defp card_agent_id(_request), do: nil

  # The question an agent's live turn is blocked on: its live card becomes
  # the question card, so the two never stack. A detached question (the
  # agent stopped waiting) stays a card of its own.
  defp live_question(questions, agent_id),
    do: Enum.find(questions, &(is_nil(&1.detached_at) and card_agent_id(&1) == agent_id))

  defp folded_question?(request, questions, telemetry, turn_threads, thread) do
    agent_id = card_agent_id(request)

    Map.has_key?(telemetry, agent_id) and place(turn_threads, agent_id, thread) == :feed and
      live_question(questions, agent_id) == request
  end

  defp draft_for(_drafts, nil), do: %{}
  defp draft_for(drafts, request), do: Map.get(drafts, request.id, %{})

  defp repo_root(%{repository: %{path: path}}), do: path
  defp repo_root(_channel), do: nil

  defp playbook_chip_title(%{status: "awaiting_approval"} = run),
    do: "#{run.playbook_name} is waiting for your sign-off"

  defp playbook_chip_title(_run), do: "Playbook run in progress"

  defp playbook_chip_icon(%{status: "awaiting_approval"}), do: "hero-hand-raised-mini"
  defp playbook_chip_icon(_run), do: "hero-book-open-mini"

  defp spend_text(channel, spent) do
    Costs.money(spent) <>
      if channel.spend_limit, do: " / " <> Costs.money(channel.spend_limit), else: ""
  end

  # `$44.69 · no limit`, `$44.69 of $50.00`: Details › Automation › Spend
  defp spend_value(%{spend_limit: limit}, spent) when is_number(limit),
    do: Costs.money(spent) <> " of " <> Costs.money(limit)

  defp spend_value(_channel, spent), do: Costs.money(spent) <> " · no limit"

  # Who needs the user first: waiting on you, then working, queued, idle.
  @status_rank %{awaiting_user: 0, busy: 1, queued: 2}

  defp by_status(members, statuses),
    do: Enum.sort_by(members, &Map.get(@status_rank, Map.get(statuses, &1.id, :idle), 3))

  defp status_word(:awaiting_user), do: "waiting on you"
  defp status_word(:busy), do: "working"
  defp status_word(:queued), do: "queued"
  defp status_word(:error), do: "error"
  defp status_word(_status), do: "idle"

  # "4 agents: @frontend working, @designer waiting on you"
  defp agents_title(members, statuses) do
    active =
      members
      |> by_status(statuses)
      |> Enum.flat_map(fn member ->
        case Map.get(statuses, member.id, :idle) do
          :idle -> []
          status -> ["@#{member.name} #{status_word(status)}"]
        end
      end)

    case active do
      [] -> agents_label(length(members)) <> ", all idle"
      _ -> agents_label(length(members)) <> ": " <> Enum.join(active, ", ")
    end
  end

  # The Details button's dot, while Details is closed: something in it wants
  # a look that the header doesn't show (an agent in line for a lock, active
  # schedules).
  defp details_dot(locks, schedule_count) do
    cond do
      Enum.any?(locks, fn lock -> Enum.any?(lock.queue, & &1.agent_id) end) ->
        {"bg-warning", "An agent is waiting for a lock"}

      schedule_count > 0 ->
        {"bg-primary", "#{schedule_count} scheduled"}

      true ->
        nil
    end
  end

  # When each agent started waiting on the user: its oldest pending card.
  defp awaiting_since(permissions, questions) do
    Enum.reduce(permissions ++ questions, %{}, fn request, acc ->
      case card_agent_id(request) do
        nil ->
          acc

        id ->
          Map.update(acc, id, request.inserted_at, &Enum.min([&1, request.inserted_at], DateTime))
      end
    end)
  end

  # What the agent row's timing counts from (wall-clock ms), and its title:
  # a working agent's turn, or the card an agent waiting on you raised.
  # Queued and idle agents show no time.
  defp member_since(status, agent_id, telemetry, awaiting) do
    case {status, Map.get(telemetry, agent_id), Map.get(awaiting, agent_id)} do
      {:awaiting_user, _card, %DateTime{} = at} ->
        ms = DateTime.to_unix(at, :millisecond)
        {ms, "Waiting on you since " <> clock_ms(ms)}

      {:busy, %{started_at: ms}, _at} when is_integer(ms) ->
        {ms, "Working since " <> clock_ms(ms)}

      _ ->
        nil
    end
  end

  attr :channel, :map, required: true
  attr :members, :list, required: true
  attr :agent_statuses, :map, required: true
  attr :schedule_count, :integer, default: 0
  attr :spent, :float, default: 0.0
  attr :locks, :list, default: []
  attr :now, :any, default: nil
  attr :run, :any, default: nil
  attr :names, :map, default: %{}
  attr :details?, :boolean, default: false

  defp channel_header(assigns) do
    %{members: members, agent_statuses: statuses} = assigns

    assigns =
      assigns
      |> assign(:dm?, Channels.dm?(assigns.channel))
      |> assign(:archived?, Channels.archived?(assigns.channel))
      |> assign(:dots, members |> by_status(statuses) |> Enum.take(5))
      |> assign(:waiting, Enum.count(members, &(Map.get(statuses, &1.id) == :awaiting_user)))
      |> assign(:dot, details_dot(assigns.locks, assigns.schedule_count))

    ~H"""
    <%!-- One row. The HeaderFit hook (assets/js/hooks/header_fit.js) fits it
         to the header's own width by setting data-fit, and the rules under
         "Channel header" in app.css act on it: the topic goes first, then
         labels shorten and the spend and Changes buttons go (Details has
         them), Stop drops its label, and on a phone the chips shrink to
         icons and counts while the name truncates. The rest of the channel's
         controls live in the Details panel. --%>
    <header
      id="channel-header"
      phx-hook="HeaderFit"
      data-fit=""
      class="flex h-12 shrink-0 items-center border-b border-base-300 px-3 sm:h-14 sm:px-6"
    >
      <div id="channel-header-row" class="flex min-w-0 flex-1 items-center gap-2 sm:gap-3">
        <Layouts.menu_button />
        <h1
          id="channel-name"
          class="flex min-w-0 items-baseline gap-1 overflow-hidden whitespace-nowrap text-base font-semibold sm:shrink-0"
        >
          <%= if @dm? do %>
            {Channels.dm_label(@channel)}
            <span
              class="ml-1 rounded-full bg-base-300/70 px-1.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60"
              title="A direct message: only this agent is in the channel"
            >
              dm
            </span>
          <% else %>
            <span class="text-base-content/40">#</span><span class="truncate">{@channel.name}</span>
          <% end %>
        </h1>
        <p
          :if={@channel.topic && !@dm?}
          class="min-w-0 truncate text-sm text-base-content/60"
          id="channel-topic"
        >
          {@channel.topic}
        </p>
        <div id="channel-header-actions" class="ml-auto flex shrink-0 items-center gap-1">
          <span
            :if={@archived?}
            id="archived-badge"
            class="badge badge-sm badge-ghost gap-1"
            title="No one can post here until it is reopened"
          >
            <.icon name="hero-archive-box-mini" class="size-3" /> archived
          </span>
          <button
            :for={lock <- @locks}
            type="button"
            id={"lock-chip-#{lock_dom_id(lock.name)}"}
            class="btn btn-sm btn-ghost max-w-72 gap-1.5 px-2 font-normal text-warning"
            phx-click="open_details"
            phx-value-section="locks"
            title={lock_title(lock, @now)}
            aria-label={"Lock " <> lock.name}
          >
            <.icon name="hero-lock-closed-mini" class="size-4 shrink-0" />
            <span data-hdr-chip-label class="font-mono font-medium">{lock.name}</span>
            <span data-hdr-detail class="min-w-0 truncate text-base-content/70">
              {lock_summary(lock, @now)}
            </span>
            <span
              :if={lock.awaiting_user?}
              id={"lock-chip-#{lock_dom_id(lock.name)}-awaiting"}
              class="size-2 shrink-0 rounded-full bg-info"
              title="The holder is waiting on your answer to a card"
            />
          </button>
          <button
            :if={@run}
            type="button"
            id="playbook-chip"
            data-status={@run.status}
            class={[
              "btn btn-sm btn-ghost max-w-80 gap-1.5 px-2 font-normal",
              @run.status == "awaiting_approval" && "text-warning"
            ]}
            phx-click="open_details"
            phx-value-section="playbook"
            title={playbook_chip_title(@run)}
            aria-label={"Playbook: " <> PlaybookComponents.chip_text(@run, @names)}
          >
            <.icon name={playbook_chip_icon(@run)} class="size-4 shrink-0" />
            <span data-hdr-detail class="min-w-0 truncate">
              {PlaybookComponents.chip_text(@run, @names)}
            </span>
          </button>
          <button
            :if={!@dm?}
            type="button"
            id="agents-button"
            class="btn btn-sm btn-ghost gap-2 px-2 font-normal"
            phx-click="open_details"
            phx-value-section="agents"
            title={agents_title(@members, @agent_statuses)}
            aria-label={agents_title(@members, @agent_statuses)}
          >
            <span :if={@members != []} data-hdr-dots class="flex items-center gap-1">
              <Layouts.status_dot
                :for={member <- @dots}
                status={Map.get(@agent_statuses, member.id, :idle)}
              />
              <span :if={length(@members) > 5} class="text-[11px] text-base-content/50">
                +{length(@members) - 5}
              </span>
            </span>
            <span data-hdr-label>{agents_label(length(@members))}</span>
            <span
              :if={@waiting > 0}
              id="agents-waiting"
              class="rounded-full bg-info/15 px-1.5 text-[11px] font-medium text-info"
            >
              {@waiting}<span data-hdr-label> waiting on you</span><span data-hdr-short> waiting</span>
            </span>
          </button>
          <button
            type="button"
            id="edit-budget"
            class={[
              "btn btn-sm btn-ghost gap-1.5 px-2 font-normal tabular-nums",
              limit_reached?(@channel, @spent) && "text-error"
            ]}
            phx-click="open_details"
            phx-value-section="spend"
            title="What this channel has spent, and its limit"
            aria-label={"Spend " <> spend_text(@channel, @spent)}
          >
            <.icon
              name="hero-banknotes-mini"
              class={["size-4", !limit_reached?(@channel, @spent) && "text-base-content/60"]}
            />
            {spend_text(@channel, @spent)}
          </button>
          <button
            type="button"
            id="open-changes"
            data-hdr="rest"
            class="btn btn-sm btn-ghost gap-1.5 px-2 font-normal"
            phx-click="open_changes"
            title="Changes in the working tree"
            aria-label="Changes"
          >
            <.icon name="hero-document-plus-mini" class="size-4 text-base-content/60" />
            <span data-hdr-label>Changes</span>
          </button>
          <span
            :if={!@archived?}
            data-hdr-divider
            class="mx-1.5 h-5 w-px bg-base-300"
            aria-hidden="true"
          />
          <button
            :if={!@archived?}
            type="button"
            id="stop-all"
            data-hdr="stop"
            class="btn btn-sm btn-ghost gap-1.5 px-2 text-error"
            phx-click="stop_all"
            title="Stop all: abort every running turn, drop queued wakes, and hold the channel until you reply"
            aria-label="Stop all"
          >
            <.icon name="hero-stop-mini" class="size-4" />
            <span data-hdr-label>Stop</span>
          </button>
          <button
            :if={@archived?}
            type="button"
            id="reopen-channel"
            data-hdr="stop"
            class="btn btn-sm btn-ghost gap-1.5 px-2"
            phx-click="reopen_channel"
            title="Reopen this channel"
            aria-label="Reopen"
          >
            <.icon name="hero-archive-box-x-mark-mini" class="size-4" />
            <span data-hdr-label>Reopen</span>
          </button>
          <button
            type="button"
            id="toggle-details"
            data-hdr="rest"
            class={["btn btn-sm btn-ghost gap-1.5 px-2 font-normal", @details? && "btn-active"]}
            phx-click="toggle_details"
            aria-expanded={to_string(@details?)}
            aria-controls="details-panel"
            title={if @details?, do: "Hide channel details", else: "Channel details"}
          >
            <.icon name="hero-view-columns-mini" class="size-4" />
            <span data-hdr-label>Details</span>
            <span
              :if={@dot && !@details?}
              id="details-dot"
              class={["size-1.5 shrink-0 rounded-full", elem(@dot, 0)]}
              title={elem(@dot, 1)}
            />
          </button>
        </div>
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true, doc: "what `open_details` and `details:focus` call it"
  attr :title, :string, required: true
  attr :note, :string, default: nil
  attr :note_title, :string, default: nil
  attr :action, :string, default: nil, doc: "the label of the title row's link-button"
  attr :action_id, :string, default: nil
  attr :click, :string, default: nil
  slot :inner_block, required: true

  # One section of the Details panel: a small uppercase title row, with an
  # optional note and link-button, over its body.
  defp details_section(assigns) do
    ~H"""
    <section
      id={@id}
      data-section={@key}
      class="scroll-mt-2 border-b border-base-300 px-4 py-4 last:border-b-0"
    >
      <div class="mb-2.5 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
        <h3>{@title}</h3>
        <span
          :if={@note}
          class="min-w-0 truncate font-normal normal-case tracking-normal text-base-content/40"
          title={@note_title}
        >
          {@note}
        </span>
        <button
          :if={@action}
          type="button"
          id={@action_id}
          class="ml-auto shrink-0 text-xs font-medium normal-case tracking-normal text-primary hover:underline"
          phx-click={@click}
        >
          {@action}
        </button>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :open?, :boolean, default: false
  attr :click, :string, required: true
  attr :value_class, :any, default: nil
  slot :value
  slot :inner_block

  # A row of Details › Automation that opens its body in place.
  defp disclosure(assigns) do
    ~H"""
    <div data-section={@key} class="scroll-mt-2 rounded-md">
      <button
        type="button"
        id={@id}
        class="flex w-full items-center gap-2.5 rounded-md px-2 py-2 text-left text-[13px] hover:bg-base-200"
        phx-click={@click}
        aria-expanded={to_string(@open?)}
        aria-controls={@id <> "-body"}
      >
        <.icon name={@icon} class="size-4 shrink-0 text-base-content/60" />
        <span class="shrink-0">{@label}</span>
        <span class={["ml-auto min-w-0 truncate text-xs text-base-content/50", @value_class]}>
          {render_slot(@value)}
        </span>
        <.icon
          name={if @open?, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
          class="size-3.5 shrink-0 text-base-content/40"
        />
      </button>
      <div :if={@open?} id={@id <> "-body"} class="px-2 pb-2">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :channel, :map, required: true
  attr :task, :map, default: nil
  attr :task_form, :any, default: nil
  attr :editing_task?, :boolean, default: false
  attr :branch, :string, default: nil
  attr :repositories, :list, default: []
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :members, :list, required: true
  attr :agent_statuses, :map, required: true
  attr :telemetry, :map, default: %{}
  attr :awaiting, :map, default: %{}, doc: "`%{agent_id => DateTime}` its oldest pending card"
  attr :steers, :map, default: %{}, doc: "`%{agent_id => %{pending}}` steered into turns"
  attr :editing_members?, :boolean, default: false
  attr :addable, :list, default: []
  attr :addable_teams, :list, default: []
  attr :locks, :list, default: []
  attr :now, :any, default: nil
  attr :lock_form, :any, required: true
  attr :taking_lock?, :boolean, default: false
  attr :run, :any, default: nil
  attr :editing_playbook?, :boolean, default: false
  attr :start_form, :any, default: nil
  attr :playbooks, :list, default: []
  attr :run_agents, :list, default: []
  attr :recent_runs, :list, default: []
  attr :schedules, :list, default: []
  attr :editing_schedules?, :boolean, default: false
  attr :spent, :float, default: 0.0
  attr :editing_budget?, :boolean, default: false
  attr :compact?, :boolean, default: true

  # The channel's details in the side panel (the third kind, after a thread
  # and an activity): the task, the agents, the repository's locks, what runs
  # by itself, and how the feed shows. Every header chip opens it at its
  # section; the Details button toggles it.
  defp details_panel(assigns) do
    assigns =
      assigns
      |> assign(:dm?, Channels.dm?(assigns.channel))
      |> assign(:archived?, Channels.archived?(assigns.channel))
      |> assign(:schedule_count, Enum.count(assigns.schedules, &(&1.status == "active")))

    ~H"""
    <.side_panel id="details-panel" label="Channel details" close_click="close_panel">
      <:title>Channel details</:title>
      <div id="details-body" class="min-h-0 flex-1 overflow-y-auto text-[13px]">
        <.details_section
          id="details-task"
          key="task"
          title="Task"
          action={@task && !@editing_task? && "Edit"}
          action_id="edit-task"
          click="toggle_task_form"
        >
          <%= if @editing_task? and @task_form do %>
            <.task_panel form={@task_form} />
          <% else %>
            <p :if={@task} class="flex items-start gap-2 text-sm">
              <span
                id="task-status"
                class={["badge badge-xs mt-1 shrink-0", task_badge(@task.status)]}
              >
                {@task.status}
              </span>
              <span id="task-title" class="min-w-0">{@task.title}</span>
            </p>
            <p
              :if={@task && @task.description not in [nil, ""]}
              id="task-description"
              class="mt-1 line-clamp-3 text-xs text-base-content/70"
            >
              {@task.description}
            </p>
            <p :if={!@task} class="text-sm text-base-content/60">No task yet.</p>
          <% end %>
          <dl class="mt-3 grid grid-cols-[6rem_1fr] items-baseline gap-y-1.5 text-xs">
            <dt class="text-base-content/50">Owner</dt>
            <dd id="owner-badge" class={!@channel.owner && "text-base-content/50"}>
              {if @channel.owner, do: "@" <> @channel.owner.name, else: "no owner"}
            </dd>
            <dt class="text-base-content/50">Branch</dt>
            <dd id="branch" class="min-w-0 truncate font-mono">{@branch || "—"}</dd>
            <dt class="text-base-content/50">Repository</dt>
            <dd class="min-w-0">
              <form
                :if={@dm?}
                id="dm-repository-form"
                phx-change="switch_repository"
                title="The repository this DM's agents work in; switch it to move the conversation"
              >
                <select
                  id="dm-repository"
                  name="repository_id"
                  class="select select-xs h-6 min-h-0 w-full max-w-56 border-base-300 bg-base-200 text-xs"
                  aria-label="Repository"
                >
                  <option
                    :for={repository <- @repositories}
                    value={repository.id}
                    selected={repository.id == @channel.repository_id}
                  >
                    {repository.name}
                  </option>
                </select>
              </form>
              <span :if={!@dm?} id="details-repository">{@channel.repository.name}</span>
            </dd>
            <dt class="text-base-content/50">Brief</dt>
            <dd id="details-brief">
              <%= if @channel.brief do %>
                set by {brief_author(@channel.brief_updated_by, @names, @user_name)} · {Canopy.MCP.Format.relative_time(
                  @channel.brief_updated_at
                )}
              <% else %>
                <span class="text-base-content/50">none ·</span>
              <% end %>
              <button
                :if={!@archived?}
                type="button"
                id="edit-brief"
                class="ml-1 font-medium text-primary hover:underline"
                phx-click="toggle_brief_form"
              >
                {if @channel.brief, do: "Edit", else: "Add"}
              </button>
            </dd>
            <dt class="text-base-content/50">Working tree</dt>
            <dd>
              <button
                type="button"
                id="details-changes"
                class="font-medium text-primary hover:underline"
                phx-click="open_changes"
              >
                Changes…
              </button>
            </dd>
          </dl>
        </.details_section>

        <.details_section
          id="details-agents"
          key="agents"
          title={if @dm?, do: "Agent", else: "Agents · #{length(@members)}"}
          action={!@dm? && !@archived? && if(@editing_members?, do: "Done", else: "Add or remove")}
          action_id="edit-members"
          click="toggle_members"
        >
          <ul id="members" class="-mx-2 flex flex-col">
            <.member_row
              :for={member <- @members}
              member={member}
              channel={@channel}
              status={Map.get(@agent_statuses, member.id, :idle)}
              since={
                member_since(
                  Map.get(@agent_statuses, member.id, :idle),
                  member.id,
                  @telemetry,
                  @awaiting
                )
              }
              held={locks_held(@locks, member.id)}
              queued={locks_queued(@locks, member.id)}
              steer={Map.get(@steers, member.id)}
              removable?={@editing_members? and member.id != @channel.owner_agent_id}
            />
          </ul>
          <.members_panel
            :if={@editing_members? and !@dm?}
            addable={@addable}
            addable_teams={@addable_teams}
          />
        </.details_section>

        <.details_section
          id="details-locks"
          key="locks"
          title="Locks"
          note={"shared by " <> @channel.repository.name}
          note_title={"Shared by every channel on #{@channel.repository.name}. Agents take them before running tests or anything that writes shared output; each frees itself when its holder's turn ends."}
          action={if @taking_lock?, do: "Cancel", else: "Take a lock"}
          action_id="take-lock-toggle"
          click="toggle_take_lock"
        >
          <.locks_panel
            locks={@locks}
            channel={@channel}
            now={@now}
            form={@lock_form}
            user_name={@user_name}
            taking?={@taking_lock?}
          />
        </.details_section>

        <.details_section id="details-automation" key="automation" title="Automation">
          <div class="-mx-2 flex flex-col">
            <.disclosure
              :if={!@dm?}
              id="edit-playbook"
              key="playbook"
              icon="hero-book-open-mini"
              label="Playbook"
              open?={@editing_playbook?}
              click="toggle_playbook"
              value_class={@run && @run.status == "awaiting_approval" && "text-warning"}
            >
              <:value>
                {if @run, do: PlaybookComponents.chip_text(@run, @names), else: "none running · Run…"}
              </:value>
              <PlaybookComponents.run_panel
                run={@run}
                names={@names}
                user_name={@user_name}
                start_form={@start_form}
                playbooks={@playbooks}
                agents={@run_agents}
                recent={@recent_runs}
                bare
              />
            </.disclosure>
            <.disclosure
              id="edit-schedules"
              key="schedules"
              icon="hero-clock-mini"
              label="Scheduled"
              open?={@editing_schedules?}
              click="toggle_schedules"
            >
              <:value>
                <span :if={@schedule_count > 0} id="schedule-count">{@schedule_count} active</span>
                <span :if={@schedule_count == 0}>none</span>
              </:value>
              <div id="schedules-panel">
                <p class="text-xs text-base-content/60">
                  Ask an agent to set a reminder or a repeat.
                </p>
                <.schedule_list id="channel-schedules" schedules={@schedules} scope={:channel} />
              </div>
            </.disclosure>
            <.disclosure
              id="edit-budget-row"
              key="spend"
              icon="hero-banknotes-mini"
              label="Spend"
              open?={@editing_budget?}
              click="toggle_budget"
              value_class={["tabular-nums", limit_reached?(@channel, @spent) && "text-error"]}
            >
              <:value>
                <span id="budget-spent">{spend_value(@channel, @spent)}</span>
              </:value>
              <.budget_panel channel={@channel} />
            </.disclosure>
          </div>
        </.details_section>

        <.details_section id="details-view" key="view" title="View">
          <div class="-mx-2 flex flex-col">
            <button
              type="button"
              id="toggle-activity"
              role="switch"
              aria-checked={to_string(!@compact?)}
              class="flex w-full items-center gap-2.5 rounded-md px-2 py-2 text-left text-[13px] hover:bg-base-200"
              phx-click="toggle_activity"
            >
              <.icon
                name="hero-eye-mini"
                class="size-4 shrink-0 self-start mt-0.5 text-base-content/60"
              />
              <span class="min-w-0 flex-1">
                Routine activity
                <span class="block text-[11px] text-base-content/50">
                  Tool calls and turn summaries in the feed
                </span>
              </span>
              <span
                class="toggle toggle-sm toggle-primary pointer-events-none shrink-0"
                aria-checked={to_string(!@compact?)}
                aria-hidden="true"
              />
            </button>
            <.link
              navigate={~p"/search?#{[channel: @channel.id]}"}
              id="search-channel"
              class="flex w-full items-center gap-2.5 rounded-md px-2 py-2 text-[13px] hover:bg-base-200"
            >
              <.icon name="hero-magnifying-glass-mini" class="size-4 shrink-0 text-base-content/60" />
              Search this channel
            </.link>
            <div :if={!@archived?} class="mt-1 border-t border-base-300 pt-1">
              <button
                type="button"
                id="archive-channel"
                class="flex w-full items-center gap-2.5 rounded-md px-2 py-2 text-left text-[13px] hover:bg-base-200"
                phx-click="archive_channel"
                data-canopy-confirm={"Nobody can post in ##{@channel.name} until it is reopened."}
                data-canopy-confirm-title={"Archive ##{@channel.name}?"}
                data-canopy-confirm-label="Archive"
              >
                <.icon
                  name="hero-archive-box-arrow-down-mini"
                  class="size-4 shrink-0 text-base-content/60"
                /> Archive channel…
              </button>
            </div>
          </div>
        </.details_section>
      </div>
    </.side_panel>
    """
  end

  attr :member, :map, required: true
  attr :channel, :map, required: true
  attr :status, :atom, required: true
  attr :since, :any, default: nil, doc: "`{started_at_ms, title}` for the row's timing, or nil"
  attr :held, :list, default: []
  attr :queued, :list, default: []
  attr :steer, :map, default: nil
  attr :removable?, :boolean, default: false

  # One agent in Details › Agents: its dot, name and status line (what it is
  # doing and for how long, the locks it holds or waits for, your messages it
  # will read mid-turn), then its transcript and Abort or Reset.
  defp member_row(assigns) do
    ~H"""
    <li
      id={"member-#{@member.id}"}
      class="group flex items-center gap-2.5 rounded-md px-2 py-1.5 hover:bg-base-200"
      title={@member.role}
    >
      <Layouts.status_dot status={@status} />
      <div class="min-w-0 flex-1">
        <p class="flex min-w-0 items-center gap-1.5 text-[13px] font-medium">
          <span class="truncate">@{@member.name}</span>
          <span
            :if={@member.id == @channel.owner_agent_id}
            class="rounded-full bg-primary/10 px-1.5 text-[10px] font-medium uppercase tracking-wide text-primary"
            title="The owner cannot be removed; hand the task off first"
          >
            owner
          </span>
          <.icon
            :if={@held != []}
            name="hero-lock-closed-micro"
            class="size-3.5 shrink-0 text-warning"
          />
        </p>
        <p class={[
          "flex flex-wrap gap-x-1 text-[11px]",
          if(@status == :awaiting_user, do: "text-info", else: "text-base-content/60")
        ]}>
          <span :if={@status == :awaiting_user} id={"member-#{@member.id}-awaiting"}>
            waiting on you
          </span>
          <span :if={@status != :awaiting_user}>{status_word(@status)}</span>
          <%= if @since do %>
            <span aria-hidden="true">·</span>
            <.elapsed
              id={"member-#{@member.id}-elapsed-#{elem(@since, 0)}"}
              started_at={elem(@since, 0)}
              coarse
              class="tabular-nums"
              title={elem(@since, 1)}
            />
          <% end %>
          <span
            :if={@held != []}
            id={"member-#{@member.id}-lock"}
            title={"Holds " <> lock_names(@held)}
          >
            · holds <span class="font-mono">{Enum.join(@held, ", ")}</span>
          </span>
          <span
            :if={@queued != []}
            id={"member-#{@member.id}-lock-queued"}
            title={"Waiting for " <> lock_names(@queued)}
          >
            · waiting for <span class="font-mono">{Enum.join(@queued, ", ")}</span>
          </span>
          <span
            :if={@steer}
            id={"member-#{@member.id}-steers"}
            class="text-secondary"
            title="Your messages it will read mid-turn"
          >
            · {@steer.pending} {if @steer.pending == 1, do: "message", else: "messages"} waiting
          </span>
        </p>
      </div>
      <.link
        navigate={~p"/channels/#{@channel.id}/agents/#{@member.id}/transcript"}
        id={"transcript-#{@member.id}"}
        class="btn btn-xs btn-ghost btn-square text-base-content/50 hover:text-base-content"
        title={"@#{@member.name}'s session transcript"}
        aria-label={"Open @#{@member.name}'s session transcript"}
      >
        <.icon name="hero-document-text-mini" class="size-3.5" />
      </.link>
      <button
        :if={@status in [:busy, :awaiting_user]}
        type="button"
        id={"abort-#{@member.id}"}
        class="btn btn-xs btn-ghost btn-square text-base-content/50 hover:text-error"
        phx-click="abort"
        phx-value-agent-id={@member.id}
        title="Abort the current turn"
        aria-label={"Abort @#{@member.name}'s turn"}
      >
        <.icon name="hero-stop-mini" class="size-3.5" />
      </button>
      <button
        :if={@status not in [:busy, :awaiting_user]}
        type="button"
        id={"reset-session-#{@member.id}"}
        class="btn btn-xs btn-ghost btn-square text-base-content/50 hover:text-base-content"
        phx-click="reset_session"
        phx-value-agent-id={@member.id}
        data-canopy-confirm={"Reset @#{@member.name}'s session in this channel? Its next turn starts with a fresh #{Canopy.Engine.label(Canopy.Agents.effective_engine(@member))} session; channel messages are kept, and the old session stays readable in its transcript."}
        title="Reset session (fresh context on the next turn)"
        aria-label={"Reset @#{@member.name}'s session"}
      >
        <.icon name="hero-arrow-path-mini" class="size-3.5" />
      </button>
      <button
        :if={@removable?}
        type="button"
        id={"remove-member-#{@member.id}"}
        class="btn btn-xs btn-ghost btn-square text-base-content/50 hover:text-error"
        phx-click="remove_member"
        phx-value-agent-id={@member.id}
        title={"Remove @#{@member.name} from this channel"}
        aria-label={"Remove @#{@member.name} from this channel"}
      >
        <.icon name="hero-x-mark-mini" class="size-3.5" />
      </button>
    </li>
    """
  end

  attr :locks, :list, required: true
  attr :channel, :map, required: true
  attr :now, :any, required: true
  attr :form, :any, required: true
  attr :user_name, :string, required: true
  attr :taking?, :boolean, default: false

  # Details › Locks: every lock on the repository (holder, how long, why, the
  # line behind it, and Force release), and the form to take one by hand. A
  # holder whose turn is blocked on a card is marked: its lock frees itself
  # only when that turn ends, so the card is the way on.
  defp locks_panel(assigns) do
    ~H"""
    <div id="locks-panel" class="flex flex-col gap-2">
      <p :if={@locks == []} id="locks-empty" class="text-xs text-base-content/60">
        No locks are held.
      </p>
      <ul :if={@locks != []} id="locks-list" class="flex flex-col gap-2">
        <li
          :for={lock <- @locks}
          id={"lock-#{lock_dom_id(lock.name)}"}
          class="flex flex-col gap-1.5 rounded-md border border-base-300 px-2.5 py-2"
        >
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <.icon name="hero-lock-closed-mini" class="size-4 text-warning" />
            <span class="font-mono font-semibold">{lock.name}</span>
            <%= if lock.holder do %>
              <span id={"lock-#{lock_dom_id(lock.name)}-holder"}>
                {holder_label(lock.holder, @user_name)}{lock_where(lock.holder, @channel)} · {Locks.age(
                  lock.holder,
                  @now || DateTime.utc_now()
                )}
              </span>
              <span :if={lock.holder.reason} class="text-base-content/60">
                “{lock.holder.reason}”
              </span>
              <span
                :if={lock.awaiting_user?}
                id={"lock-#{lock_dom_id(lock.name)}-awaiting"}
                class="badge badge-sm badge-info badge-soft"
                title="Its turn is blocked on a question or permission card; the lock frees itself when that turn ends. Answer the card to move it along."
              >
                waiting on you
              </span>
              <span
                :if={lock.holder.hold_across_turns}
                class="badge badge-sm badge-ghost"
                title="Kept after its turns end, until released or the hold runs out"
              >
                across turns
              </span>
              <button
                type="button"
                id={"force-release-#{lock_dom_id(lock.name)}"}
                class={[
                  "btn btn-xs ml-auto",
                  if(lock.holder.user_id, do: "btn-primary btn-soft", else: "btn-ghost text-error")
                ]}
                phx-click="force_release"
                phx-value-name={lock.name}
                data-canopy-confirm={
                  !lock.holder.user_id &&
                    "#{holder_label(lock.holder, @user_name)} may still be using it. The next in line is woken."
                }
                data-canopy-confirm-title={!lock.holder.user_id && "Force release `#{lock.name}`?"}
                data-canopy-confirm-label={!lock.holder.user_id && "Force release"}
              >
                {if lock.holder.user_id, do: "Release", else: "Force release"}
              </button>
            <% else %>
              <span class="text-base-content/60">passing to the next in line…</span>
            <% end %>
          </div>
          <ol
            :if={lock.queue != []}
            id={"lock-#{lock_dom_id(lock.name)}-queue"}
            class="ml-6 flex list-decimal flex-col gap-0.5 pl-4 text-xs text-base-content/70"
          >
            <li :for={waiter <- lock.queue}>
              {holder_label(waiter, @user_name)}{lock_where(waiter, @channel)}
              <span :if={waiter.reason} class="text-base-content/50">· “{waiter.reason}”</span>
              <span class="text-base-content/40">
                · waiting {Locks.age(waiter, @now || DateTime.utc_now())}
              </span>
            </li>
          </ol>
        </li>
      </ul>
      <.form
        :if={@taking?}
        for={@form}
        id="take-lock-form"
        phx-submit="take_lock"
        class="flex flex-wrap items-center gap-2"
      >
        <input
          type="text"
          id="take-lock-name"
          name={@form[:name].name}
          value={@form[:name].value}
          class="input input-sm w-28 font-mono"
          aria-label="Lock name"
        />
        <input
          type="text"
          id="take-lock-reason"
          name={@form[:reason].name}
          value={@form[:reason].value}
          placeholder="Why (testing by hand…)"
          class="input input-sm min-w-0 flex-1"
          aria-label="Reason"
        />
        <button type="submit" id="take-lock" class="btn btn-sm">Take lock</button>
        <p class="w-full text-[11px] text-base-content/50">
          Hold one yourself; agents that ask for it wait until you release it.
        </p>
      </.form>
    </div>
    """
  end

  # lock names may carry `:` `/` `.`; DOM ids keep letters, digits and dashes
  defp lock_dom_id(name), do: String.replace(name, ~r/[^a-z0-9-]/, "-")

  defp holder_label(%{user_id: id}, user_name) when is_binary(id), do: user_name
  defp holder_label(claim, _user_name), do: Locks.holder_name(claim)

  # the holder's channel, when it is another one on the repository
  defp lock_where(%{channel: %{id: id, name: name}}, %{id: current}) when id != current,
    do: " in #" <> name

  defp lock_where(_claim, _channel), do: ""

  # `@backend · 6m · next: @fullstack, @frontend`
  defp lock_summary(lock, now) do
    holder =
      case lock.holder do
        nil -> ["passing on"]
        claim -> [Locks.holder_name(claim), Locks.age(claim, now || DateTime.utc_now())]
      end

    next =
      case lock.queue do
        [] -> []
        waiters -> ["next: " <> Enum.map_join(waiters, ", ", &Locks.holder_name/1)]
      end

    Enum.join(holder ++ next, " · ")
  end

  defp lock_title(lock, now) do
    waiting =
      if lock.awaiting_user?, do: ". The holder is waiting on your answer to a card", else: ""

    "Lock `#{lock.name}`: #{lock_summary(lock, now)}#{waiting}. Click for details and Force release."
  end

  defp locks_held(locks, agent_id),
    do: for(%{holder: %{agent_id: ^agent_id}, name: name} <- locks, do: name)

  defp lock_names(names), do: Enum.map_join(names, ", ", &"`#{&1}`")

  defp locks_queued(locks, agent_id) do
    for lock <- locks, Enum.any?(lock.queue, &(&1.agent_id == agent_id)), do: lock.name
  end

  defp task_badge("open"), do: "badge-ghost"
  defp task_badge("working"), do: "badge-info badge-soft"
  defp task_badge("blocked"), do: "badge-warning badge-soft"
  defp task_badge("completed"), do: "badge-success badge-soft"
  defp task_badge(_), do: "badge-ghost"

  attr :addable, :list, required: true
  attr :addable_teams, :list, default: []

  # Under Details › Agents while editing: add an agent, or invite a team.
  defp members_panel(assigns) do
    ~H"""
    <div id="members-panel" class="mt-3 flex flex-col gap-2">
      <form :if={@addable != []} id="add-member-form" phx-submit="add_member" class="flex gap-2">
        <select id="add-member-select" name="agent_id" class="select select-sm min-w-0 flex-1">
          <option value="">Add an agent…</option>
          <option :for={agent <- @addable} value={agent.id}>
            @{agent.name}{if agent.role, do: " · " <> agent.role, else: ""}
          </option>
        </select>
        <button type="submit" id="add-member" class="btn btn-sm btn-primary">Add</button>
      </form>
      <form
        :if={@addable_teams != []}
        id="invite-team-form"
        phx-submit="invite_team"
        class="flex gap-2"
      >
        <select id="invite-team-select" name="team_id" class="select select-sm min-w-0 flex-1">
          <option value="">Invite a team…</option>
          <option :for={team <- @addable_teams} value={team.id}>
            @{team.name} · {team_size(team)}
          </option>
        </select>
        <button type="submit" id="invite-team" class="btn btn-sm btn-primary">Invite</button>
      </form>
      <p :if={@addable_teams != []} class="text-[11px] text-base-content/50">
        A team adds its active members; nobody wakes until mentioned.
      </p>
      <p :if={@addable == []} class="text-xs text-base-content/60">
        Every active agent is already here. Create more on the Agents page.
      </p>
    </div>
    """
  end

  defp team_size(team) do
    case length(Teams.active_members(team)) do
      1 -> "1 member"
      n -> "#{n} members"
    end
  end

  defp reaction_error(:archived), do: "This channel is archived; it takes no reactions."
  defp reaction_error(:system_message), do: "System notes take no reactions."
  defp reaction_error(:unknown_emoji), do: "That reaction is not one Canopy offers."
  defp reaction_error(_reason), do: "Could not react to that message."

  defp limit_reached?(%{spend_limit: limit}, spent) when is_number(limit), do: spent >= limit
  defp limit_reached?(_channel, _spent), do: false

  attr :channel, :map, required: true

  # Details › Automation › Spend: the user's control over what a channel may
  # spend. Agents can set a limit when they create a channel; only this
  # changes one.
  defp budget_panel(assigns) do
    ~H"""
    <div id="budget-panel" class="flex flex-col gap-2">
      <form id="budget-form" phx-submit="set_spend_limit" class="flex items-center gap-2">
        <label class="input input-sm min-w-0 flex-1" for="spend-limit">
          <span class="text-base-content/60">$</span>
          <input
            id="spend-limit"
            name="spend_limit"
            type="number"
            min="0.01"
            step="0.01"
            value={@channel.spend_limit}
            placeholder="No limit"
            class="grow"
          />
        </label>
        <button type="submit" id="save-spend-limit" class="btn btn-sm btn-primary">Set limit</button>
        <button
          :if={@channel.spend_limit}
          type="button"
          id="clear-spend-limit"
          class="btn btn-sm btn-ghost"
          phx-click="clear_spend_limit"
        >
          Remove limit
        </button>
      </form>
      <p class="text-[11px] text-base-content/50">
        The total this channel may spend, all time. Once reached, agents here stay quiet until you
        raise it. Agents can propose a limit when they create a channel; only you change one.
      </p>
    </div>
    """
  end

  attr :channel, :map, required: true
  attr :spent, :float, required: true

  defp limit_bar(assigns) do
    ~H"""
    <div
      id="limit-bar"
      class="flex shrink-0 flex-wrap items-center justify-center gap-3 border-t border-error/40 bg-error/10 px-3 py-2 text-sm"
    >
      <.icon name="hero-banknotes-mini" class="size-4 text-error" />
      <span>
        Spend limit reached: {Costs.money(@spent)} of {Costs.money(@channel.spend_limit)}. Agents stay
        quiet here until you raise it.
      </span>
      <button
        type="button"
        id="raise-limit"
        class="btn btn-xs btn-error"
        phx-click="open_details"
        phx-value-section="spend"
      >
        Change limit
      </button>
    </div>
    """
  end

  attr :stopped?, :boolean, default: false

  defp paused_bar(assigns) do
    ~H"""
    <div
      id="paused-bar"
      class="flex shrink-0 flex-wrap items-center justify-center gap-3 border-t border-warning/40 bg-warning/10 px-3 py-2 text-sm"
    >
      <.icon name="hero-pause-circle-mini" class="size-4 text-warning" />
      <span :if={@stopped?}>
        Stopped. Agents stay quiet until you reply, or
      </span>
      <span :if={!@stopped?}>
        Paused after {Canopy.Runtime.ChannelServer.chatter_limit() || "several"} agent turns without you.
        Reply to keep going, or
      </span>
      <button
        type="button"
        id="continue-chatter"
        class="btn btn-xs btn-warning"
        phx-click="continue_chatter"
      >
        Continue
      </button>
    </div>
    """
  end

  attr :waiting, :list, required: true, doc: "`[{agent_name, card_dom_id}]`"

  # Agents blocked on a card in this channel. Without it, an agent waiting on
  # the user looks the same as one at work.
  defp awaiting_bar(assigns) do
    ~H"""
    <div
      :if={@waiting != []}
      id="awaiting-bar"
      class="flex shrink-0 flex-wrap items-center justify-center gap-x-4 gap-y-1 border-t border-info/40 bg-info/10 px-3 py-2 text-sm"
    >
      <span :for={{name, dom_id} <- @waiting} class="flex items-center gap-2">
        <.icon name="hero-question-mark-circle-mini" class="size-4 text-info" />
        <span>@{name} is waiting on your answer</span>
        <a href={"#" <> dom_id} id={"awaiting-show-#{dom_id}"} class="btn btn-xs btn-info btn-soft">
          Show
        </a>
      </span>
    </div>
    """
  end

  attr :channel, :map, required: true

  defp archived_bar(assigns) do
    ~H"""
    <div
      id="archived-bar"
      class="flex shrink-0 flex-wrap items-center justify-center gap-3 border-t border-base-300 bg-base-200/60 px-3 py-3 text-sm text-base-content/60"
    >
      <.icon name="hero-archive-box-mini" class="size-4" />
      <span>This channel is archived. Nobody can post here.</span>
      <button type="button" class="btn btn-xs btn-outline" phx-click="reopen_channel">
        Reopen
      </button>
    </div>
    """
  end

  attr :form, :map, required: true

  # Details › Task while editing: one column, the panel is narrow.
  defp task_panel(assigns) do
    ~H"""
    <div id="task-panel">
      <.form for={@form} id="task-form" phx-change="validate_task" phx-submit="save_task">
        <div class="grid grid-cols-1">
          <.input field={@form[:title]} type="text" label="Title" />
          <.input
            field={@form[:status]}
            type="select"
            label="Status"
            options={Enum.map(Task.statuses(), &{&1, &1})}
          />
        </div>
        <.input field={@form[:description]} type="textarea" label="Description" rows="3" />
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-sm btn-ghost" phx-click="toggle_task_form">Cancel</button>
          <button type="submit" id="save-task" class="btn btn-sm btn-primary">Save task</button>
        </div>
      </.form>
    </div>
    """
  end

  attr :channel, :map, required: true
  attr :editing?, :boolean, default: false
  attr :form, :any, default: nil
  attr :text, :string, default: ""
  attr :expanded?, :boolean, default: false

  attr :history, :any,
    default: nil,
    doc: "the brief's `brief_updated` events, newest first; nil when closed"

  attr :viewing, :string, default: nil, doc: "the history entry whose text is shown"

  attr :conflict, :any,
    default: nil,
    doc: "a `brief_updated` that arrived while the editor was open"

  attr :agents, :integer, default: 0, doc: "active members, each of which gets the brief"
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :channel_links, :map, default: %{}
  attr :mention_names, :any, default: MapSet.new()

  # The brief under the header: the editor while it is open, otherwise (when
  # a brief is set) the pinned strip, which opens up to the rendered brief.
  defp brief_panel(%{editing?: true, form: %{}} = assigns) do
    chars = assigns.text |> to_string() |> String.trim() |> String.length()

    assigns =
      assigns
      |> assign(:chars, chars)
      |> assign(:max, Channels.Channel.brief_max())
      |> assign(:tokens, div(chars + 3, 4))

    ~H"""
    <section id="brief-editor" class="border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6">
      <div class="mb-2 flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
          Brief
        </span>
        <span class="text-xs text-base-content/60">
          Standing context every agent here gets in its instructions: the goal, constraints,
          links, what not to touch. The task is for what to do now. Mentions in a brief don't
          wake anyone.
        </span>
      </div>

      <div
        :if={@conflict}
        id="brief-conflict"
        role="status"
        class="mb-2 rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-xs"
      >
        <span class="font-medium">
          {brief_author(@conflict.payload["by"], @names, @user_name)} changed the brief while you were editing.
        </span>
        Saving replaces their version; it stays in History.
        <details :if={@conflict.payload["body"]} class="mt-1">
          <summary id="brief-conflict-view" class="cursor-pointer text-base-content/70">View</summary>
          <div class="mt-1 max-h-48 overflow-y-auto text-sm">
            <.message_text
              body={@conflict.payload["body"]}
              channels={@channel_links}
              mentions={@mention_names}
            />
          </div>
        </details>
      </div>

      <.form for={@form} id="brief-form" phx-change="validate_brief" phx-submit="save_brief">
        <.input
          field={@form[:brief]}
          type="textarea"
          rows="7"
          phx-debounce="250"
          placeholder="Goal: …\nConstraints:\n- Don't touch …\nLinks: …"
          class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary"
        />
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2 text-xs">
          <span
            id="brief-chars"
            class={[
              "tabular-nums",
              @chars > @max && "font-medium text-error",
              @chars <= @max && "text-base-content/60"
            ]}
          >
            {format_count(@chars)} / {format_count(@max)} chars
          </span>
          <span id="brief-tokens" class="tabular-nums text-base-content/60">
            ≈ {format_count(@tokens)} tokens × {agents_label(@agents)}
          </span>
          <span
            :if={@chars > div(@max, 2) and @chars <= @max}
            id="brief-long"
            class="text-warning"
          >
            long briefs cost on every prompt
          </span>
          <div class="ml-auto flex items-center gap-2">
            <button
              type="button"
              id="brief-history-toggle"
              class={["btn btn-sm btn-ghost", @history && "btn-active"]}
              phx-click="toggle_brief_history"
            >
              History
            </button>
            <button
              :if={@channel.brief}
              type="button"
              id="clear-brief"
              class="btn btn-sm btn-ghost text-error"
              phx-click="clear_brief"
              data-canopy-confirm="Agents here stop getting it from their next prompt. The text stays in History."
              data-canopy-confirm-title="Clear the brief?"
              data-canopy-confirm-label="Clear"
            >
              Clear
            </button>
            <button
              type="button"
              id="cancel-brief"
              class="btn btn-sm btn-ghost"
              phx-click="toggle_brief_form"
            >
              Cancel
            </button>
            <button type="submit" id="save-brief" class="btn btn-sm btn-primary">Save brief</button>
          </div>
        </div>
        <p class="mt-1 text-[11px] text-base-content/50">
          Saving re-sends each agent's context once without the cache.
        </p>
      </.form>

      <.brief_history
        :if={@history}
        history={@history}
        viewing={@viewing}
        current={@channel.brief}
        names={@names}
        user_name={@user_name}
        channel_links={@channel_links}
        mention_names={@mention_names}
      />
    </section>
    """
  end

  defp brief_panel(%{channel: %{brief: brief}} = assigns) when is_binary(brief) do
    ~H"""
    <section
      id="channel-brief"
      data-expanded={to_string(@expanded?)}
      class="border-b border-base-300 bg-base-200/40 px-3 sm:px-6"
    >
      <div class="flex min-w-0 items-center gap-2 py-1 text-xs">
        <button
          type="button"
          id="brief-toggle"
          class="flex min-w-0 flex-1 items-center gap-1.5 rounded py-0.5 text-left transition hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          phx-click="toggle_brief"
          aria-expanded={to_string(@expanded?)}
          aria-controls="brief-body"
          title={if @expanded?, do: "Collapse the brief", else: "Show the whole brief"}
        >
          <.icon
            name={if @expanded?, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="size-4 shrink-0 text-base-content/50"
          />
          <span class="shrink-0 font-semibold uppercase tracking-wider text-base-content/60">
            Brief
          </span>
          <span :if={!@expanded?} id="brief-summary" class="min-w-0 truncate text-base-content/70">
            {brief_first_line(@channel.brief)}
          </span>
        </button>
        <span
          :if={@expanded?}
          id="brief-meta"
          class="hidden shrink-0 text-base-content/50 @2xl/main:inline"
        >
          {brief_author(@channel.brief_updated_by, @names, @user_name)} · {Canopy.MCP.Format.relative_time(
            @channel.brief_updated_at
          )}
        </span>
        <button
          :if={@expanded?}
          type="button"
          id="brief-history-toggle"
          class={["btn btn-xs btn-ghost", @history && "btn-active"]}
          phx-click="toggle_brief_history"
        >
          History
        </button>
        <button
          type="button"
          id="brief-edit"
          class="btn btn-xs btn-ghost text-base-content/60"
          phx-click="toggle_brief_form"
          title="Edit the brief"
        >
          Edit
        </button>
      </div>
      <div :if={@expanded?} class="pb-2 pl-5">
        <div id="brief-body" class="max-h-64 overflow-y-auto text-sm">
          <.message_text body={@channel.brief} channels={@channel_links} mentions={@mention_names} />
        </div>
        <p id="brief-cost" class="mt-1 text-[11px] text-base-content/50">
          ≈ {format_count(Channels.brief_tokens(@channel.brief))} tokens in every prompt of {agents_label(
            @agents
          )}
        </p>
        <.brief_history
          :if={@history}
          history={@history}
          viewing={@viewing}
          current={@channel.brief}
          names={@names}
          user_name={@user_name}
          channel_links={@channel_links}
          mention_names={@mention_names}
        />
      </div>
    </section>
    """
  end

  defp brief_panel(assigns), do: ~H""

  attr :history, :list, required: true
  attr :viewing, :string, default: nil
  attr :current, :string, default: nil
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :channel_links, :map, default: %{}
  attr :mention_names, :any, default: MapSet.new()

  defp brief_history(assigns) do
    assigns = assign(assigns, :entries, Enum.with_index(assigns.history))

    ~H"""
    <div id="brief-history" class="mt-2 border-t border-base-300/70 pt-2">
      <p class="mb-1 text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
        History
      </p>
      <p :if={@history == []} class="text-xs text-base-content/50">No versions yet.</p>
      <ul class="flex flex-col divide-y divide-base-300/50">
        <li :for={{event, index} <- @entries} id={"brief-history-#{event.id}"} class="py-1.5 text-xs">
          <div class="flex min-w-0 items-center gap-2">
            <span class="shrink-0 font-medium">
              {brief_author(event.payload["by"], @names, @user_name)}
            </span>
            <time
              class="shrink-0 text-base-content/50"
              title={DateTime.to_iso8601(event.inserted_at)}
            >
              {Canopy.MCP.Format.relative_time(event.inserted_at)}
            </time>
            <span class="min-w-0 flex-1 truncate text-base-content/60">
              {if event.payload["body"],
                do: "“" <> brief_first_line(event.payload["body"]) <> "”",
                else: "(cleared)"}
            </span>
            <span
              :if={index == 0 and event.payload["body"] == @current}
              class="badge badge-xs badge-ghost shrink-0"
            >
              current
            </span>
            <button
              :if={event.payload["body"]}
              type="button"
              id={"brief-version-#{event.id}"}
              class={["btn btn-ghost btn-xs", @viewing == event.id && "btn-active"]}
              phx-click="view_brief_version"
              phx-value-id={event.id}
            >
              {if @viewing == event.id, do: "Hide", else: "View"}
            </button>
            <button
              :if={event.payload["body"] && event.payload["body"] != @current}
              type="button"
              id={"brief-restore-#{event.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="restore_brief"
              phx-value-id={event.id}
              title="Make this the brief again (a new version; this one stays in history)"
            >
              Restore
            </button>
          </div>
          <div
            :if={@viewing == event.id}
            id={"brief-version-body-#{event.id}"}
            class="mt-1 max-h-48 overflow-y-auto rounded-lg border border-base-300 bg-base-100/60 px-2 py-1 text-sm"
          >
            <.message_text
              body={event.payload["body"]}
              channels={@channel_links}
              mentions={@mention_names}
            />
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp brief_author("user", _names, user_name), do: user_name
  defp brief_author(nil, _names, user_name), do: user_name
  defp brief_author(agent_id, names, _user_name), do: "@" <> Map.get(names, agent_id, "agent")

  # The first line with words in it, as plain text: without Markdown's
  # leading markers (`#`, `>`, `-`, `1.`), emphasis and code marks, and with
  # links as their text. `@name` and `#channel` stay.
  @doc false
  def brief_first_line(text) do
    text
    |> String.split("\n")
    |> Enum.map(&plain_line/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp plain_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^[-*_]{3,}$/, "")
    |> String.replace(~r/^(?:(?:#+|>|[*+-]|\d+\.)(?:\s+|$))+/, "")
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/(\*\*|__)(?=\S)(.+?)(?<=\S)\1/, "\\2")
    |> String.replace(~r/(?<![\w*])([*_])(?=\S)(.+?)(?<=\S)\1(?![\w*])/, "\\2")
    |> String.replace("`", "")
    |> String.trim()
  end

  defp agents_label(1), do: "1 agent"
  defp agents_label(n), do: "#{n} agents"

  defp format_count(n) when n >= 1000,
    do: "#{div(n, 1000)},#{n |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}"

  defp format_count(n), do: Integer.to_string(n)

  attr :thread, :map, required: true
  attr :stream, :any, required: true
  attr :channel, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :compact?, :boolean, default: true
  attr :channel_links, :map, default: %{}
  attr :mention_names, :any, default: MapSet.new()
  attr :telemetry, :list, default: [], doc: "`[{agent_id, card}]` of turns working here"
  attr :permissions, :list, default: []
  attr :questions, :list, default: []
  attr :drafts, :map, default: %{}, doc: "the question forms' params by request id"
  attr :waiting, :list, default: []
  attr :form, :map, required: true
  attr :agent_names, :list, required: true
  attr :member_names, :list, default: []
  attr :team_names, :list, default: []
  attr :team_members, :map, default: %{}
  attr :channel_names, :list, required: true
  attr :upload, :any, required: true
  attr :picked, :list, default: []
  attr :act, :map, required: true
  attr :activity, :map, default: nil
  attr :receipts, :map, default: %{}
  attr :queued, :map, default: %{}, doc: "message id => `:next_step | :held` (steered, unread)"
  attr :agent_statuses, :map, default: %{}
  attr :steers, :map, default: %{}
  attr :interrupt, :boolean, default: false
  attr :working, :list, default: []

  # A thread in the side panel: the root, its replies and the turn cards of
  # work done for it, the live card and cards of an agent working here, and a
  # composer that stays in the thread.
  defp thread_panel(assigns) do
    ~H"""
    <.side_panel id="thread-panel" label="Thread" close={~p"/channels/#{@channel.id}"}>
      <:title>
        Thread <span class="font-normal text-base-content/60">· {channel_title(@channel)}</span>
      </:title>
      <:actions>
        <button
          type="button"
          id="thread-follow"
          class={["btn btn-ghost btn-xs btn-square", @thread.following? && "text-primary"]}
          phx-click="toggle_follow"
          data-following={to_string(@thread.following?)}
          title={
            if @thread.following?,
              do: "Following: new replies show on the Threads badge. Click to unfollow.",
              else: "Follow: show new replies on the Threads badge"
          }
          aria-label={if @thread.following?, do: "Unfollow the thread", else: "Follow the thread"}
          aria-pressed={to_string(@thread.following?)}
        >
          <.icon
            name={if @thread.following?, do: "hero-bell-alert-mini", else: "hero-bell-mini"}
            class="size-4"
          />
        </button>
        <button
          type="button"
          id="thread-copy-link"
          phx-hook="CopyLink"
          data-href={thread_path(@channel.id, @thread.root.id)}
          class="btn btn-ghost btn-xs btn-square"
          title="Copy link to this thread"
          aria-label="Copy link to this thread"
        >
          <.icon name="hero-link-mini" class="size-4" />
        </button>
      </:actions>

      <div
        id="thread-scroll"
        class="relative min-h-0 flex-1 overflow-y-auto"
        phx-hook="TimelineScroll"
        data-feed="#thread-replies"
        data-scope={@thread.root.id}
      >
        <div
          id="thread-replies"
          phx-update="stream"
          class={["flex flex-col py-2", @compact? && "timeline-compact"]}
        >
          <.timeline_item
            :for={{id, event} <- @stream}
            id={id}
            event={event}
            names={@names}
            user_name={@user_name}
            root={repo_root(@channel)}
            dom_prefix="thread-msg"
            thread={panel_thread(event, @channel, @thread)}
            channels={@channel_links}
            mentions={@mention_names}
            activity={turn_ui(@act, @activity, event)}
            receipt={receipt_of(@receipts, event)}
            queued={queued_mark(@queued, event)}
            reactable={!Channels.archived?(@channel)}
          />
        </div>

        <.telemetry_card
          :for={{agent_id, card} <- @telemetry}
          agent_id={agent_id}
          name={Map.get(@names, agent_id, "agent")}
          card={card}
          root={repo_root(@channel)}
          channel_id={@channel.id}
          status={Map.get(@agent_statuses, agent_id, :busy)}
          open?={MapSet.member?(@act.open_live, agent_id)}
          open_rows={rows_of(@act.open_rows, "telemetry-" <> agent_id)}
          auto_open?={@act.auto_open?}
          steer={Map.get(@steers, agent_id)}
          question={live_question(@questions, agent_id)}
          draft={draft_for(@drafts, live_question(@questions, agent_id))}
        />
        <.permission_card :for={request <- @permissions} request={request} names={@names} />
        <.question_card
          :for={request <- @questions}
          :if={
            !List.keymember?(@telemetry, card_agent_id(request), 0) or
              live_question(@questions, card_agent_id(request)) != request
          }
          request={request}
          names={@names}
          draft={Map.get(@drafts, request.id, %{})}
        />
      </div>

      <:footer>
        <.composer
          :if={!Channels.archived?(@channel)}
          id="thread-composer"
          submit="send_thread"
          scope={@thread.root.id}
          thread
          also_send={channel_title(@channel)}
          waiting={@waiting}
          interrupt={@interrupt}
          working={@working}
          form={@form}
          agent_names={@agent_names}
          member_names={@member_names}
          team_names={@team_names}
          team_members={@team_members}
          channel_names={@channel_names}
          channel_refs={Map.keys(@channel_links)}
          upload={@upload}
          picked={@picked}
          placeholder="Reply in the thread — @mention an agent to wake it"
        />
      </:footer>
    </.side_panel>
    """
  end

  attr :activity, :map,
    required: true,
    doc: "`%{kind: :turn, event}` or `%{kind: :live, agent_id}`"

  attr :channel, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true
  attr :telemetry, :map, required: true
  attr :agent_statuses, :map, required: true
  attr :act, :map, required: true
  attr :mentions, :any, default: MapSet.new()

  # An agent's activity in the side panel: a finished turn, or a running one
  # (it moves to the finished turn when it ends). The same rows as the card,
  # full height, with Copy (the rows as text, for a bug report) and Copy link.
  defp activity_panel(assigns) do
    assigns = assign(assigns, panel_card(assigns))

    ~H"""
    <.side_panel id="activity-panel" label="Activity" close={~p"/channels/#{@channel.id}"}>
      <:title>
        Activity
        <span class="font-normal text-base-content/60">
          · @{Map.get(@names, @agent_id, "agent")}<span :if={@span}> · {@span}</span>
        </span>
      </:title>
      <:actions>
        <button
          type="button"
          id="activity-panel-copy"
          class="btn btn-ghost btn-xs btn-square"
          phx-click={
            JS.dispatch("canopy:copy",
              to: "#activity-panel-text",
              detail: %{button: "activity-panel-copy"}
            )
          }
          title="Copy the activity as text"
          aria-label="Copy the activity as text"
        >
          <.icon name="hero-clipboard-document-list-mini" class="size-4" />
          <span data-copy-label class="sr-only">Copy</span>
        </button>
        <.link
          navigate={transcript_path(@channel.id, @agent_id, @target)}
          id="activity-panel-transcript"
          class="btn btn-ghost btn-xs btn-square"
          title="View in the session transcript"
          aria-label="View in the session transcript"
        >
          <.icon name="hero-document-text-mini" class="size-4" />
        </.link>
        <button
          type="button"
          id="activity-panel-copy-link"
          phx-hook="CopyLink"
          data-href={activity_path(@channel.id, @target)}
          class="btn btn-ghost btn-xs btn-square"
          title="Copy link to this activity"
          aria-label="Copy link to this activity"
        >
          <.icon name="hero-link-mini" class="size-4" />
        </button>
      </:actions>

      <div id="activity-panel-scroll" class="relative min-h-0 flex-1 overflow-y-auto">
        <p
          id="activity-panel-summary"
          class="flex items-center gap-2 border-b border-base-300/70 px-4 py-2 text-xs text-base-content/70"
        >
          <Layouts.status_dot :if={@live?} status={Map.get(@agent_statuses, @agent_id, :busy)} />
          <span class="min-w-0">{@summary}</span>
        </p>
        <.activity_body
          id={"panel-" <> @card_id}
          card_id={@card_id}
          card={@card}
          live?={@live?}
          open_rows={rows_of(@act.open_rows, @card_id)}
          details={@details}
          root={repo_root(@channel)}
          final_text={@final_text}
          mentions={@mentions}
          panel?
        />
        <pre id="activity-panel-text" hidden>{card_text(@card, repo_root(@channel))}</pre>
      </div>
    </.side_panel>
    """
  end

  defp panel_card(%{activity: %{kind: :live, agent_id: agent_id}} = assigns) do
    card = Map.get(assigns.telemetry, agent_id) || Activity.new()
    name = Map.get(assigns.names, agent_id, "agent")

    summary =
      ["@#{name} is #{Activity.verb(card)}…", tally_text(card)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" · ")

    %{
      card: card,
      card_id: "telemetry-" <> agent_id,
      agent_id: agent_id,
      live?: true,
      details: card.details,
      final_text: nil,
      target: "live:" <> agent_id,
      span: if(card.started_at, do: "since " <> clock_ms(card.started_at)),
      summary: summary
    }
  end

  defp panel_card(%{activity: %{kind: :turn, event: event}} = assigns) do
    ended = event.inserted_at

    started =
      case event.payload["duration_ms"] do
        ms when is_integer(ms) -> DateTime.add(ended, -ms, :millisecond)
        _ -> nil
      end

    %{
      card: Activity.card_from_payload(event.payload),
      card_id: "turn-" <> event.id,
      agent_id: event.agent_id,
      live?: false,
      details: Map.get(assigns.act.details, event.id),
      final_text: event.payload["final_text"],
      target: event.id,
      span:
        Enum.join(
          Enum.reject([started && short_time(started), short_time(ended)], &is_nil/1),
          "–"
        ),
      summary: event_text(event, assigns.names, assigns.user_name)
    }
  end

  defp clock_ms(ms), do: ms |> DateTime.from_unix!(:millisecond) |> short_time()

  # A finished turn lands on its place in the transcript; a running one on the newest entries.
  defp transcript_path(channel_id, agent_id, "live:" <> _),
    do: ~p"/channels/#{channel_id}/agents/#{agent_id}/transcript"

  defp transcript_path(channel_id, agent_id, event_id),
    do: ~p"/channels/#{channel_id}/agents/#{agent_id}/transcript?#{[turn: event_id]}"

  # What a timeline item shows of the view's activity state: a finished
  # card's open state, open rows, loaded details, and the panel highlight.
  defp turn_ui(act, activity, %{event_type: "agent_turn_completed", id: id}) do
    card_id = "turn-" <> id

    %{
      open?: MapSet.member?(act.open_turns, id),
      open_rows: rows_of(act.open_rows, card_id),
      details: Map.get(act.details, id),
      highlight: match?(%{kind: :turn, event: %{id: ^id}}, activity)
    }
  end

  defp turn_ui(_act, _activity, _event), do: %{}

  defp receipt_of(receipts, %{event_type: "message", ref_id: message_id}),
    do: Map.get(receipts, message_id)

  defp receipt_of(_receipts, _event), do: nil

  defp rows_of(open_rows, card_id),
    do: for({^card_id, key} <- open_rows, into: MapSet.new(), do: key)

  defp live_in_panel?(%{kind: :live, agent_id: agent_id}, agent_id), do: true
  defp live_in_panel?(_activity, _agent_id), do: false

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the panel is, for assistive technology"
  attr :close, :string, default: nil, doc: "the path Close and Back patch to"

  attr :close_click, :string,
    default: nil,
    doc: "the event Close and Back push instead, for a panel with no URL (Details)"

  slot :title, required: true
  slot :actions
  slot :inner_block, required: true
  slot :footer

  # The right-hand side panel: one slot beside the feed that one panel kind at
  # a time fills (a thread or an activity, which the URL param names, or the
  # channel's details, which this browser remembers). Fixed widths from
  # lg up (28rem, 32rem at 2xl); below lg a full-screen overlay with Back.
  # Esc closes it unless a text box in it has something typed (SidePanel hook).
  defp side_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      phx-hook="SidePanel"
      aria-label={@label}
      class="side-panel fixed inset-0 z-30 flex flex-col bg-base-100 lg:static lg:inset-auto lg:z-auto lg:w-[28rem] lg:shrink-0 lg:border-l lg:border-base-300 2xl:w-[32rem]"
    >
      <header class="flex h-12 shrink-0 items-center gap-1.5 border-b border-base-300 px-3 sm:px-4 lg:h-14">
        <.close_control
          id={"#{@id}-back"}
          close={@close}
          click={@close_click}
          class="btn btn-ghost btn-sm -ml-1 gap-1 px-2 lg:hidden"
          aria-label="Back to the channel"
        >
          <.icon name="hero-chevron-left-mini" class="size-4" /> Back
        </.close_control>
        <h2 class="min-w-0 flex-1 truncate text-sm font-semibold">{render_slot(@title)}</h2>
        {render_slot(@actions)}
        <.close_control
          id={"#{@id}-close"}
          close={@close}
          click={@close_click}
          class="btn btn-ghost btn-xs btn-square max-lg:hidden"
          title="Close (Esc)"
          aria-label="Close the panel"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </.close_control>
      </header>
      {render_slot(@inner_block)}
      {render_slot(@footer)}
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :close, :string, default: nil
  attr :click, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  # A side panel's Back or Close: a patch link, or a button for a panel with no URL.
  defp close_control(%{click: nil} = assigns) do
    ~H"""
    <.link patch={@close} id={@id} {@rest}>{render_slot(@inner_block)}</.link>
    """
  end

  defp close_control(assigns) do
    ~H"""
    <button type="button" id={@id} phx-click={@click} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :id, :string,
    required: true,
    doc: "prefix of every id inside: `composer`, `thread-composer`"

  attr :submit, :string, required: true, doc: "the event a send pushes"
  attr :class, :any, default: nil
  attr :form, :map, required: true
  attr :agent_names, :list, required: true
  attr :member_names, :list, default: []
  attr :team_names, :list, default: []
  attr :team_members, :map, default: %{}, doc: "team name => its active members' names"
  attr :channel_names, :list, required: true
  attr :channel_refs, :list, default: [], doc: "every linkable channel name, archived ones too"
  attr :upload, :any, required: true, doc: "this composer's own upload config"
  attr :picked, :list, required: true
  attr :thread, :boolean, default: false, doc: "a thread's composer: commands are refused"

  attr :scope, :string,
    default: nil,
    doc: "what the draft belongs to (a thread's root); the hook clears the draft when it changes"

  attr :also_send, :string, default: nil, doc: "offer \"Also send to\" this channel"
  attr :placeholder, :string, required: true
  attr :waiting, :list, default: [], doc: "`[{agent_name, card_dom_id}]` blocked on a card"

  attr :interrupt, :boolean,
    default: false,
    doc: "a mention of a working agent reaches it mid-turn (the setting)"

  attr :working, :list, default: [], doc: "names of the agents working now (with `interrupt`)"
  attr :dm, :boolean, default: false, doc: "a DM's composer: `/` offers only the DM commands"

  # The channel's composer and the thread panel's share this one component and
  # the one Composer hook (autocomplete, team names, the highlight layer, the
  # awaiting hint), told apart by their ids.
  defp composer(assigns) do
    assigns =
      assigns
      |> assign(:main?, assigns.id == "composer")
      |> assign(:item, if(assigns.id == "composer", do: "", else: assigns.id <> "-"))
      |> assign(:target, if(assigns.id == "composer", do: "main", else: "thread"))
      |> assign(:slash, slash_commands(assigns))

    ~H"""
    <div class={[
      "shrink-0 border-t border-base-300 bg-base-100 px-3 pb-2 pt-2",
      @main? && "sm:px-6 sm:pb-3",
      !@main? && "sm:px-4",
      @class
    ]}>
      <%!-- Files travel through their own form: uploads need a phx-change, and
           the composer text must never round-trip on every keystroke. --%>
      <form
        id={if @main?, do: "upload-form", else: "#{@id}-upload-form"}
        phx-change="validate_upload"
        phx-submit="validate_upload"
        class="hidden"
      >
        <.live_file_input upload={@upload} />
      </form>
      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-submit={@submit}
        data-agents={Jason.encode!(@agent_names)}
        data-teams={Jason.encode!(@team_names)}
        data-channels={Jason.encode!(@channel_names)}
        data-awaiting={Jason.encode!(Enum.map(@waiting, &elem(&1, 0)))}
        data-working={Jason.encode!(@working)}
        data-interrupt={@interrupt && "true"}
        data-members={Jason.encode!(@member_names)}
        data-team-members={Jason.encode!(@team_members)}
        data-channel-refs={Jason.encode!(@channel_refs)}
        data-commands={Jason.encode!(Commands.names())}
        data-slash={Jason.encode!(@slash)}
        data-thread={@thread && "true"}
        data-scope={@scope}
        class="relative"
      >
        <%!-- Alt+Enter and the send menu send the other way round from the
             setting: "toggle" (see interrupt_opts/1). The hook sets it. --%>
        <input type="hidden" name="interrupt" id={"#{@id}-interrupt"} value="" />
        <%!-- Filled by the Composer hook when the draft mentions an agent that
             is blocked on a card (a message is never taken as the card's
             answer), or one that is working while mentions interrupt. --%>
        <div
          id={"#{@id}-awaiting-hint"}
          phx-update="ignore"
          class="mb-1.5 hidden rounded-lg border border-info/30 bg-info/5 px-2.5 py-1.5 text-xs text-base-content/70"
        >
        </div>
        <div
          id={"#{@id}-suggestions"}
          phx-update="ignore"
          class="absolute bottom-full left-0 z-10 mb-1 hidden w-80 max-w-full overflow-hidden rounded-lg border border-base-300 bg-base-200 shadow-lg"
        >
        </div>
        <div
          id={"#{@id}-box"}
          phx-drop-target={@upload.ref}
          class="rounded-xl border border-base-300 bg-base-200 p-2 shadow-xs transition focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20"
        >
          <div
            :if={@upload.entries != [] or @picked != []}
            id={"#{@id}-files"}
            class="mb-2 flex flex-wrap gap-2"
          >
            <div
              :for={doc <- @picked}
              id={"#{@item}picked-#{doc.id}"}
              class="flex max-w-xs items-center gap-2 rounded-lg border border-primary/40 bg-base-100 px-2 py-1 text-xs"
              title="From the files library"
            >
              <img
                :if={doc.kind == "image"}
                src={Documents.url_path(doc)}
                alt=""
                class="size-8 rounded object-cover"
              />
              <.icon
                :if={doc.kind != "image"}
                name="hero-document-mini"
                class="size-4 shrink-0 text-base-content/60"
              />
              <div class="min-w-0">
                <div class="truncate font-medium" title={doc.filename}>{doc.filename}</div>
                <div class="text-base-content/60">shared · {Documents.size_label(doc.byte_size)}</div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-square"
                phx-click="unpick_document"
                phx-value-id={doc.id}
                phx-value-target={@target}
                title="Remove"
                aria-label={"Remove #{doc.filename}"}
              >
                <.icon name="hero-x-mark-mini" class="size-3.5" />
              </button>
            </div>
            <div
              :for={entry <- @upload.entries}
              id={"#{@item}upload-#{entry.ref}"}
              class="flex max-w-xs items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2 py-1 text-xs"
            >
              <.live_img_preview
                :if={String.starts_with?(entry.client_type || "", "image/")}
                entry={entry}
                class="size-8 rounded object-cover"
              />
              <.icon
                :if={!String.starts_with?(entry.client_type || "", "image/")}
                name="hero-document-mini"
                class="size-4 shrink-0 text-base-content/60"
              />
              <div class="min-w-0">
                <div class="truncate font-medium" title={entry.client_name}>{entry.client_name}</div>
                <div
                  :if={!entry.done? and upload_errors(@upload, entry) == []}
                  class="text-base-content/60"
                >
                  {entry.progress}%
                </div>
                <div :for={err <- upload_errors(@upload, entry)} class="text-error">
                  {upload_error(err)}
                </div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-square"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                phx-value-upload={@upload.name}
                title="Remove"
                aria-label={"Remove #{entry.client_name}"}
              >
                <.icon name="hero-x-mark-mini" class="size-3.5" />
              </button>
            </div>
          </div>
          <div :for={err <- upload_errors(@upload)} class="mb-1 px-1 text-xs text-error">
            {upload_error(err)}
          </div>
          <%!-- The textarea is the browser's: LiveView never patches it, so the
               hook's auto-grown height and the draft survive every update.
               The server clears it with the "composer:clear" event (naming
               this textarea). Behind it, the highlight layer copies the draft
               in transparent text so the mention chips show through (see
               composer_highlight.js). --%>
          <div id={"#{@id}-input-wrap"} phx-update="ignore" class="relative min-w-0">
            <div id={"#{@id}-highlight"} aria-hidden="true" class="composer-text composer-highlight">
            </div>
            <textarea
              id={"#{@id}-input"}
              name={@form[:body].name}
              phx-hook="Composer"
              data-suggestions={"##{@id}-suggestions"}
              data-highlight={"##{@id}-highlight"}
              data-hint={"##{@id}-awaiting-hint"}
              data-upload={@upload.name}
              rows="1"
              placeholder={@placeholder}
              class="composer-text relative max-h-[60vh] w-full resize-none bg-transparent outline-none focus:outline-none"
              autocomplete="off"
            >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          </div>
          <%!-- Toolbar under the text, Slack-style: attach on the left, send on the right. --%>
          <div class="mt-1 flex items-center gap-1">
            <label
              for={@upload.ref}
              id={"#{@id}-attach"}
              class="btn btn-sm btn-ghost btn-square cursor-pointer"
              title="Attach a file from your computer (or paste, or drop one here)"
            >
              <.icon name="hero-folder-open-mini" class="size-4" />
            </label>
            <button
              type="button"
              id={"#{@id}-library"}
              class="btn btn-sm btn-ghost btn-square"
              phx-click="open_library"
              phx-value-target={@target}
              title="Attach a file already shared in Canopy"
            >
              <.icon name="hero-paper-clip-mini" class="size-4" />
            </button>
            <label
              :if={@also_send}
              for="thread-also-send"
              class="ml-1 flex min-w-0 cursor-pointer select-none items-center gap-1.5 text-xs text-base-content/70"
              title="Also show this reply in the channel feed"
            >
              <input
                type="checkbox"
                id="thread-also-send"
                name="also_send"
                value="true"
                data-clear="true"
                class="checkbox checkbox-xs"
              />
              <span class="truncate">Also send to {@also_send}</span>
            </label>
            <%!-- One joined control: Send, and with interrupts on the other
                 way to send (without interrupting a working agent, also
                 Alt+Enter) behind a 1px divider. --%>
            <div id={"#{@id}-send-group"} class="join ml-auto">
              <button
                type="submit"
                id={"#{@id}-send"}
                class="btn btn-sm btn-primary btn-square join-item"
                title="Send (Enter)"
              >
                <.icon name="hero-paper-airplane-mini" class="size-4" />
              </button>
              <div
                :if={@interrupt}
                id={"#{@id}-send-menu"}
                class="dropdown dropdown-top dropdown-end join-item"
              >
                <button
                  type="button"
                  tabindex="0"
                  id={"#{@id}-send-menu-toggle"}
                  class="btn btn-sm btn-primary btn-square join-item w-5 border-0 border-l border-primary-content/20"
                  title="More ways to send"
                  aria-label="More ways to send"
                >
                  <.icon name="hero-chevron-up-mini" class="size-3.5" />
                </button>
                <div
                  tabindex="0"
                  class="dropdown-content z-20 mb-1 w-64 rounded-lg border border-base-300 bg-base-100 p-1 shadow-lg"
                >
                  <button
                    type="submit"
                    name="interrupt"
                    value="toggle"
                    id={"#{@id}-send-no-interrupt"}
                    class="flex w-full flex-col items-start rounded-md px-2.5 py-1.5 text-left text-sm hover:bg-base-200"
                  >
                    <span>Send without interrupting</span>
                    <span class="text-[11px] text-base-content/60">
                      A working agent reads it after its turn · Alt+Enter
                    </span>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
        <p
          :if={@main?}
          id={"#{@id}-hint"}
          class="mt-1.5 hidden truncate px-1 text-[11px] text-base-content/45 sm:block"
        >
          Enter to send · Shift+Enter new line · / for commands
        </p>
        <p :if={!@main?} class="mt-1.5 hidden px-1 text-[11px] text-base-content/45 sm:block">
          Enter to send · Esc closes the thread when the box is empty
        </p>
      </.form>
    </div>
    """
  end

  # What `/` at the start of the draft offers: the command palette's catalog
  # (its names, aliases, and usage), none in a thread, the DM ones in a DM.
  defp slash_commands(%{thread: true}), do: []

  defp slash_commands(assigns) do
    for command <- Commands.catalog(),
        !assigns.dm or command.dm?,
        name <- [command.name | command.aliases],
        do: %{name: name, usage: command.usage, summary: command.summary}
  end

  attr :library, :map, required: true

  defp library_picker(assigns) do
    ~H"""
    <div
      id="library-picker"
      class="fixed inset-0 z-40 flex items-center justify-center bg-base-content/40 p-4"
      phx-window-keydown="close_library"
      phx-key="Escape"
    >
      <div
        id="library-dialog"
        class="flex max-h-[80vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-200 shadow-2xl"
        phx-click-away="close_library"
      >
        <div class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-3">
          <div>
            <h2 class="text-sm font-semibold">Attach a shared file</h2>
            <p class="mt-0.5 text-xs text-base-content/60">
              Files already in Canopy, from any chat. Pick one to add it to your message.
            </p>
          </div>
          <button
            type="button"
            id="close-library"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="close_library"
            aria-label="Close"
          >
            <.icon name="hero-x-mark-mini" class="size-4" />
          </button>
        </div>
        <form
          id="library-search"
          phx-change="search_library"
          phx-submit="search_library"
          class="px-5 py-3"
        >
          <input
            type="search"
            name="q"
            value={@library.q}
            placeholder="Search by name"
            class="input input-sm w-full"
            phx-debounce="200"
            autocomplete="off"
            autofocus
          />
        </form>
        <ul id="library-documents" class="min-h-0 flex-1 divide-y divide-base-300 overflow-y-auto">
          <li
            :if={@library.documents == []}
            class="px-5 py-6 text-center text-sm text-base-content/60"
          >
            Nothing shared yet.
          </li>
          <li :for={doc <- @library.documents}>
            <button
              type="button"
              id={"library-#{doc.id}"}
              class="flex w-full items-center gap-3 px-5 py-2 text-left text-sm hover:bg-base-300/50"
              phx-click="pick_document"
              phx-value-id={doc.id}
            >
              <span class="flex size-9 shrink-0 items-center justify-center overflow-hidden rounded bg-base-100">
                <img
                  :if={doc.kind == "image"}
                  src={Documents.url_path(doc)}
                  alt=""
                  loading="lazy"
                  class="size-9 object-cover"
                />
                <.icon
                  :if={doc.kind != "image"}
                  name="hero-document-text"
                  class="size-5 text-base-content/60"
                />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate font-medium">{doc.filename}</span>
                <span class="block text-xs text-base-content/60">
                  {doc.kind} · {Documents.size_label(doc.byte_size)} · {library_sharer(doc)}
                </span>
              </span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp library_sharer(%{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  defp library_sharer(%{user: %{display_name: name}}) when is_binary(name), do: name
  defp library_sharer(_), do: "unknown"

  defp upload_error(:too_large),
    do: "Too large; the limit is #{Documents.size_label(Documents.max_bytes())}."

  defp upload_error(:too_many_files),
    do: "At most #{Messages.max_attachments()} files per message."

  defp upload_error(:not_accepted), do: "That file type is not accepted."
  defp upload_error(other), do: "Upload failed (#{other})."

  attr :changes, :map, required: true
  attr :repository, :map, required: true

  defp changes_modal(assigns) do
    ~H"""
    <div
      id="changes-modal"
      class="fixed inset-0 z-40 flex items-center justify-center bg-base-content/40 p-6"
      phx-window-keydown="close_changes"
      phx-key="Escape"
    >
      <div
        id="changes-dialog"
        class="flex h-[80vh] w-full max-w-5xl overflow-hidden rounded-2xl border border-base-300 bg-base-200 shadow-2xl"
        phx-click-away="close_changes"
      >
        <aside class="flex w-72 shrink-0 flex-col border-r border-base-300">
          <div class="flex items-center justify-between px-4 py-3">
            <div class="min-w-0">
              <h2 class="text-sm font-semibold">Working tree changes</h2>
              <p class="truncate text-[11px] text-base-content/60" title={@repository.path}>
                {@repository.name}
              </p>
            </div>
            <button
              type="button"
              id="close-changes"
              class="btn btn-xs btn-ghost btn-square"
              phx-click="close_changes"
              aria-label="Close"
            >
              <.icon name="hero-x-mark-mini" class="size-4" />
            </button>
          </div>
          <p :if={@changes.error} class="px-4 pb-3 text-xs text-error">{@changes.error}</p>
          <p
            :if={@changes.files == [] and is_nil(@changes.error)}
            class="px-4 pb-3 text-xs text-base-content/60"
          >
            The working tree is clean.
          </p>
          <ul id="changed-files" class="flex-1 overflow-y-auto pb-2">
            <li :for={file <- @changes.files}>
              <button
                type="button"
                id={"changed-file-#{:erlang.phash2(file.path)}"}
                class={[
                  "flex w-full items-center gap-2 px-4 py-1.5 text-left font-mono text-xs transition hover:bg-base-200",
                  @changes.selected == file.path && "bg-primary/10 text-primary"
                ]}
                phx-click="select_file"
                phx-value-path={file.path}
                title={file.path}
              >
                <span class={["w-5 shrink-0 font-semibold", status_class(file.status)]}>{file.status}</span>
                <span class="truncate">{file.path}</span>
              </button>
            </li>
          </ul>
        </aside>
        <div class="flex min-w-0 flex-1 flex-col">
          <div class="border-b border-base-300 px-4 py-3 font-mono text-xs text-base-content/70">
            {@changes.selected || "Select a file to see its diff"}
          </div>
          <.diff_view
            :if={@changes.diff}
            id="file-diff"
            diff={@changes.diff}
            class="flex-1 py-3"
          />
        </div>
      </div>
    </div>
    """
  end

  defp status_class("??"), do: "text-success"
  defp status_class("A"), do: "text-success"
  defp status_class("D"), do: "text-error"
  defp status_class(_), do: "text-warning"
end
