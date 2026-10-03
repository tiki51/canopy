defmodule CanopyWeb.ChannelLive do
  @moduledoc """
  The main screen: one channel's header, feed, live agent telemetry, permission
  cards, pending handoffs, task form, the repository's locks, and the composer.

  A thread opens in the side panel beside the feed (`?thread=<message id>`,
  with `&reply=<id>` to point at one reply): its own stream, its own composer,
  and the live card and cards of an agent working for it. The feed shows only
  a thread's root and its summary row. The side panel is one slot shared by
  every panel kind; only one is open at a time.

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
    PermissionRequests,
    QuestionRequests,
    Repositories,
    Runtime,
    Schedules,
    Tasks,
    Teams,
    Threads,
    Timeline,
    Unread,
    Users
  }

  alias Canopy.Engine.Event
  alias Canopy.Runtime.{Activity, Commands}
  alias CanopyWeb.Nav
  alias Canopy.Tasks.Task

  @page_size 100
  @thread_page 200
  @archived_answer "This channel is archived. Unarchive (Reopen) the channel to answer."
  @branch_interval 15_000

  # -- Lifecycle ---------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Schedules.subscribe()
      Documents.subscribe()
      Teams.subscribe()
    end

    {:ok,
     socket
     |> assign(:channel, nil)
     |> assign(:compact?, true)
     |> assign(:branch_timer, nil)
     |> assign(:picked, [])
     |> assign(:thread_picked, [])
     |> assign(:library, nil)
     |> assign(:thread, nil)
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

    {:noreply, socket |> attach_from_params(params) |> thread_from_params(params)}
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
        {agent_id, Activity.fold_all(Runtime.telemetry(id, agent_id))}
      end

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
    |> assign(:turn_threads, Runtime.turn_threads(id))
    |> assign(:message_ids, message_ids(events))
    |> assign(:summaries, Messages.thread_summaries(root_ids(events)))
    |> assign(:thread_unread, thread_unread(Map.put(socket.assigns, :user, user)))
    |> assign(:thread, nil)
    |> assign(:thread_picked, [])
    |> stream(:thread, [], reset: true)
    |> assign(:oldest_event_id, events |> List.first() |> then(&(&1 && &1.id)))
    |> assign(:has_earlier?, length(events) >= @page_size)
    |> assign(:pending_handoffs, Handoffs.pending_for_channel(id))
    |> assign(:pending_permissions, PermissionRequests.pending_for_channel(id))
    |> assign(:pending_questions, QuestionRequests.pending_for_channel(id))
    |> assign_cards()
    |> assign(:editing_task?, false)
    |> assign(:editing_members?, false)
    |> assign(:addable_agents, [])
    |> assign(:addable_teams, [])
    |> assign(:editing_budget?, false)
    |> assign(:spent, Costs.channel_total(id))
    |> assign(:editing_schedules?, false)
    |> assign(:schedules, Schedules.list_for_channel(id))
    |> assign(:editing_locks?, false)
    |> assign(:lock_form, to_form(%{"name" => Locks.default_name(), "reason" => ""}, as: :lock))
    |> watch_locks()
    |> assign(:changes, nil)
    |> assign_task(Tasks.for_channel(id))
    |> assign_composer("")
    |> assign_branch()
    |> stream(:timeline, events, reset: true)
    |> schedule_branch_refresh()
  end

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
    {:noreply, socket |> insert_event(event) |> thread_event(event) |> react_to(event)}
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
  # the runtime's own status change ends that.
  def handle_info({:telemetry, agent_id, %Event{} = event}, socket) do
    card = Activity.fold(event, Map.get(socket.assigns.telemetry, agent_id, Activity.new()))

    statuses =
      Map.update(socket.assigns.agent_statuses, agent_id, :busy, fn
        :awaiting_user -> :awaiting_user
        _ -> :busy
      end)

    {:noreply,
     socket
     |> assign(:telemetry, Map.put(socket.assigns.telemetry, agent_id, card))
     |> assign(:agent_statuses, statuses)}
  end

  def handle_info({:agent_status, agent_id, status}, socket) do
    telemetry =
      if status in [:busy, :awaiting_user],
        do: socket.assigns.telemetry,
        else: Map.delete(socket.assigns.telemetry, agent_id)

    {:noreply,
     socket
     |> assign(:agent_statuses, Map.put(socket.assigns.agent_statuses, agent_id, status))
     |> assign(:telemetry, telemetry)}
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

    socket =
      Enum.reduce(message_ids, socket, fn message_id, socket ->
        case Timeline.for_message(message_id) do
          nil ->
            socket

          event ->
            socket =
              if MapSet.member?(socket.assigns.message_ids, message_id),
                do: stream_insert(socket, :timeline, event),
                else: socket

            if loaded_in_panel?(socket, message_id),
              do: stream_insert(socket, :thread, event),
              else: socket
        end
      end)

    {:noreply, socket}
  end

  def handle_info({:schedules, :changed, cid}, socket) do
    if cid == socket.assigns.channel.id,
      do: {:noreply, assign(socket, :schedules, Schedules.list_for_channel(cid))},
      else: {:noreply, socket}
  end

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

  # Only the thread shows what stays in it.
  defp insert_event(socket, %{in_channel: false}), do: socket

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

  defp react_to(socket, %{event_type: "task_updated"}),
    do: assign_task(socket, Tasks.for_channel(cid(socket)))

  defp react_to(socket, %{event_type: "permission_" <> _}), do: refresh_permissions(socket)
  defp react_to(socket, %{event_type: "question_" <> _}), do: refresh_questions(socket)
  defp react_to(socket, _event), do: socket

  defp refresh_channel(socket) do
    channel = Channels.get!(cid(socket))
    assign(socket, :channel, channel)
  end

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
  defp build_answers(request, params) do
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

  defp cid(socket), do: socket.assigns.channel.id

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
             |> push_event("composer:clear", %{id: input})}

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

  defp excerpt(%{body: body}) when is_binary(body) and body != "" do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @excerpt_chars)
  end

  defp excerpt(_message), do: "(no text)"

  # -- Events ------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    submit(socket, body, :main, [])
  end

  # The thread panel's composer: the reply lands in the open thread, and the
  # composer stays there for the next one. "Also send to channel" shows it in
  # the feed too.
  def handle_event("send_thread", %{"message" => %{"body" => body}} = params, socket) do
    case socket.assigns.thread do
      nil ->
        {:noreply, socket}

      %{root: root} ->
        submit(socket, body, :thread,
          thread_id: root.id,
          to_channel: params["also_send"] == "true"
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

  # Esc in the side panel (see the SidePanel hook) closes it.
  def handle_event("close_panel", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/channels/#{cid(socket)}")}

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

  def handle_event("pref", _params, socket), do: {:noreply, socket}

  def handle_event("switch_repository", %{"repository_id" => repository_id}, socket) do
    case Runtime.switch_dm_repository(cid(socket), repository_id, "user") do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> assign_branch()
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

    case request && build_answers(request, params) do
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

  def handle_event("toggle_task_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_task?, not socket.assigns.editing_task?)
     |> assign_task(socket.assigns.task)}
  end

  def handle_event("continue_chatter", _params, socket) do
    :ok = Runtime.continue(cid(socket))
    {:noreply, assign(socket, :paused?, false)}
  end

  def handle_event("toggle_schedules", _params, socket),
    do: {:noreply, assign(socket, :editing_schedules?, not socket.assigns.editing_schedules?)}

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
    do: {:noreply, assign(socket, :editing_locks?, not socket.assigns.editing_locks?)}

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
    socket = assign(socket, :editing_members?, not socket.assigns.editing_members?)
    {:noreply, if(socket.assigns.editing_members?, do: refresh_members(socket), else: socket)}
  end

  def handle_event("toggle_budget", _params, socket),
    do: {:noreply, assign(socket, :editing_budget?, not socket.assigns.editing_budget?)}

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

  def handle_event("open_changes", _params, socket) do
    changes =
      case Repositories.status(socket.assigns.channel.repository) do
        {:ok, lines} ->
          %{files: Enum.map(lines, &status_line/1), selected: nil, diff: nil, error: nil}

        {:error, reason} ->
          %{files: [], selected: nil, diff: nil, error: reason}
      end

    {:noreply, assign(socket, :changes, changes)}
  end

  def handle_event("close_changes", _params, socket),
    do: {:noreply, assign(socket, :changes, nil)}

  def handle_event("select_file", %{"path" => path}, socket) do
    changes = socket.assigns.changes || %{files: [], selected: nil, diff: nil, error: nil}

    diff =
      case Repositories.file_diff(socket.assigns.channel.repository, path) do
        {:ok, ""} -> "(no textual diff)"
        {:ok, patch} -> patch
        {:error, reason} -> "Could not read diff: #{reason}"
      end

    {:noreply, assign(socket, :changes, %{changes | selected: path, diff: diff})}
  end

  def handle_event("load_earlier", _params, socket) do
    older =
      Timeline.list(cid(socket),
        limit: @page_size,
        before: socket.assigns.oldest_event_id,
        scope: :channel
      )

    {:noreply,
     socket
     |> assign(
       :summaries,
       Map.merge(socket.assigns.summaries, Messages.thread_summaries(root_ids(older)))
     )
     |> assign(:message_ids, MapSet.union(socket.assigns.message_ids, message_ids(older)))
     |> assign(
       :oldest_event_id,
       older |> List.first() |> then(&(&1 && &1.id)) || socket.assigns.oldest_event_id
     )
     |> assign(:has_earlier?, length(older) >= @page_size)
     |> stream(:timeline, Enum.reverse(older), at: 0)}
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
      agent_statuses={@agent_statuses}
    >
      <div id="channel-layout" class="flex min-h-0 flex-1 overflow-hidden">
        <%!-- A container, so the header drops its button labels when the side
           panel narrows the column, not only on a narrow window. --%>
        <div id="channel-main" class="@container/main flex min-w-0 flex-1 flex-col overflow-hidden">
          <.channel_header
            channel={@channel}
            task={@task}
            branch={@branch}
            members={@members}
            agent_statuses={@agent_statuses}
            editing_task?={@editing_task?}
            editing_members?={@editing_members?}
            editing_schedules?={@editing_schedules?}
            schedule_count={Enum.count(@schedules, &(&1.status == "active"))}
            compact?={@compact?}
            repositories={@repositories}
            editing_budget?={@editing_budget?}
            spent={@spent}
            locks={@locks}
            editing_locks?={@editing_locks?}
            now={@now}
          />

          <.locks_panel
            :if={@editing_locks?}
            locks={@locks}
            channel={@channel}
            now={@now}
            form={@lock_form}
            user_name={@user.display_name}
          />

          <.budget_panel :if={@editing_budget?} channel={@channel} spent={@spent} />

          <.handoff_banner
            :for={handoff <- @pending_handoffs}
            handoff={handoff}
            names={@names}
            user_name={@user.display_name}
          />

          <.task_panel :if={@editing_task? and @task_form} form={@task_form} />

          <section
            :if={@editing_schedules?}
            id="schedules-panel"
            class="border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6"
          >
            <div class="mb-1 flex items-center gap-2">
              <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                Scheduled
              </span>
              <span class="text-xs text-base-content/60">
                Ask an agent to set a reminder or a repeat.
              </span>
            </div>
            <.schedule_list id="channel-schedules" schedules={@schedules} scope={:channel} />
          </section>

          <.members_panel
            :if={@editing_members?}
            channel={@channel}
            members={@members}
            addable={@addable_agents}
            addable_teams={@addable_teams}
            agent_statuses={@agent_statuses}
          />

          <div
            id="timeline-scroll"
            class="flex-1 overflow-y-auto scroll-smooth"
            phx-hook="TimelineScroll"
            data-feed="#timeline"
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
              />
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
            />

            <.permission_card
              :for={request <- @pending_permissions}
              :if={place(@turn_threads, card_agent_id(request), @thread) != :panel}
              request={request}
              names={@names}
            />
            <.question_card
              :for={request <- @pending_questions}
              :if={place(@turn_threads, card_agent_id(request), @thread) != :panel}
              request={request}
              names={@names}
            />
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
            class={@thread && "max-lg:hidden"}
            submit="send"
            waiting={@waiting_on_user}
            form={@composer}
            agent_names={@agent_names}
            member_names={@member_names}
            team_names={@team_names}
            team_members={@team_members}
            channel_names={@channel_names}
            channel_refs={Map.keys(@channel_links)}
            upload={@uploads.files}
            picked={@picked}
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
          waiting={@waiting_on_user}
          form={@thread_composer}
          agent_names={@agent_names}
          member_names={@member_names}
          team_names={@team_names}
          team_members={@team_members}
          channel_names={@channel_names}
          upload={@uploads.thread_files}
          picked={@thread_picked}
        />
      </div>
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

  attr :channel, :map, required: true
  attr :task, :map, default: nil
  attr :branch, :string, default: nil
  attr :members, :list, required: true
  attr :agent_statuses, :map, required: true
  attr :editing_task?, :boolean, default: false
  attr :editing_members?, :boolean, default: false
  attr :editing_schedules?, :boolean, default: false
  attr :schedule_count, :integer, default: 0
  attr :compact?, :boolean, default: true
  attr :repositories, :list, default: []
  attr :editing_budget?, :boolean, default: false
  attr :spent, :float, default: 0.0
  attr :locks, :list, default: []
  attr :editing_locks?, :boolean, default: false
  attr :now, :any, default: nil

  defp repo_root(%{repository: %{path: path}}), do: path
  defp repo_root(_channel), do: nil

  defp channel_header(assigns) do
    ~H"""
    <header
      id="channel-header"
      class="flex shrink-0 flex-col gap-1.5 border-b border-base-300 px-3 py-2 sm:px-6 sm:py-3"
    >
      <div class="flex min-w-0 items-center gap-2 sm:gap-3">
        <Layouts.menu_button />
        <h1
          id="channel-name"
          class="flex min-w-0 items-baseline gap-1 overflow-hidden whitespace-nowrap text-base font-semibold sm:shrink-0"
        >
          <%= if Channels.dm?(@channel) do %>
            {Channels.dm_label(@channel)}
            <span
              class="ml-1 rounded-full bg-base-300/70 px-1.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60"
              title="A direct message: only this agent is in the channel"
            >
              dm
            </span>
          <% else %>
            <span class="text-base-content/40">#</span>{@channel.name}
          <% end %>
        </h1>
        <p
          :if={@channel.topic && !Channels.dm?(@channel)}
          class="min-w-0 truncate text-sm text-base-content/60"
          id="channel-topic"
        >
          {@channel.topic}
        </p>
        <div class="ml-auto flex shrink-0 items-center gap-1 sm:gap-2">
          <span
            :if={Channels.archived?(@channel)}
            id="archived-badge"
            class="badge badge-sm badge-ghost gap-1"
            title="No one can post here until it is reopened"
          >
            <.icon name="hero-archive-box-mini" class="size-3" /> archived
          </span>
          <button
            :if={!Channels.dm?(@channel)}
            type="button"
            id="edit-members"
            class={["btn btn-xs btn-ghost", @editing_members? && "btn-active"]}
            phx-click="toggle_members"
            title="Add or remove agents"
          >
            <.icon name="hero-users-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Members</span>
          </button>
          <button
            type="button"
            id="toggle-activity"
            class={["btn btn-xs btn-ghost", !@compact? && "btn-active"]}
            phx-click="toggle_activity"
            phx-hook="Pref"
            data-pref="timeline-activity"
            title={
              if @compact?,
                do: "Show routine activity (started, finished, scheduled runs)",
                else: "Hide routine activity"
            }
          >
            <.icon
              name={if @compact?, do: "hero-eye-slash-mini", else: "hero-eye-mini"}
              class="size-4"
            />
            <span class="hidden @4xl/main:inline">Activity</span>
          </button>
          <button
            :for={lock <- @locks}
            type="button"
            id={"lock-chip-#{lock_dom_id(lock.name)}"}
            class={[
              "btn btn-xs btn-ghost max-w-72 gap-1 font-normal",
              @editing_locks? && "btn-active"
            ]}
            phx-click="toggle_locks"
            title={lock_title(lock, @now)}
          >
            <.icon name="hero-lock-closed-mini" class="size-4 shrink-0 text-warning" />
            <span class="font-mono font-medium">{lock.name}</span>
            <span class="hidden min-w-0 truncate text-base-content/70 @4xl/main:inline">
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
            :if={@locks == []}
            type="button"
            id="edit-locks"
            class={["btn btn-xs btn-ghost", @editing_locks? && "btn-active"]}
            phx-click="toggle_locks"
            title="Locks on this repository's shared resources"
          >
            <.icon name="hero-lock-open-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Locks</span>
          </button>
          <button
            type="button"
            id="edit-schedules"
            class={["btn btn-xs btn-ghost", @editing_schedules? && "btn-active"]}
            phx-click="toggle_schedules"
            title="Scheduled tasks in this channel"
          >
            <.icon name="hero-clock-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Scheduled</span>
            <span :if={@schedule_count > 0} id="schedule-count" class="badge badge-xs badge-primary">
              {@schedule_count}
            </span>
          </button>
          <button
            type="button"
            id="edit-budget"
            class={[
              "btn btn-xs btn-ghost",
              @editing_budget? && "btn-active",
              limit_reached?(@channel, @spent) && "text-error"
            ]}
            phx-click="toggle_budget"
            title="What this channel has spent, and its limit"
          >
            <.icon name="hero-banknotes-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">
              {Costs.money(@spent)}{if @channel.spend_limit,
                do: " / " <> Costs.money(@channel.spend_limit),
                else: ""}
            </span>
          </button>
          <button
            type="button"
            id="edit-task"
            class={["btn btn-xs btn-ghost", @editing_task? && "btn-active"]}
            phx-click="toggle_task_form"
          >
            <.icon name="hero-clipboard-document-list-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Task</span>
          </button>
          <button
            type="button"
            id="open-changes"
            class="btn btn-xs btn-ghost"
            phx-click="open_changes"
          >
            <.icon name="hero-document-plus-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Changes</span>
          </button>
          <button
            :if={!Channels.archived?(@channel)}
            type="button"
            id="stop-all"
            class="btn btn-xs btn-ghost text-error"
            phx-click="stop_all"
            title="Stop all: abort every running turn, drop queued wakes, and hold the channel until you reply"
          >
            <.icon name="hero-stop-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Stop</span>
          </button>
          <button
            :if={!Channels.archived?(@channel)}
            type="button"
            id="archive-channel"
            class="btn btn-xs btn-ghost text-base-content/60"
            phx-click="archive_channel"
            data-canopy-confirm={"Nobody can post in ##{@channel.name} until it is reopened."}
            data-canopy-confirm-title={"Archive ##{@channel.name}?"}
            data-canopy-confirm-label="Archive"
            title="Archive this channel"
          >
            <.icon name="hero-archive-box-arrow-down-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Archive</span>
          </button>
          <button
            :if={Channels.archived?(@channel)}
            type="button"
            id="reopen-channel"
            class="btn btn-xs btn-ghost"
            phx-click="reopen_channel"
            title="Reopen this channel"
          >
            <.icon name="hero-archive-box-x-mark-mini" class="size-4" />
            <span class="hidden @4xl/main:inline">Reopen</span>
          </button>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
        <span class="flex items-center gap-1.5" title="Task owner">
          <.icon name="hero-user-circle-mini" class="size-4 text-base-content/40" />
          <span
            id="owner-badge"
            class={[
              "badge badge-sm",
              @channel.owner && "badge-primary badge-soft",
              is_nil(@channel.owner) && "badge-ghost"
            ]}
          >
            {if @channel.owner, do: "@" <> @channel.owner.name, else: "no owner"}
          </span>
        </span>

        <span :if={@task} class="flex min-w-0 items-center gap-1.5" title={@task.description}>
          <span id="task-status" class={["badge badge-sm", task_badge(@task.status)]}>
            {@task.status}
          </span>
          <span id="task-title" class="truncate text-base-content/70">{@task.title}</span>
        </span>

        <form
          :if={Channels.dm?(@channel)}
          id="dm-repository-form"
          phx-change="switch_repository"
          class="flex items-center gap-1.5"
          title="The repository this DM's agents work in; switch it to move the conversation"
        >
          <.icon name="hero-folder-mini" class="size-4 text-base-content/40" />
          <select
            id="dm-repository"
            name="repository_id"
            class="select select-xs h-6 min-h-0 w-auto max-w-48 border-base-300 bg-base-200 text-xs"
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

        <span class="flex items-center gap-1 font-mono text-base-content/60" title="Current branch">
          <.icon name="hero-code-bracket-mini" class="size-4 text-base-content/40" />
          <span id="branch">{@branch || "—"}</span>
        </span>

        <ul id="members" class="ml-auto flex items-center gap-2">
          <li
            :for={member <- @members}
            id={"member-#{member.id}"}
            class="flex items-center gap-1.5 rounded-full border border-base-300 py-0.5 pl-2 pr-1"
            title={member.role}
          >
            <Layouts.status_dot status={Map.get(@agent_statuses, member.id, :idle)} />
            <span>@{member.name}</span>
            <span
              :if={locks_held(@locks, member.id) != []}
              id={"member-#{member.id}-lock"}
              class="flex items-center text-warning"
              title={"Holds " <> lock_names(locks_held(@locks, member.id))}
            >
              <.icon name="hero-lock-closed-micro" class="size-3.5" />
            </span>
            <span
              :if={locks_queued(@locks, member.id) != []}
              id={"member-#{member.id}-lock-queued"}
              class="flex items-center text-base-content/50"
              title={"Waiting for " <> lock_names(locks_queued(@locks, member.id))}
            >
              <.icon name="hero-clock-micro" class="size-3.5" />
            </span>
            <span
              :if={Map.get(@agent_statuses, member.id) == :awaiting_user}
              id={"member-#{member.id}-awaiting"}
              class="text-xs text-info"
            >
              waiting on you
            </span>
            <button
              :if={Map.get(@agent_statuses, member.id) in [:busy, :awaiting_user]}
              type="button"
              id={"abort-#{member.id}"}
              class="btn btn-xs btn-ghost h-5 min-h-0 px-1 text-error"
              phx-click="abort"
              phx-value-agent-id={member.id}
              title="Abort the current turn"
            >
              <.icon name="hero-stop-circle-mini" class="size-4" />
            </button>
            <button
              :if={Map.get(@agent_statuses, member.id) not in [:busy, :awaiting_user]}
              type="button"
              id={"reset-session-#{member.id}"}
              class="btn btn-xs btn-ghost h-5 min-h-0 px-1 text-base-content/40 hover:text-base-content"
              phx-click="reset_session"
              phx-value-agent-id={member.id}
              data-canopy-confirm={"Reset @#{member.name}'s session in this channel? Its next turn starts with a fresh OpenCode session; channel messages are kept."}
              title="Reset session (fresh context on the next turn)"
            >
              <.icon name="hero-arrow-path-mini" class="size-3.5" />
            </button>
          </li>
        </ul>
      </div>
    </header>
    """
  end

  attr :locks, :list, required: true
  attr :channel, :map, required: true
  attr :now, :any, required: true
  attr :form, :any, required: true
  attr :user_name, :string, required: true

  # Every lock on the repository: holder, how long, why, the line behind it,
  # and Force release. A holder whose turn is blocked on a card is marked:
  # its lock frees itself only when that turn ends, so the card is the way on.
  defp locks_panel(assigns) do
    ~H"""
    <section
      id="locks-panel"
      class="flex flex-col gap-3 border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
          Locks
        </span>
        <span class="text-xs text-base-content/60">
          Shared by every channel on {@channel.repository.name}. Agents take them before running
          tests or anything that writes shared output; each frees itself when its holder's turn ends.
        </span>
      </div>
      <p :if={@locks == []} id="locks-empty" class="text-sm text-base-content/60">
        No locks are held.
      </p>
      <ul :if={@locks != []} id="locks-list" class="flex flex-col gap-2">
        <li
          :for={lock <- @locks}
          id={"lock-#{lock_dom_id(lock.name)}"}
          class="flex flex-col gap-1.5 rounded-box border border-base-300 bg-base-100 px-3 py-2"
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
          class="input input-sm w-36 font-mono"
          aria-label="Lock name"
        />
        <input
          type="text"
          id="take-lock-reason"
          name={@form[:reason].name}
          value={@form[:reason].value}
          placeholder="Why (testing by hand…)"
          class="input input-sm w-56 min-w-0"
          aria-label="Reason"
        />
        <button type="submit" id="take-lock" class="btn btn-sm">Take lock</button>
        <span class="text-xs text-base-content/60">
          Hold one yourself; agents that ask for it wait until you release it.
        </span>
      </.form>
    </section>
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

  attr :channel, :map, required: true
  attr :members, :list, required: true
  attr :addable, :list, required: true
  attr :addable_teams, :list, default: []
  attr :agent_statuses, :map, required: true

  defp members_panel(assigns) do
    ~H"""
    <section
      id="members-panel"
      class="flex flex-col gap-3 border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
          Members
        </span>
        <span
          :for={member <- @members}
          id={"member-row-#{member.id}"}
          class="flex items-center gap-1.5 rounded-full border border-base-300 bg-base-200 py-0.5 pl-2 pr-1 text-xs"
          title={member.role}
        >
          <Layouts.status_dot status={Map.get(@agent_statuses, member.id, :idle)} />
          <span>@{member.name}</span>
          <span
            :if={member.id == @channel.owner_agent_id}
            class="rounded-full bg-primary/10 px-1.5 text-[10px] font-medium uppercase tracking-wide text-primary"
            title="The owner cannot be removed; hand the task off first"
          >
            owner
          </span>
          <button
            :if={member.id != @channel.owner_agent_id}
            type="button"
            id={"remove-member-#{member.id}"}
            class="btn btn-xs btn-ghost h-5 min-h-0 px-1 text-base-content/50 hover:text-error"
            phx-click="remove_member"
            phx-value-agent-id={member.id}
            title={"Remove @#{member.name} from this channel"}
          >
            <.icon name="hero-x-mark-mini" class="size-3.5" />
          </button>
          <span :if={member.id == @channel.owner_agent_id} class="w-1" />
        </span>
      </div>
      <form
        :if={@addable != []}
        id="add-member-form"
        phx-submit="add_member"
        class="flex flex-wrap items-center gap-2"
      >
        <select id="add-member-select" name="agent_id" class="select select-sm w-56 min-w-0">
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
        class="flex flex-wrap items-center gap-2"
      >
        <select id="invite-team-select" name="team_id" class="select select-sm w-56 min-w-0">
          <option value="">Invite a team…</option>
          <option :for={team <- @addable_teams} value={team.id}>
            @{team.name} · {team_size(team)}
          </option>
        </select>
        <button type="submit" id="invite-team" class="btn btn-sm btn-primary">Invite</button>
        <span class="text-xs text-base-content/60">
          Adds its active members; nobody wakes until mentioned.
        </span>
      </form>
      <p :if={@addable == []} class="text-xs text-base-content/60">
        Every active agent is already here. Create more on the Agents page.
      </p>
    </section>
    """
  end

  defp team_size(team) do
    case length(Teams.active_members(team)) do
      1 -> "1 member"
      n -> "#{n} members"
    end
  end

  defp limit_reached?(%{spend_limit: limit}, spent) when is_number(limit), do: spent >= limit
  defp limit_reached?(_channel, _spent), do: false

  attr :channel, :map, required: true
  attr :spent, :float, required: true

  # The user's control over what a channel may spend. Agents can set a limit
  # when they create a channel; only this panel changes one.
  defp budget_panel(assigns) do
    ~H"""
    <section
      id="budget-panel"
      class="flex flex-col gap-2 border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
          Budget
        </span>
        <span id="budget-spent" class="text-sm tabular-nums">
          Spent {Costs.money(@spent)}{if @channel.spend_limit,
            do: " of a " <> Costs.money(@channel.spend_limit) <> " limit",
            else: ", no limit"}
        </span>
      </div>
      <form id="budget-form" phx-submit="set_spend_limit" class="flex flex-wrap items-center gap-2">
        <label class="input input-sm w-44" for="spend-limit">
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
      <p class="text-xs text-base-content/60">
        The total this channel may spend, all time. Once reached, agents here stay quiet until you
        raise it. Agents can propose a limit when they create a channel; only you change one.
      </p>
    </section>
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
      <button type="button" id="raise-limit" class="btn btn-xs btn-error" phx-click="toggle_budget">
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

  defp task_panel(assigns) do
    ~H"""
    <section id="task-panel" class="border-b border-base-300 bg-base-200/60 px-3 sm:px-6 py-3">
      <.form for={@form} id="task-form" phx-change="validate_task" phx-submit="save_task">
        <div class="grid grid-cols-1 gap-x-4 md:grid-cols-[1fr_12rem]">
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
    </section>
    """
  end

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
  attr :waiting, :list, default: []
  attr :form, :map, required: true
  attr :agent_names, :list, required: true
  attr :member_names, :list, default: []
  attr :team_names, :list, default: []
  attr :team_members, :map, default: %{}
  attr :channel_names, :list, required: true
  attr :upload, :any, required: true
  attr :picked, :list, default: []

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
        class="min-h-0 flex-1 overflow-y-auto"
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
          />
        </div>

        <.telemetry_card
          :for={{agent_id, card} <- @telemetry}
          agent_id={agent_id}
          name={Map.get(@names, agent_id, "agent")}
          card={card}
          root={repo_root(@channel)}
        />
        <.permission_card :for={request <- @permissions} request={request} names={@names} />
        <.question_card :for={request <- @questions} request={request} names={@names} />
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

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the panel is, for assistive technology"
  attr :close, :string, required: true, doc: "the path Close and Back patch to"
  slot :title, required: true
  slot :actions
  slot :inner_block, required: true
  slot :footer

  # The right-hand side panel: one slot beside the feed that one panel kind at
  # a time fills (a thread now; the URL param says which). Fixed widths from
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
      <header class="flex shrink-0 items-center gap-1.5 border-b border-base-300 px-3 py-2 sm:px-4 lg:py-3">
        <.link
          patch={@close}
          id={"#{@id}-back"}
          class="btn btn-ghost btn-sm -ml-1 gap-1 px-2 lg:hidden"
          aria-label="Back to the channel"
        >
          <.icon name="hero-chevron-left-mini" class="size-4" /> Back
        </.link>
        <h2 class="min-w-0 flex-1 truncate text-sm font-semibold">{render_slot(@title)}</h2>
        {render_slot(@actions)}
        <.link
          patch={@close}
          id={"#{@id}-close"}
          class="btn btn-ghost btn-xs btn-square max-lg:hidden"
          title="Close (Esc)"
          aria-label="Close the panel"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </.link>
      </header>
      {render_slot(@inner_block)}
      {render_slot(@footer)}
    </aside>
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

  # The channel's composer and the thread panel's share this one component and
  # the one Composer hook (autocomplete, team names, the highlight layer, the
  # awaiting hint), told apart by their ids.
  defp composer(assigns) do
    assigns =
      assigns
      |> assign(:main?, assigns.id == "composer")
      |> assign(:item, if(assigns.id == "composer", do: "", else: assigns.id <> "-"))
      |> assign(:target, if(assigns.id == "composer", do: "main", else: "thread"))

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
        data-members={Jason.encode!(@member_names)}
        data-team-members={Jason.encode!(@team_members)}
        data-channel-refs={Jason.encode!(@channel_refs)}
        data-commands={Jason.encode!(Commands.names())}
        data-thread={@thread && "true"}
        data-scope={@scope}
        class="relative"
      >
        <%!-- Filled by the Composer hook when the draft mentions an agent that
             is blocked on a card: a message is never taken as the card's answer. --%>
        <div
          id={"#{@id}-awaiting-hint"}
          phx-update="ignore"
          class="mb-1.5 hidden rounded-lg border border-info/30 bg-info/5 px-2.5 py-1.5 text-xs text-base-content/70"
        >
        </div>
        <div
          id={"#{@id}-suggestions"}
          phx-update="ignore"
          class="absolute bottom-full left-0 z-10 mb-1 hidden w-64 overflow-hidden rounded-lg border border-base-300 bg-base-200 shadow-lg"
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
            <button
              type="submit"
              id={"#{@id}-send"}
              class="btn btn-sm btn-primary btn-square ml-auto"
              title="Send (Enter)"
            >
              <.icon name="hero-paper-airplane-mini" class="size-4" />
            </button>
          </div>
        </div>
        <p :if={@main?} class="mt-1.5 hidden px-1 text-[11px] text-base-content/45 sm:block">
          Enter to send · Shift+Enter for a new line · paste or drop files to attach · {Commands.help()}
        </p>
        <p :if={!@main?} class="mt-1.5 hidden px-1 text-[11px] text-base-content/45 sm:block">
          Enter to send · Esc closes the thread when the box is empty
        </p>
      </.form>
    </div>
    """
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
