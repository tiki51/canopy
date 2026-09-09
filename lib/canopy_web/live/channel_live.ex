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
    Handoffs,
    PermissionRequests,
    Repositories,
    Runtime,
    Tasks,
    Timeline,
    Users
  }

  alias Canopy.OpenCode.Event
  alias Canopy.Runtime.Commands
  alias Canopy.Tasks.Task

  @page_size 100
  @branch_interval 15_000
  @card_entries 80
  @preview_chars 1_500

  @empty_card %{
    entries: [],
    preview: "",
    collapsed: false,
    tool_count: 0,
    cost: 0.0
  }

  # -- Lifecycle ---------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:channel, nil)
     |> assign(:branch_timer, nil)
     |> stream_configure(:timeline, dom_id: &"evt-#{&1.id}")
     |> stream(:timeline, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case socket.assigns.channel do
      %{id: ^id} -> {:noreply, socket}
      _ -> {:noreply, load_channel(socket, id)}
    end
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
    names = Map.new(Agents.list(), &{&1.id, &1.name})
    events = Timeline.list(id, limit: @page_size)
    {items, threads, message_ids} = split_threads(events)
    statuses = Runtime.status(id)

    agent_statuses =
      Map.new(members, fn member -> {member.id, Map.get(statuses, member.id, :idle)} end)

    telemetry =
      for {agent_id, :busy} <- agent_statuses, into: %{} do
        {agent_id, Enum.reduce(Runtime.telemetry(id, agent_id), @empty_card, &fold_telemetry/2)}
      end

    socket
    |> assign(:page_title, "##{channel.name}")
    |> assign(:channel, channel)
    |> assign(:members, members)
    |> assign(:member_names, Enum.map(members, & &1.name))
    |> assign(:user, user)
    |> assign(:names, names)
    |> assign(:agent_statuses, agent_statuses)
    |> assign(:telemetry, telemetry)
    |> assign(:threads, threads)
    |> assign(:message_ids, message_ids)
    |> assign(:oldest_event_id, events |> List.first() |> then(&(&1 && &1.id)))
    |> assign(:has_earlier?, length(events) >= @page_size)
    |> assign(:pending_handoffs, Handoffs.pending_for_channel(id))
    |> assign(:pending_permissions, PermissionRequests.pending_for_channel(id))
    |> assign(:editing_task?, false)
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
    {:noreply, socket |> insert_event(event) |> react_to(event)}
  end

  def handle_info({:telemetry, agent_id, %Event{} = event}, socket) do
    card = fold_telemetry(event, Map.get(socket.assigns.telemetry, agent_id, @empty_card))

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

  defp react_to(socket, %{event_type: "task_updated"}),
    do: assign_task(socket, Tasks.for_channel(cid(socket)))

  defp react_to(socket, %{event_type: "permission_" <> _}), do: refresh_permissions(socket)
  defp react_to(socket, _event), do: socket

  defp refresh_channel(socket) do
    channel = Channels.get!(cid(socket))
    assign(socket, :channel, channel)
  end

  defp refresh_handoffs(socket),
    do: assign(socket, :pending_handoffs, Handoffs.pending_for_channel(cid(socket)))

  defp refresh_permissions(socket),
    do: assign(socket, :pending_permissions, PermissionRequests.pending_for_channel(cid(socket)))

  defp cid(socket), do: socket.assigns.channel.id

  # -- Telemetry folding -------------------------------------------------------

  defp fold_telemetry(%Event{type: :tool_started, data: data}, card) do
    put_entry(card, %{
      key: data[:call_id] || data[:part_id] || unique_key(),
      kind: :tool,
      status: :running,
      label: data[:title] || data[:tool] || "tool",
      detail: short_input(data[:input])
    })
  end

  defp fold_telemetry(%Event{type: :tool_completed, data: data}, card) do
    entry = %{
      key: data[:call_id] || data[:part_id] || unique_key(),
      kind: :tool,
      status: if(data[:status] == :error, do: :error, else: :ok),
      label: data[:title] || data[:tool] || "tool",
      detail: data[:error] || short_input(data[:input])
    }

    card = put_entry(card, entry)
    %{card | tool_count: card.tool_count + 1}
  end

  defp fold_telemetry(%Event{type: :file_changed, data: %{path: path}}, card) do
    put_entry(card, %{
      key: "file-" <> path,
      kind: :file,
      status: :ok,
      label: Path.basename(path),
      detail: path
    })
  end

  defp fold_telemetry(%Event{type: :step_completed, data: data}, card) do
    cost = if is_number(data[:cost]), do: data[:cost], else: 0.0

    card =
      put_entry(card, %{
        key: "step-" <> unique_key(),
        kind: :step,
        status: :ok,
        label: "step #{data[:reason] || "completed"}",
        detail: step_detail(data[:tokens], cost)
      })

    %{card | cost: card.cost + cost}
  end

  defp fold_telemetry(%Event{type: :text_delta, data: %{delta: delta}}, card)
       when is_binary(delta) do
    %{card | preview: tail(card.preview <> delta, @preview_chars)}
  end

  defp fold_telemetry(%Event{type: :text_done, data: %{text: text}}, card) when is_binary(text) do
    %{card | preview: tail(text, @preview_chars)}
  end

  defp fold_telemetry(%Event{type: :diff, data: %{files: files}}, card) when is_list(files) do
    put_entry(card, %{
      key: "diff-" <> unique_key(),
      kind: :diff,
      status: :ok,
      label: "#{length(files)} changed #{if(length(files) == 1, do: "file", else: "files")}",
      detail: Enum.map_join(files, ", ", &diff_file/1)
    })
  end

  defp fold_telemetry(%Event{type: :patch, data: data}, card) do
    files = List.wrap(data[:files])

    put_entry(card, %{
      key: "patch-" <> unique_key(),
      kind: :diff,
      status: :ok,
      label: "patch",
      detail: Enum.map_join(files, ", ", &diff_file/1)
    })
  end

  defp fold_telemetry(_event, card), do: card

  defp put_entry(card, %{key: key} = entry) do
    entries =
      if Enum.any?(card.entries, &(&1.key == key)),
        do: Enum.map(card.entries, fn e -> if e.key == key, do: entry, else: e end),
        else: Enum.take(card.entries ++ [entry], -@card_entries)

    %{card | entries: entries}
  end

  defp short_input(input) when is_map(input) do
    value =
      Enum.find_value(~w(filePath path command pattern description query url), fn key ->
        case Map.get(input, key) do
          v when is_binary(v) and v != "" -> v
          _ -> nil
        end
      end) ||
        case Map.values(input) do
          [v | _] when is_binary(v) -> v
          _ -> nil
        end

    value && truncate(value, 80)
  end

  defp short_input(_), do: nil

  defp step_detail(tokens, cost) do
    total =
      case tokens do
        %{} -> tokens |> Map.values() |> Enum.filter(&is_number/1) |> Enum.sum()
        _ -> 0
      end

    [
      if(total > 0, do: "#{total} tokens"),
      if(cost > 0, do: format_cost(cost))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      detail -> detail
    end
  end

  defp diff_file(%{} = file) do
    name = file["file"] || file["path"] || file[:file] || file[:path] || "?"
    adds = file["additions"] || file[:additions]
    dels = file["deletions"] || file[:deletions]

    if is_integer(adds) or is_integer(dels),
      do: "#{name} (+#{adds || 0}/-#{dels || 0})",
      else: to_string(name)
  end

  defp diff_file(other), do: to_string(other)

  defp tail(text, max) do
    if String.length(text) > max, do: "…" <> String.slice(text, -max, max), else: text
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp unique_key, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  # -- Events ------------------------------------------------------------------

  @impl true
  def handle_event("composer_change", %{"message" => %{"body" => body}}, socket) do
    {:noreply, assign_composer(socket, body)}
  end

  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    case String.trim(body) do
      "" ->
        {:noreply, socket}

      text ->
        case Runtime.post_user_message(cid(socket), text) do
          {:ok, _} ->
            {:noreply, socket |> assign_composer("") |> push_event("composer:clear", %{})}

          {:error, reason} ->
            {:noreply, socket |> assign_composer(body) |> put_flash(:error, to_string(reason))}
        end
    end
  end

  def handle_event("abort", %{"agent-id" => agent_id}, socket) do
    case Runtime.abort(cid(socket), agent_id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Abort requested.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Abort failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_telemetry", %{"agent-id" => agent_id}, socket) do
    telemetry =
      Map.update(socket.assigns.telemetry, agent_id, @empty_card, fn card ->
        %{card | collapsed: not card.collapsed}
      end)

    {:noreply, assign(socket, :telemetry, telemetry)}
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
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      agent_statuses={@agent_statuses}
    >
      <.channel_header
        channel={@channel}
        task={@task}
        branch={@branch}
        members={@members}
        agent_statuses={@agent_statuses}
        editing_task?={@editing_task?}
      />

      <.handoff_banner
        :for={handoff <- @pending_handoffs}
        handoff={handoff}
        names={@names}
        user_name={@user.display_name}
      />

      <.task_panel :if={@editing_task? and @task_form} form={@task_form} />

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

        <div id="timeline" phx-update="stream" class="flex flex-col py-2">
          <div
            id="timeline-empty"
            class="hidden only:flex flex-col items-center gap-1 px-6 py-16 text-center text-sm text-base-content/50"
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
          />
        </div>

        <.telemetry_card
          :for={{agent_id, card} <- @telemetry}
          agent_id={agent_id}
          name={Map.get(@names, agent_id, "agent")}
          card={card}
        />

        <.permission_card :for={request <- @pending_permissions} request={request} names={@names} />
      </div>

      <.composer form={@composer} member_names={@member_names} />

      <.changes_modal :if={@changes} changes={@changes} repository={@channel.repository} />
    </Layouts.app>
    """
  end

  defp thread_replies(threads, %{event_type: "message", message: %{id: id, thread_id: nil}}),
    do: Map.get(threads, id, [])

  defp thread_replies(_threads, _event), do: []

  attr :channel, :map, required: true
  attr :task, :map, default: nil
  attr :branch, :string, default: nil
  attr :members, :list, required: true
  attr :agent_statuses, :map, required: true
  attr :editing_task?, :boolean, default: false

  defp channel_header(assigns) do
    ~H"""
    <header
      id="channel-header"
      class="flex shrink-0 flex-col gap-1.5 border-b border-base-300 px-6 py-3"
    >
      <div class="flex min-w-0 items-center gap-3">
        <h1 id="channel-name" class="flex items-baseline gap-1 truncate text-base font-semibold">
          <span class="text-base-content/40">#</span>{@channel.name}
        </h1>
        <p :if={@channel.topic} class="truncate text-sm text-base-content/60" id="channel-topic">
          {@channel.topic}
        </p>
        <div class="ml-auto flex shrink-0 items-center gap-2">
          <button
            type="button"
            id="edit-task"
            class={["btn btn-xs btn-ghost", @editing_task? && "btn-active"]}
            phx-click="toggle_task_form"
          >
            <.icon name="hero-clipboard-document-list-mini" class="size-4" /> Task
          </button>
          <button
            type="button"
            id="open-changes"
            class="btn btn-xs btn-ghost"
            phx-click="open_changes"
          >
            <.icon name="hero-document-plus-mini" class="size-4" /> Changes
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
            <span :if={Map.get(@agent_statuses, member.id) != :busy} class="w-1" />
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

  attr :form, :map, required: true

  defp task_panel(assigns) do
    ~H"""
    <section id="task-panel" class="border-b border-base-300 bg-base-200/60 px-6 py-3">
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
  attr :member_names, :list, required: true

  defp composer(assigns) do
    ~H"""
    <div class="shrink-0 border-t border-base-300 bg-base-100 px-6 pb-3 pt-2">
      <.form
        for={@form}
        id="composer-form"
        phx-submit="send"
        phx-change="composer_change"
        class="relative"
      >
        <div
          id="composer-suggestions"
          phx-update="ignore"
          class="absolute bottom-full left-0 z-10 mb-1 hidden w-64 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-lg"
        >
        </div>
        <div class="flex items-end gap-2 rounded-xl border border-base-300 bg-base-100 p-2 shadow-xs transition focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20">
          <textarea
            id="composer-input"
            name={@form[:body].name}
            phx-hook="Composer"
            data-members={Jason.encode!(@member_names)}
            data-suggestions="#composer-suggestions"
            rows="2"
            placeholder="Message the channel — @mention an agent to wake it"
            class="max-h-48 min-h-10 flex-1 resize-none border-0 bg-transparent px-1 py-1 text-sm leading-relaxed outline-none focus:outline-none"
            autocomplete="off"
          >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          <button
            type="submit"
            id="composer-send"
            class="btn btn-sm btn-primary btn-square"
            title="Send (Enter)"
          >
            <.icon name="hero-paper-airplane-mini" class="size-4" />
          </button>
        </div>
        <p class="mt-1.5 px-1 text-[11px] text-base-content/45">
          Enter to send · Shift+Enter for a new line · {Commands.help()}
        </p>
      </.form>
    </div>
    """
  end

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
        class="flex h-[80vh] w-full max-w-5xl overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
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
