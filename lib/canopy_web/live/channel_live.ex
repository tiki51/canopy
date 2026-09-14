defmodule CanopyWeb.ChannelLive do
  @moduledoc """
  The main screen: one channel's header, feed, live agent telemetry, permission
  cards, pending handoffs, task form, and the composer.

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
    PermissionRequests,
    QuestionRequests,
    Repositories,
    Runtime,
    Schedules,
    Tasks,
    Timeline,
    Unread,
    Users
  }

  alias Canopy.OpenCode.Event
  alias Canopy.Runtime.{Activity, Commands}
  alias CanopyWeb.Nav
  alias Canopy.Tasks.Task

  @page_size 100
  @branch_interval 15_000

  # -- Lifecycle ---------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Schedules.subscribe()
      Documents.subscribe()
    end

    {:ok,
     socket
     |> assign(:channel, nil)
     |> assign(:compact?, true)
     |> assign(:branch_timer, nil)
     |> assign(:picked, [])
     |> assign(:replying_to, nil)
     |> assign(:open_threads, MapSet.new())
     |> assign(:library, nil)
     |> allow_upload(:files,
       accept: :any,
       max_entries: Messages.max_attachments(),
       max_file_size: Documents.max_bytes(),
       auto_upload: true
     )
     |> stream_configure(:timeline, dom_id: &"evt-#{&1.id}")
     |> stream(:timeline, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    socket =
      case socket.assigns.channel do
        %{id: ^id} -> socket
        _ -> load_channel(socket, id)
      end

    {:noreply, attach_from_params(socket, params)}
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

  defp pick(socket, document) do
    picked = socket.assigns.picked

    if Enum.any?(picked, &(&1.id == document.id)),
      do: socket,
      else: assign(socket, :picked, picked ++ [document])
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
    events = Timeline.list(id, limit: @page_size)
    {items, threads, message_ids} = split_threads(events)
    statuses = Runtime.status(id)

    agent_statuses =
      Map.new(members, fn member -> {member.id, Map.get(statuses, member.id, :idle)} end)

    telemetry =
      for {agent_id, :busy} <- agent_statuses, into: %{} do
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
    |> assign(:telemetry, telemetry)
    |> assign(:threads, threads)
    |> assign(:message_ids, message_ids)
    |> assign(:oldest_event_id, events |> List.first() |> then(&(&1 && &1.id)))
    |> assign(:has_earlier?, length(events) >= @page_size)
    |> assign(:pending_handoffs, Handoffs.pending_for_channel(id))
    |> assign(:pending_permissions, PermissionRequests.pending_for_channel(id))
    |> assign(:pending_questions, QuestionRequests.pending_for_channel(id))
    |> assign(:editing_task?, false)
    |> assign(:editing_members?, false)
    |> assign(:addable_agents, [])
    |> assign(:editing_budget?, false)
    |> assign(:spent, Costs.channel_total(id))
    |> assign(:editing_schedules?, false)
    |> assign(:schedules, Schedules.list_for_channel(id))
    |> assign(:changes, nil)
    |> assign_task(Tasks.for_channel(id))
    |> assign_composer("")
    |> assign_branch()
    |> stream(:timeline, items, reset: true)
    |> schedule_branch_refresh()
  end

  defp leave_channel(%{assigns: %{channel: nil}} = socket), do: socket

  defp leave_channel(%{assigns: %{channel: channel, branch_timer: timer}} = socket) do
    if connected?(socket), do: Timeline.unsubscribe(channel.id)
    if timer, do: Process.cancel_timer(timer)
    assign(socket, :branch_timer, nil)
  end

  # Thread replies are nested under their root instead of listed inline. Replies
  # whose root is outside the loaded window stay inline, marked "in a thread".
  defp split_threads(events) do
    {items, threads, ids} =
      Enum.reduce(events, {[], %{}, MapSet.new()}, fn event, {items, threads, ids} ->
        case event do
          %{event_type: "message", message: %{thread_id: root} = message} when is_binary(root) ->
            if MapSet.member?(ids, root) do
              {items, Map.update(threads, root, [message], &(&1 ++ [message])), ids}
            else
              {[event | items], threads, ids}
            end

          %{event_type: "message", message: %{id: message_id}} ->
            {[event | items], threads, MapSet.put(ids, message_id)}

          _ ->
            {[event | items], threads, ids}
        end
      end)

    {Enum.reverse(items), threads, ids}
  end

  defp assign_task(socket, task) do
    form = if task, do: to_form(Tasks.change(task), id: "task-form"), else: nil
    socket |> assign(:task, task) |> assign(:task_form, form)
  end

  defp assign_composer(socket, body) do
    assign(socket, :composer, to_form(%{"body" => body}, as: :message, id: "composer-form"))
  end

  defp load_library(socket, q) do
    picked = Enum.map(socket.assigns.picked, & &1.id)
    documents = Documents.list(search: q, limit: 30) |> Enum.reject(&(&1.id in picked))
    assign(socket, :library, %{q: q, documents: documents})
  end

  # A deleted document on a thread reply: swap the reply in the threads map.
  defp refresh_thread_reply(socket, message_id) do
    case Messages.get(message_id) do
      %{thread_id: root} = reply when is_binary(root) ->
        threads =
          Map.update(socket.assigns.threads, root, [reply], fn replies ->
            Enum.map(replies, &if(&1.id == reply.id, do: reply, else: &1))
          end)

        assign(socket, :threads, threads)

      _ ->
        socket
    end
  end

  # A mention of an agent that is not in the channel wakes nobody; say so and
  # point at /i, instead of leaving the user waiting.
  defp outsider_hint(socket, %Messages.Message{mentions: ids}) when ids != [] do
    members = MapSet.new(socket.assigns.members, & &1.id)

    outsiders =
      ids
      |> Enum.reject(&MapSet.member?(members, &1))
      |> Enum.map(&Map.get(socket.assigns.names, &1))
      |> Enum.reject(&is_nil/1)

    case outsiders do
      [] ->
        socket

      names ->
        mentions = Enum.map_join(names, ", ", &("@" <> &1))
        invites = Enum.map_join(names, " ", &("/i @" <> &1))

        put_flash(
          socket,
          :info,
          "#{mentions} #{if length(names) == 1, do: "is", else: "are"} not in this channel, so that mention woke nobody. Invite with #{invites}."
        )
    end
  end

  defp outsider_hint(socket, _result), do: socket

  # Turns every finished upload into a document and returns the ids, in the
  # order the files were added. Entries that fail to store are skipped and
  # reported as a flash by the caller.
  defp store_uploads(socket) do
    consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
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
    {:noreply, socket |> insert_event(event) |> react_to(event)}
  end

  def handle_info({:telemetry, agent_id, %Event{} = event}, socket) do
    card = Activity.fold(event, Map.get(socket.assigns.telemetry, agent_id, Activity.new()))

    {:noreply,
     socket
     |> assign(:telemetry, Map.put(socket.assigns.telemetry, agent_id, card))
     |> assign(:agent_statuses, Map.put(socket.assigns.agent_statuses, agent_id, :busy))}
  end

  def handle_info({:agent_status, agent_id, status}, socket) do
    telemetry =
      if status == :busy,
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
      |> then(fn socket ->
        if socket.assigns.library,
          do: load_library(socket, socket.assigns.library.q),
          else: socket
      end)

    socket =
      Enum.reduce(message_ids, socket, fn message_id, socket ->
        if MapSet.member?(socket.assigns.message_ids, message_id) do
          case Timeline.for_message(message_id) do
            nil -> socket
            event -> stream_insert(socket, :timeline, event)
          end
        else
          refresh_thread_reply(socket, message_id)
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
    do: {:noreply, assign(socket, :paused?, status == :paused)}

  def handle_info(:refresh_branch, socket) do
    {:noreply, socket |> assign_branch() |> schedule_branch_refresh()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp insert_event(
         socket,
         %{event_type: "message", message: %{thread_id: root} = message} = event
       )
       when is_binary(root) do
    if MapSet.member?(socket.assigns.message_ids, root) do
      threads = Map.update(socket.assigns.threads, root, [message], &(&1 ++ [message]))
      socket = assign(socket, :threads, threads)

      case Timeline.for_message(root) do
        nil -> stream_insert(socket, :timeline, event)
        parent -> stream_insert(socket, :timeline, parent)
      end
    else
      stream_insert(socket, :timeline, event)
    end
  end

  defp insert_event(socket, %{event_type: "message", message: %{id: message_id}} = event) do
    socket
    |> assign(:message_ids, MapSet.put(socket.assigns.message_ids, message_id))
    |> stream_insert(:timeline, event)
  end

  defp insert_event(socket, event), do: stream_insert(socket, :timeline, event)

  defp react_to(socket, %{event_type: type}) when type in ~w(owner_changed handoff_accepted) do
    socket
    |> refresh_channel()
    |> refresh_handoffs()
    |> assign_task(Tasks.for_channel(cid(socket)))
  end

  defp react_to(socket, %{event_type: type}) when type in ~w(handoff_requested handoff_rejected),
    do: refresh_handoffs(socket)

  defp react_to(socket, %{event_type: type}) when type in ~w(member_added member_removed),
    do: refresh_members(socket)

  defp react_to(socket, %{event_type: type}) when type in ~w(channel_archived channel_reopened),
    do: socket |> refresh_channel() |> Nav.refresh_nav()

  defp react_to(socket, %{event_type: "repository_switched"}),
    do: socket |> refresh_channel() |> assign_branch() |> Nav.refresh_nav()

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
  end

  # What the composer suggests after `@` and `#`, and the map that turns
  # `#name` in bodies into links. In a channel every active agent is offered
  # (mentioning a non-member only hints at /i); a DM keeps its own set.
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

    socket
    |> assign(:agent_names, agent_names)
    |> assign(:channel_names, channel_names)
    |> assign(:channel_links, links)
  end

  defp refresh_handoffs(socket),
    do: assign(socket, :pending_handoffs, Handoffs.pending_for_channel(cid(socket)))

  defp refresh_permissions(socket),
    do: assign(socket, :pending_permissions, PermissionRequests.pending_for_channel(cid(socket)))

  defp refresh_questions(socket),
    do: assign(socket, :pending_questions, QuestionRequests.pending_for_channel(cid(socket)))

  defp drop_question(socket, id),
    do:
      assign(
        socket,
        :pending_questions,
        Enum.reject(socket.assigns.pending_questions, &(&1.id == id))
      )

  # One list of chosen labels per question, in the order OpenCode asked them.
  # A free-text answer rides along with whatever was ticked; every question
  # needs something, since OpenCode expects an answer for each.
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

  # Stream items are rendered once, when they are inserted: an assign the item
  # depends on does not re-render it. Re-insert the thread's root so it picks up
  # the new disclosure state.
  defp refresh_thread_root(socket, root_id) do
    case Timeline.for_message(root_id) do
      nil -> socket
      event -> stream_insert(socket, :timeline, event)
    end
  end

  defp thread_opt(%{assigns: %{replying_to: %{id: id}}}), do: [thread_id: id]
  defp thread_opt(_socket), do: []

  defp sender_label(%{agent_id: id}, socket) when is_binary(id),
    do: "@" <> Map.get(socket.assigns.names, id, "agent")

  defp sender_label(_message, socket), do: socket.assigns.user.display_name

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
  # Threads are rooted at a top-level message: replying to a reply joins the
  # thread it is already in rather than nesting a second level.
  def handle_event("reply_in_thread", %{"id" => id}, socket) do
    case Messages.get(id) do
      nil ->
        {:noreply, socket}

      message ->
        root_id = message.thread_id || message.id

        target = %{
          id: root_id,
          sender: sender_label(message, socket),
          excerpt: excerpt(message),
          replies: length(Map.get(socket.assigns.threads, root_id, []))
        }

        {:noreply,
         socket
         |> assign(:replying_to, target)
         |> assign(:open_threads, MapSet.put(socket.assigns.open_threads, root_id))
         |> refresh_thread_root(root_id)
         |> push_event("composer:focus", %{})}
    end
  end

  def handle_event("cancel_reply", _params, socket),
    do: {:noreply, assign(socket, :replying_to, nil)}

  def handle_event("toggle_thread", %{"id" => id}, socket) do
    open = socket.assigns.open_threads
    open = if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)

    {:noreply, socket |> assign(:open_threads, open) |> refresh_thread_root(id)}
  end

  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    text = String.trim(body)
    entries = socket.assigns.uploads.files.entries

    picked = Enum.map(socket.assigns.picked, & &1.id)

    cond do
      text == "" and entries == [] and picked == [] ->
        {:noreply, socket}

      Enum.any?(entries, &(not &1.done?)) ->
        {:noreply,
         put_flash(socket, :error, "A file is still uploading, or failed; wait or remove it.")}

      true ->
        documents = store_uploads(socket)

        opts = [attachments: documents ++ picked] ++ thread_opt(socket)

        case Runtime.post_user_message(cid(socket), text, opts) do
          {:ok, result} ->
            {:noreply,
             socket
             |> assign_composer("")
             |> assign(:picked, [])
             |> assign(:replying_to, nil)
             |> outsider_hint(result)
             |> push_event("composer:clear", %{})}

          {:error, reason} ->
            # the files were stored for a message that never happened
            documents
            |> Enum.map(&Documents.get/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.each(&Documents.delete/1)

            {:noreply, socket |> assign_composer(body) |> put_flash(:error, to_string(reason))}
        end
    end
  end

  # Uploads only progress through a phx-change; the composer text never
  # round-trips, so there is nothing to validate.
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  # -- Attach from the library --------------------------------------------------

  def handle_event("open_library", _params, socket),
    do: {:noreply, load_library(socket, "")}

  def handle_event("close_library", _params, socket),
    do: {:noreply, assign(socket, :library, nil)}

  def handle_event("search_library", %{"q" => q}, socket),
    do: {:noreply, load_library(socket, q)}

  def handle_event("pick_document", %{"id" => id}, socket) do
    case Documents.get(id) do
      nil -> {:noreply, socket}
      document -> {:noreply, socket |> pick(document) |> assign(:library, nil)}
    end
  end

  def handle_event("unpick_document", %{"id" => id}, socket) do
    {:noreply, assign(socket, :picked, Enum.reject(socket.assigns.picked, &(&1.id == id)))}
  end

  def handle_event("abort", %{"agent-id" => agent_id}, socket) do
    case Runtime.abort(cid(socket), agent_id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Abort requested.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Abort failed: #{inspect(reason)}")}
    end
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
        pending = Enum.reject(socket.assigns.pending_permissions, &(&1.id == id))
        {:noreply, assign(socket, :pending_permissions, pending)}

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
    older = Timeline.list(cid(socket), limit: @page_size, before: socket.assigns.oldest_event_id)
    {items, threads, ids} = split_threads(older)

    {:noreply,
     socket
     |> assign(:threads, Map.merge(socket.assigns.threads, threads))
     |> assign(:message_ids, MapSet.union(socket.assigns.message_ids, ids))
     |> assign(
       :oldest_event_id,
       older |> List.first() |> then(&(&1 && &1.id)) || socket.assigns.oldest_event_id
     )
     |> assign(:has_earlier?, length(older) >= @page_size)
     |> stream(:timeline, Enum.reverse(items), at: 0)}
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
      schedule_counts={@schedule_counts}
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
      agent_statuses={@agent_statuses}
    >
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
          <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Scheduled
          </span>
          <span class="text-xs text-base-content/50">
            Agents schedule with canopy_schedule_create; ask one to set a reminder or a repeat.
          </span>
        </div>
        <.schedule_list id="channel-schedules" schedules={@schedules} scope={:channel} />
      </section>

      <.members_panel
        :if={@editing_members?}
        channel={@channel}
        members={@members}
        addable={@addable_agents}
        agent_statuses={@agent_statuses}
      />

      <div
        id="timeline-scroll"
        class="flex-1 overflow-y-auto scroll-smooth"
        phx-hook="TimelineScroll"
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
            class="hidden only:flex flex-col items-center gap-1 px-3 py-16 text-center text-sm text-base-content/50"
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
            replies={thread_replies(@threads, event)}
            thread_open={thread_open?(@open_threads, event)}
            channels={@channel_links}
          />
        </div>

        <.telemetry_card
          :for={{agent_id, card} <- @telemetry}
          agent_id={agent_id}
          name={Map.get(@names, agent_id, "agent")}
          card={card}
        />

        <.permission_card :for={request <- @pending_permissions} request={request} names={@names} />
        <.question_card :for={request <- @pending_questions} request={request} names={@names} />
      </div>

      <.limit_bar
        :if={limit_reached?(@channel, @spent) and !Channels.archived?(@channel)}
        channel={@channel}
        spent={@spent}
      />
      <.paused_bar :if={@paused? and !Channels.archived?(@channel)} />
      <.composer
        :if={!Channels.archived?(@channel)}
        form={@composer}
        agent_names={@agent_names}
        channel_names={@channel_names}
        uploads={@uploads}
        picked={@picked}
        replying_to={@replying_to}
        user_name={@user.display_name}
      />
      <.library_picker :if={@library} library={@library} />
      <.archived_bar :if={Channels.archived?(@channel)} channel={@channel} />

      <.changes_modal :if={@changes} changes={@changes} repository={@channel.repository} />
    </Layouts.app>
    """
  end

  defp channel_title(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp channel_title(channel), do: "#" <> channel.name

  defp thread_replies(threads, %{event_type: "message", message: %{id: id, thread_id: nil}}),
    do: Map.get(threads, id, [])

  defp thread_replies(_threads, _event), do: []

  defp thread_open?(open, %{event_type: "message", message: %{id: id, thread_id: nil}}),
    do: MapSet.member?(open, id)

  defp thread_open?(_open, _event), do: false

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

  defp channel_header(assigns) do
    ~H"""
    <header
      id="channel-header"
      class="flex shrink-0 flex-col gap-1.5 border-b border-base-300 px-3 py-2 sm:px-6 sm:py-3"
    >
      <div class="flex min-w-0 items-center gap-2 sm:gap-3">
        <Layouts.menu_button />
        <h1 id="channel-name" class="flex items-baseline gap-1 truncate text-base font-semibold">
          <%= if Channels.dm?(@channel) do %>
            {Channels.dm_label(@channel)}
            <span
              class="ml-1 rounded-full bg-base-300/70 px-1.5 text-[10px] font-medium uppercase tracking-wide text-base-content/50"
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
          class="truncate text-sm text-base-content/60"
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
            <span class="hidden sm:inline">Members</span>
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
            <span class="hidden sm:inline">Activity</span>
          </button>
          <button
            type="button"
            id="edit-schedules"
            class={["btn btn-xs btn-ghost", @editing_schedules? && "btn-active"]}
            phx-click="toggle_schedules"
            title="Scheduled tasks in this channel"
          >
            <.icon name="hero-clock-mini" class="size-4" />
            <span class="hidden sm:inline">Scheduled</span>
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
            <span class="hidden sm:inline">
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
            <span class="hidden sm:inline">Task</span>
          </button>
          <button
            type="button"
            id="open-changes"
            class="btn btn-xs btn-ghost"
            phx-click="open_changes"
          >
            <.icon name="hero-document-plus-mini" class="size-4" />
            <span class="hidden sm:inline">Changes</span>
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
            <span class="hidden sm:inline">Archive</span>
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
            <span class="hidden sm:inline">Reopen</span>
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
            <button
              :if={Map.get(@agent_statuses, member.id) == :busy}
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
              :if={Map.get(@agent_statuses, member.id) != :busy}
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

  defp task_badge("open"), do: "badge-ghost"
  defp task_badge("working"), do: "badge-info badge-soft"
  defp task_badge("blocked"), do: "badge-warning badge-soft"
  defp task_badge("completed"), do: "badge-success badge-soft"
  defp task_badge(_), do: "badge-ghost"

  attr :channel, :map, required: true
  attr :members, :list, required: true
  attr :addable, :list, required: true
  attr :agent_statuses, :map, required: true

  defp members_panel(assigns) do
    ~H"""
    <section
      id="members-panel"
      class="flex flex-col gap-3 border-b border-base-300 bg-base-200/60 px-3 py-3 sm:px-6"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
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
      <p :if={@addable == []} class="text-xs text-base-content/50">
        Every active agent is already here. Create more on the Agents page.
      </p>
    </section>
    """
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
        <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
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
          <span class="text-base-content/50">$</span>
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
      <p class="text-xs text-base-content/50">
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

  defp paused_bar(assigns) do
    ~H"""
    <div
      id="paused-bar"
      class="flex shrink-0 flex-wrap items-center justify-center gap-3 border-t border-warning/40 bg-warning/10 px-3 py-2 text-sm"
    >
      <.icon name="hero-pause-circle-mini" class="size-4 text-warning" />
      <span>
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

  attr :form, :map, required: true
  attr :agent_names, :list, required: true
  attr :channel_names, :list, required: true
  attr :uploads, :map, required: true
  attr :picked, :list, required: true
  attr :replying_to, :map, default: nil
  attr :user_name, :string, required: true

  defp composer(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-base-300 bg-base-100 px-3 pb-2 pt-2 sm:px-6 sm:pb-3">
      <%!-- Files travel through their own form: uploads need a phx-change, and
           the composer text must never round-trip on every keystroke. --%>
      <form id="upload-form" phx-change="validate_upload" phx-submit="validate_upload" class="hidden">
        <.live_file_input upload={@uploads.files} />
      </form>
      <div
        :if={@replying_to}
        id="composer-thread"
        phx-window-keydown="cancel_reply"
        phx-key="Escape"
        class="mb-1.5 flex items-center gap-2 rounded-lg border border-primary/30 bg-primary/5 px-2.5 py-1.5 text-xs"
      >
        <.icon name="hero-chat-bubble-left-right-mini" class="size-3.5 shrink-0 text-primary" />
        <span class="shrink-0 font-medium text-primary">
          {if @replying_to.replies == 0, do: "Starting a thread on", else: "Replying in thread to"}
        </span>
        <span class="min-w-0 flex-1 truncate text-base-content/60">
          {@replying_to.sender}: {@replying_to.excerpt}
        </span>
        <button
          type="button"
          id="composer-thread-cancel"
          class="btn btn-ghost btn-xs btn-square shrink-0"
          phx-click="cancel_reply"
          title="Post to the channel instead (Esc)"
          aria-label="Cancel the thread reply"
        >
          <.icon name="hero-x-mark-mini" class="size-3.5" />
        </button>
      </div>
      <.form
        for={@form}
        id="composer-form"
        phx-submit="send"
        data-agents={Jason.encode!(@agent_names)}
        data-channels={Jason.encode!(@channel_names)}
        class="relative"
      >
        <div
          id="composer-suggestions"
          phx-update="ignore"
          class="absolute bottom-full left-0 z-10 mb-1 hidden w-64 overflow-hidden rounded-lg border border-base-300 bg-base-200 shadow-lg"
        >
        </div>
        <div
          id="composer-box"
          phx-drop-target={@uploads.files.ref}
          class="rounded-xl border border-base-300 bg-base-200 p-2 shadow-xs transition focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20"
        >
          <div
            :if={@uploads.files.entries != [] or @picked != []}
            id="composer-files"
            class="mb-2 flex flex-wrap gap-2"
          >
            <div
              :for={doc <- @picked}
              id={"picked-#{doc.id}"}
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
                <div class="text-base-content/50">shared · {Documents.size_label(doc.byte_size)}</div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-square"
                phx-click="unpick_document"
                phx-value-id={doc.id}
                title="Remove"
                aria-label={"Remove #{doc.filename}"}
              >
                <.icon name="hero-x-mark-mini" class="size-3.5" />
              </button>
            </div>
            <div
              :for={entry <- @uploads.files.entries}
              id={"upload-#{entry.ref}"}
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
                  :if={!entry.done? and upload_errors(@uploads.files, entry) == []}
                  class="text-base-content/50"
                >
                  {entry.progress}%
                </div>
                <div :for={err <- upload_errors(@uploads.files, entry)} class="text-error">
                  {upload_error(err)}
                </div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-square"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                title="Remove"
                aria-label={"Remove #{entry.client_name}"}
              >
                <.icon name="hero-x-mark-mini" class="size-3.5" />
              </button>
            </div>
          </div>
          <div :for={err <- upload_errors(@uploads.files)} class="mb-1 px-1 text-xs text-error">
            {upload_error(err)}
          </div>
          <%!-- The textarea is the browser's: LiveView never patches it, so the
               hook's auto-grown height and the draft survive every update.
               The server clears it with the "composer:clear" event. --%>
          <div id="composer-input-wrap" phx-update="ignore" class="min-w-0">
            <textarea
              id="composer-input"
              name={@form[:body].name}
              phx-hook="Composer"
              data-suggestions="#composer-suggestions"
              rows="1"
              placeholder="Message the channel — @mention an agent to wake it, #name a channel"
              class="max-h-[60vh] w-full resize-none border-0 bg-transparent px-1 py-1 text-sm leading-relaxed outline-none focus:outline-none"
              autocomplete="off"
            >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          </div>
          <%!-- Toolbar under the text, Slack-style: attach on the left, send on the right. --%>
          <div class="mt-1 flex items-center gap-1">
            <label
              for={@uploads.files.ref}
              id="composer-attach"
              class="btn btn-sm btn-ghost btn-square cursor-pointer"
              title="Attach a file from your computer (or paste, or drop one here)"
            >
              <.icon name="hero-folder-open-mini" class="size-4" />
            </label>
            <button
              type="button"
              id="composer-library"
              class="btn btn-sm btn-ghost btn-square"
              phx-click="open_library"
              title="Attach a file already shared in Canopy"
            >
              <.icon name="hero-paper-clip-mini" class="size-4" />
            </button>
            <button
              type="submit"
              id="composer-send"
              class="btn btn-sm btn-primary btn-square ml-auto"
              title="Send (Enter)"
            >
              <.icon name="hero-paper-airplane-mini" class="size-4" />
            </button>
          </div>
        </div>
        <p class="mt-1.5 hidden px-1 text-[11px] text-base-content/45 sm:block">
          Enter to send · Shift+Enter for a new line · paste or drop files to attach · {Commands.help()}
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
              <p class="truncate text-[11px] text-base-content/50" title={@repository.path}>
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
            class="px-4 pb-3 text-xs text-base-content/50"
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
          <pre
            :if={@changes.diff}
            id="file-diff"
            class="flex-1 overflow-auto px-4 py-3 font-mono text-xs leading-relaxed"
          ><code>{@changes.diff}</code></pre>
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
