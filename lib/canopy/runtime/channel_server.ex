defmodule Canopy.Runtime.ChannelServer do
  @moduledoc """
  One process per open channel. It owns the engine sessions of the channel's
  agents, turns durable collaboration events into agent wake-ups, and turns
  engine execution events into durable state and live telemetry. Everything
  engine-specific goes through the `Canopy.Engine` adapter of the agent's engine.

  Inputs:
    * `{:timeline, %Canopy.Timeline.Event{}}` from `Canopy.Timeline` (messages,
      delegations, handoffs). Routed by `Canopy.Runtime.Router`.
    * `{:engine_event, %Canopy.Engine.Event{}}` from the engine's event source,
      delivered on per-session topics.

  Outputs on the channel topic (`"channel:<id>"`):
    * `{:telemetry, agent_id, %Canopy.Engine.Event{}}` — ephemeral tool/text activity,
      stamped with `at` and slimmed (`Canopy.Runtime.Activity.slim_event/1`)
    * `{:agent_status, agent_id, :idle | :queued | :busy | :awaiting_user | :error}`
    * `{:turn_thread, agent_id, thread_id | nil}` — the thread a turn that just
      started works for (nil: the channel), and nil again when it ends; also
      sent on `Canopy.Threads`' topic for views that span channels

  Thread-scoped turns. A wake for a message in a thread remembers the thread's
  root; a turn started from it works for that thread: its started, finished,
  and error lines belong to the thread (only the thread panel shows them),
  and a final text the agent did not post itself lands in the thread. Wakes
  merged from different threads, or from a thread and the channel, make a
  channel turn, as before threads had a place of their own.

  Permission and question prompts. A turn whose engine holds a tool call open
  on a card is marked as awaiting the user (`:awaiting_user`). It still holds
  its session (the agent's later wakes queue behind it), but under
  `serialize_turns` it no longer holds the channel: other agents' wakes start
  while it waits. When the answer comes and the blocked turn resumes, another
  turn may already be running; that is the one sanctioned overlap of
  serialized turns. When a turn ends with cards still pending, or the engine
  stops waiting on one, the cards are detached rather than cleared: they stay
  answerable, and a late answer is posted to the channel as a message from
  the user mentioning the agent, which wakes it like any other message.

  Locks (`Canopy.Locks`). A lock claim belongs to the turn that holds it:
  every turn carries a `ref`, and however the turn ends (done, error, stopped,
  watchdog) its claims are released. A turn blocked on a card is still in
  flight, so it keeps its locks until it ends. When a lock passes to a waiting
  session of this channel, `{:lock_granted, claim}` arrives on the
  repository's locks topic and that session is woken through the normal wake
  path (holds, spend limit, chatter budget, serialize_turns); the turn the
  wake starts takes ownership of the claim. The watchdog also runs the lock
  lease for this channel's claims.

  The MCP tools rarely call this process (`canopy_pass`, and lock tools asking
  for the turn in flight); they write through contexts and the resulting
  timeline events arrive here like any other.
  """

  use GenServer
  require Logger

  alias Canopy.{
    Agents,
    AgentSessions,
    Channels,
    Costs,
    Delegations,
    Locks,
    Messages,
    PermissionRequests,
    QuestionRequests,
    Repositories,
    Settings,
    Teams,
    Timeline,
    Users
  }

  alias Canopy.Engine
  alias Canopy.Engine.Event
  alias Canopy.PermissionRequests.PermissionRequest
  alias Canopy.QuestionRequests.QuestionRequest
  alias Canopy.Runtime.{Activity, Prompts, Router}
  alias Canopy.Timeline.ActivityDetails

  @reconcile_grace_ms 15_000

  # How often the turn watchdog looks for turns that have gone quiet, and how
  # long a turn may go without an engine event before it is reconciled.
  @watchdog_ms 60_000
  @turn_stall_ms 120_000
  # A turn waiting on the user emits nothing, and that is not a stall; it is
  # still checked against the engine now and then, so a dead engine is noticed.
  @awaiting_stall_ms 10 * @turn_stall_ms

  # How long the engine may keep retrying a failing model call (a provider's
  # usage limit, an outage) before the turn is ended and the channel told.
  @retry_give_up_ms 300_000

  # Wakes Canopy sends on its own account, whose text is the whole message:
  # merged with another wake, neither text may be dropped.
  @automation_triggers ~w(scheduled watch playbook playbook_nudge)

  # Appended to a wake that replaced an earlier one still waiting for the same agent.
  @merged_wake_note "\nOther messages arrived while you were busy; this wake stands for all of them, and canopy_messages_read returns everything new.\n"

  @fields [
    :channel,
    :repository,
    # options handed to every engine's attach/2 (tests pass start_stream: false)
    engine_opts: [],
    # engine module => the adapter's own state for this channel
    engines: %{},
    # agent_id => %AgentSession{}: one session per agent in the channel
    sessions: %{},
    # engine_session_id => %{agent_id}
    index: %{},
    # engine_session_id => turn accumulator while busy
    turns: %{},
    # engine_session_id => [pending prompt text]
    queues: %{},
    # agent_id => the activity card (`Canopy.Runtime.Activity`) of the turn
    # in flight, folded as its events arrive
    telemetry: %{},
    stream_seen?: false,
    # agent turns started since the user last did something
    chatter: 0,
    # the team-mention charges already counted in `chatter` (one turn per team mention)
    charged: MapSet.new(),
    # nil, or the wakeups held back once the chatter budget ran out
    paused: nil,
    # the user pressed Stop: wakes stay held (paused) until they reply or continue
    stopped?: false,
    # a DM moved to another repository: applied once no turn is in flight
    pending_switch?: false,
    # wakes waiting for the channel's one turn at a time (serialize_turns)
    waiting: [],
    # the hold reason this channel already posted a note for (one note per hold)
    hold_noted: nil,
    # the spend limit this channel already recorded as reached (one line per limit)
    limit_noted: nil,
    # agent_id => [{target, wake, message}] caused by that agent's posts while
    # its turn was still running; released, merged per target, when it ends
    deferred: %{}
  ]

  defstruct @fields

  # A dev code reload swaps this module under running servers without touching
  # their state, so a server started before a struct field was added would
  # crash on its first access. Each callback fills in defaults first.
  @field_count length(@fields) + 1

  @doc "Agent turns allowed between user actions before the channel pauses itself; nil when off."
  def chatter_limit, do: Canopy.Settings.chatter_limit()

  # -- API --------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Answers a permission prompt. When the engine no longer holds it, an approval
  is posted to the channel as a message mentioning the agent, saying what it
  may now do; a rejection only clears the card. `{:error, :archived}` for an
  approval in an archived channel.
  """
  def respond_permission(server, permission_request_id, reply)
      when reply in [:once, :always, :reject],
      do: GenServer.call(server, {:respond_permission, permission_request_id, reply})

  @doc """
  Answers the question an agent asked through its engine's question tool.
  `{:answered, answers}` carries one list of chosen option labels (or free
  text) per question, in question order; `:rejected` declines to answer. When
  the engine no longer holds the question, the answer is posted to the
  channel as a message mentioning the agent. `{:error, :archived}` for an
  answer in an archived channel.
  """
  def respond_question(server, question_request_id, outcome)
      when outcome == :rejected or elem(outcome, 0) == :answered,
      do: GenServer.call(server, {:respond_question, question_request_id, outcome})

  def abort(server, agent_id), do: GenServer.call(server, {:abort, agent_id})

  @doc """
  Stops everything in the channel: aborts every turn in flight, drops every
  wake still waiting, and holds any wake agents cause afterwards until the
  user replies or presses Continue. Returns how many turns were aborted and
  how many wakes dropped.
  """
  def stop_all(server), do: GenServer.call(server, :stop_all)
  def stopped?(server), do: GenServer.call(server, :stopped?)

  def reset_session(server, agent_id, by),
    do: GenServer.call(server, {:reset_session, agent_id, by})

  def telemetry(server, agent_id), do: GenServer.call(server, {:telemetry, agent_id})
  def status(server), do: GenServer.call(server, :status)
  def paused?(server), do: GenServer.call(server, :paused?)

  def pass(server, engine_session_id, reason),
    do: GenServer.call(server, {:pass, engine_session_id, reason})

  def continue(server), do: GenServer.call(server, :continue)

  @doc "`%{agent_id => thread_id}` for every turn in flight that works for a thread."
  def turn_threads(server), do: GenServer.call(server, :turn_threads)

  @doc "The `ref` of the session's turn in flight (by `AgentSession.id`), or nil."
  def turn_ref(server, session_id), do: GenServer.call(server, {:turn_ref, session_id}, 15_000)

  def wake(server, agent_id, text),
    do: GenServer.cast(server, {:wake, {:root, agent_id}, %{text: text, trigger: "scheduled"}})

  @doc """
  Wakes an agent with `text`. Options: `:trigger` (what the turn is
  attributed to, default "scheduled"), `:reset` (default true): a wake the
  user asked for resets the chatter budget like a user action; with `reset:
  false` it is an agent wake, counted against the budget and held when the
  channel is paused; and `:check` (a stall nudge's `{run_id, step_id,
  round}`): the wake is dropped if, when its prompt would go out, the run has
  moved on.
  """
  def wake(server, agent_id, text, opts) do
    wake =
      %{text: text, trigger: Keyword.get(opts, :trigger, "scheduled")}
      |> then(&if check = opts[:check], do: Map.put(&1, :playbook_check, check), else: &1)

    if Keyword.get(opts, :reset, true),
      do: GenServer.cast(server, {:wake, {:root, agent_id}, wake}),
      else: GenServer.cast(server, {:wake_counted, {:root, agent_id}, wake})
  end

  # -- Callbacks --------------------------------------------------------------

  @impl true
  def init(opts) do
    # Finish the message in flight before a supervisor shutdown takes effect, so a
    # timeline write is never cut off mid-transaction.
    Process.flag(:trap_exit, true)
    channel_id = Keyword.fetch!(opts, :channel_id)
    channel = Channels.get!(channel_id)
    repository = Repositories.get!(channel.repository_id)

    state = %__MODULE__{
      channel: channel,
      repository: repository,
      engine_opts: Keyword.take(opts, [:base_url, :start_stream])
    }

    # Subscribe and load sessions before start_link returns, so a message posted
    # right after ensure_channel/1 cannot be broadcast before we are listening.
    schedule_watchdog()
    {:ok, attach(state)}
  end

  defp schedule_watchdog, do: Process.send_after(self(), :watchdog, @watchdog_ms)

  defp upgrade(state), do: struct(__MODULE__, Map.from_struct(state))

  defp attach(state) do
    :ok = Timeline.subscribe(state.channel.id)
    :ok = Engine.subscribe_repository(state.repository.id)
    :ok = Settings.subscribe()
    :ok = Locks.subscribe(state.repository.id)
    # a lock granted to a session here while no server ran (a restart) still
    # waits for its wake; sent to self so init does not prompt an engine
    send(self(), :wake_pending_grants)
    state = attach_engines(state)

    # Turns in flight are not restored: a server restarted mid-turn does not
    # know that turn, so a wake for its agent is not queued behind it.
    # Rebuilding turns from sessions marked busy would need the engine's word
    # that they still run; the gap is accepted. Child sessions, left from when
    # an agent's delegations ran in sessions of their own, are never woken.
    state.channel.id
    |> AgentSessions.list_for_channel()
    |> Enum.filter(&is_nil(&1.parent_session_id))
    |> Enum.reduce(state, &put_root(&2, &1))
  end

  @impl true
  def handle_call(msg, from, %__MODULE__{} = state) when map_size(state) != @field_count,
    do: handle_call(msg, from, upgrade(state))

  # The engine is always told, even for a detached card. `:ok` means the
  # waiting tool call took the answer (a detached card can still be held by
  # an engine whose abort failed), so the card simply resolves. When the
  # engine no longer holds the prompt, or a detached card's engine reply
  # fails, the answer is late: it is posted to the channel instead. An
  # archived channel takes no answers or approvals, since one may wake an
  # agent; dismissing still works.
  def handle_call({:respond_permission, request_id, reply}, _from, state) do
    if reply != :reject and archived?(state) do
      {:reply, {:error, :archived}, state}
    else
      request = PermissionRequests.get!(request_id)
      {mod, es, state} = engine_for_request(state, request)

      case mod.reply_permission(ctx(state), es, request, reply) do
        :ok ->
          {:reply, resolve_if_pending(request, reply), clear_awaiting(state, request)}

        {:error, reason} when reason != :gone and is_nil(request.detached_at) ->
          {:reply, {:error, reason}, state}

        _late ->
          state = clear_awaiting(state, request)
          {:reply, deliver_late_permission(state, request, reply), state}
      end
    end
  end

  def handle_call({:respond_question, request_id, outcome}, _from, state) do
    if outcome != :rejected and archived?(state) do
      {:reply, {:error, :archived}, state}
    else
      request = QuestionRequests.get!(request_id)
      {mod, es, state} = engine_for_request(state, request)

      case mod.reply_question(ctx(state), es, request, outcome) do
        :ok ->
          {:reply, resolve_question_if_pending(request, outcome), clear_awaiting(state, request)}

        # the engine could not take the answer in place and released the agent
        {:ok, :as_message} ->
          state = clear_awaiting(state, request)
          {:reply, deliver_late_answer(state, request, outcome, as_message?: true), state}

        {:error, reason} when reason != :gone and is_nil(request.detached_at) ->
          {:reply, {:error, reason}, state}

        _late ->
          state = clear_awaiting(state, request)
          {:reply, deliver_late_answer(state, request, outcome, []), state}
      end
    end
  end

  # Drops the agent's root session in this channel so its next wake starts a
  # fresh engine session: the cure for a poisoned or bloated context.
  def handle_call({:reset_session, agent_id, by}, _from, state) do
    session =
      Map.get(state.sessions, agent_id) || AgentSessions.get_root(state.channel.id, agent_id)

    cond do
      is_nil(session) ->
        {:reply, {:error, :no_session}, state}

      Map.has_key?(state.turns, session.engine_session_id) ->
        {:reply, {:error, :busy}, state}

      true ->
        {:ok, _} = AgentSessions.delete(session)

        {:ok, _} =
          Timeline.record(%{
            channel_id: state.channel.id,
            agent_id: agent_id,
            event_type: "session_reset",
            ref_id: session.id,
            payload: %{"by" => by, "engine_session_id" => session.engine_session_id}
          })

        state = %{
          state
          | sessions: Map.delete(state.sessions, agent_id),
            index: Map.delete(state.index, session.engine_session_id),
            queues: Map.delete(state.queues, session.engine_session_id),
            telemetry: Map.delete(state.telemetry, agent_id)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call({:abort, agent_id}, _from, state) do
    case Map.get(state.sessions, agent_id) do
      nil ->
        {:reply, {:error, :no_session}, state}

      # The engine reports the abort later, as an error (OpenCode) or a clean
      # finish (Claude Code); the mark makes either close the turn as stopped.
      session ->
        {mod, es, state} = engine_of(state, session)

        case mod.abort(ctx(state), es, session) do
          {:ok, _} = ok ->
            {:reply, ok,
             update_turn(state, session.engine_session_id, &Map.put(&1, :stopped?, true))}

          error ->
            {:reply, error, state}
        end
    end
  end

  # The user's stop button. Every turn in flight is aborted and closed here,
  # rather than waiting for the engine to say so; the engine's own report of
  # the abort (an "Aborted" error, an idle) lands after the turn is gone and is
  # ignored. Every wake still waiting (queued behind a turn, held by the
  # chatter budget, deferred until a poster's turn ends) is dropped first, so
  # closing the turns starts nothing. The channel then holds wakes like a
  # chatter pause: the user's next message or Continue lifts it.
  def handle_call(:stop_all, _from, state) do
    dropped =
      length(state.waiting) + length(state.paused || []) +
        (state.queues |> Map.values() |> Enum.map(&length/1) |> Enum.sum()) +
        (state.deferred |> Map.values() |> Enum.map(&length/1) |> Enum.sum())

    Enum.each(waiting_agent_ids(state), &broadcast(state, {:agent_status, &1, :idle}))

    state = %{
      state
      | waiting: [],
        queues: %{},
        deferred: %{},
        paused: [],
        stopped?: true,
        chatter: 0,
        charged: MapSet.new()
    }

    turns = state.turns

    state =
      Enum.reduce(turns, state, fn {sid, turn}, acc ->
        abort_turn(acc, sid, turn, :stopped)
      end)

    aborted = map_size(turns)

    # what the channel's sessions hold or wait for goes too: a waiter left in
    # line would be granted the lock and woken into a stopped channel
    Enum.each(state.sessions, fn {_agent_id, session} ->
      Locks.release_session(session.id, "user", "Stop all")
    end)

    {:ok, _} =
      Messages.post_user_note(
        state.channel.id,
        Users.local().id,
        "Stopped all agent activity: #{count(aborted, "turn")} aborted, " <>
          "#{count(dropped, "queued wake")} dropped. " <>
          "Agents stay quiet until you reply or press Continue."
      )

    broadcast(state, {:chatter, :stopped})
    {:reply, {:ok, %{aborted: aborted, dropped: dropped}}, state}
  end

  def handle_call(:stopped?, _from, state), do: {:reply, state.stopped? == true, state}

  def handle_call({:telemetry, agent_id}, _from, state),
    do: {:reply, Map.get(state.telemetry, agent_id) || Activity.new(), state}

  def handle_call(:status, _from, state) do
    # An agent with a turn in flight is busy, even with a wake waiting in line
    # for it; one blocked on a card is shown as waiting on the user.
    idle = Map.new(state.sessions, fn {agent_id, _session} -> {agent_id, :idle} end)
    queued = Map.new(waiting_agent_ids(state), &{&1, :queued})
    busy = Map.new(state.turns, fn {_sid, turn} -> {turn.agent_id, :busy} end)

    awaiting =
      for {_sid, turn} <- state.turns, awaiting?(turn), into: %{} do
        {turn.agent_id, :awaiting_user}
      end

    {:reply, idle |> Map.merge(queued) |> Map.merge(busy) |> Map.merge(awaiting), state}
  end

  def handle_call(:paused?, _from, state), do: {:reply, is_list(state.paused), state}

  def handle_call(:turn_threads, _from, state) do
    threads =
      for {_sid, %{thread_id: thread_id} = turn} <- state.turns,
          is_binary(thread_id),
          into: %{},
          do: {turn.agent_id, thread_id}

    {:reply, threads, state}
  end

  def handle_call({:turn_ref, session_id}, _from, state) do
    ref =
      Enum.find_value(state.turns, fn {_sid, turn} ->
        if turn.session.id == session_id, do: Map.get(turn, :ref)
      end)

    {:reply, ref, state}
  end

  # The agent chose not to respond: the turn ends without a reply message.
  def handle_call({:pass, sid, reason}, _from, state) do
    if Map.has_key?(state.turns, sid),
      do: {:reply, :ok, update_turn(state, sid, &%{&1 | passed: reason || ""})},
      else: {:reply, {:error, :no_turn}, state}
  end

  # The user pressed Continue: the held wakeups run, against a fresh budget.
  def handle_call(:continue, _from, state) do
    held = state.paused || []
    state = %{state | chatter: 0, charged: MapSet.new(), paused: nil, stopped?: false}
    broadcast(state, {:chatter, :resumed})

    {:reply, :ok,
     Enum.reduce(held, state, fn {t, text}, acc -> wake_within_budget(acc, t, text) end)}
  end

  @impl true
  def handle_cast(msg, %__MODULE__{} = state) when map_size(state) != @field_count,
    do: handle_cast(msg, upgrade(state))

  def handle_cast({:wake, target, text}, state),
    do:
      {:noreply,
       wake_within_budget(%{state | chatter: 0, charged: MapSet.new(), paused: nil}, target, text)}

  def handle_cast({:wake_counted, target, wake}, state),
    do: {:noreply, wake_within_budget(state, target, wake)}

  @impl true
  def handle_info(msg, %__MODULE__{} = state) when map_size(state) != @field_count,
    do: handle_info(msg, upgrade(state))

  def handle_info({:timeline, %Timeline.Event{event_type: "repository_switched"}}, state),
    do: {:noreply, apply_switch(%{state | pending_switch?: true})}

  def handle_info({:timeline, %Timeline.Event{} = event}, state) do
    state = event |> note_agent_post(state) |> then(&maybe_refresh_channel(event, &1))
    ctx = router_ctx(state)

    # Anything the user does resets the budget and drops whatever was held:
    # their message wakes whoever it should on its own.
    state = if user_action?(event), do: resume(state), else: state

    trigger = trigger_of(event)

    wakes =
      Enum.map(Router.wakeups(event, ctx), fn {target, wake} ->
        {target, wake |> wake_message(trigger) |> put_message_id(event) |> put_delegation(event)}
      end)

    state =
      case posting_agent_mid_turn(event, state) do
        nil ->
          Enum.reduce(wakes, state, fn {target, wake}, acc ->
            wake_within_budget(acc, target, wake)
          end)

        agent_id ->
          defer_wakes(state, agent_id, wakes, event.message)
      end

    {:noreply, state}
  rescue
    e ->
      Logger.error(
        "channel runtime failed handling #{inspect(event.event_type)}: #{Exception.message(e)}"
      )

      {:noreply, state}
  end

  # OpenCode's `file.edited` carries no session id; attribute it to every turn
  # in flight in this channel (almost always exactly one agent is busy).
  def handle_info({:engine_event, %Event{type: :file_changed, session_id: nil} = event}, state) do
    state =
      Enum.reduce(state.turns, state, fn {sid, _turn}, acc ->
        case Map.get(acc.index, sid) do
          nil -> acc
          who -> handle_execution(%{event | session_id: sid}, who, touch_turn(acc, sid, event))
        end
      end)

    {:noreply, state}
  end

  def handle_info({:engine_event, %Event{session_id: sid} = event}, state) do
    case Map.get(state.index, sid) do
      nil -> {:noreply, state}
      who -> {:noreply, handle_execution(event, who, touch_turn(state, sid, event))}
    end
  end

  # The event stream reconnected: events may have been missed, so reconcile
  # against the engine's view of session status and pending prompts. The very
  # first connect after start carries nothing to reconcile and races the first
  # prompt, so it is skipped.
  def handle_info({:engine_stream, :connected, _repository_id}, %{stream_seen?: false} = state),
    do: {:noreply, %{state | stream_seen?: true}}

  # A reconnect usually means the engine restarted: whatever the adapters
  # memoised about it (an MCP registration) may be gone.
  def handle_info({:engine_stream, :connected, _repository_id}, state),
    do: {:noreply, state |> invalidate_engines(:stream_reconnected) |> reconcile()}

  # The MCP token changed: any registration an engine holds is stale.
  def handle_info({:settings, :mcp_token_rotated}, state),
    do: {:noreply, invalidate_engines(state, :mcp_token_rotated)}

  # A default model changed: nothing to do, every turn re-reads its agent and
  # the adapter resolves the default then.
  def handle_info({:settings, :default_models_changed}, state), do: {:noreply, state}

  # A turn ends when the engine reports the session idle. If that never arrives —
  # the stream dropped it, or the session died still holding an open tool call —
  # the turn stays in flight forever and every later wake for that agent queues
  # behind it, which looks like a channel that has stopped responding. Any turn
  # that has gone quiet, or has been stuck retrying a failing model call, gets
  # reconciled against the engine's own view. The same tick then runs the lock
  # lease for this channel's claims, once any turn that was gone is finished.
  def handle_info(:watchdog, state) do
    schedule_watchdog()

    state =
      if stalled_turn?(state) or retrying_turn?(state), do: reconcile(state), else: state

    {:noreply, expire_locks(state)}
  end

  # A lock passed to a waiting session of this channel: wake that session.
  def handle_info(
        {:lock_granted, %Locks.Claim{channel_id: id} = claim},
        %{channel: %{id: id}} = state
      ),
      do: {:noreply, wake_grant(state, claim)}

  def handle_info(:wake_pending_grants, state) do
    state =
      state.channel.id
      |> Locks.pending_grants_in_channel()
      |> Enum.reduce(state, &wake_grant(&2, &1))

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp stalled_turn?(state) do
    now = System.monotonic_time(:millisecond)
    Enum.any?(state.turns, fn {_sid, turn} -> stalled?(turn, now) end)
  end

  # A turn waiting on the user is quiet by design; only the slow check applies.
  defp stalled?(turn, now) do
    if awaiting?(turn),
      do: now - Map.get(turn, :awaiting_since, now) > @awaiting_stall_ms,
      else: now - Map.get(turn, :last_event_at, turn.started_at) > @turn_stall_ms
  end

  defp retrying_turn?(state) do
    now = System.monotonic_time(:millisecond)
    Enum.any?(state.turns, fn {_sid, turn} -> retrying_too_long?(turn, now) end)
  end

  defp retrying_too_long?(turn, now) do
    case Map.get(turn, :retrying) do
      %{since: since} -> now - since > @retry_give_up_ms
      _ -> false
    end
  end

  @doc false
  def reconcile(state) do
    state.engines
    |> Enum.reduce(state, fn {mod, es}, acc ->
      view = mod.reconcile(ctx(acc), es)

      acc
      |> abort_stuck_turns(mod, view.retrying)
      |> finish_idle_turns(mod, view)
      # prompts raised while we were disconnected (best effort)
      |> replay_prompts(view.permissions)
      |> replay_prompts(view.questions)
    end)
    |> restart_awaiting_clocks()
  end

  # A turn still waiting on the user after a reconcile was just checked: its
  # slow window starts again, so the next check is another window away.
  defp restart_awaiting_clocks(state) do
    now = System.monotonic_time(:millisecond)

    turns =
      Map.new(state.turns, fn {sid, turn} ->
        if awaiting?(turn), do: {sid, Map.put(turn, :awaiting_since, now)}, else: {sid, turn}
      end)

    %{state | turns: turns}
  end

  # Turns we think are running but the engine reports idle: finish them. A turn
  # younger than the grace period may not be marked busy yet, and one waiting on
  # a permission or question prompt is blocked rather than finished — OpenCode
  # can report such a session idle while it still holds the tool call open.
  # While the busy list or either prompt list is unknown, nothing is finished.
  defp finish_idle_turns(state, _mod, %{
         busy: busy,
         permissions: permissions,
         questions: questions
       })
       when busy == :unknown or permissions == :unknown or questions == :unknown,
       do: state

  defp finish_idle_turns(state, mod, %{
         busy: busy_ids,
         permissions: permissions,
         questions: questions
       }) do
    blocked_ids = Enum.map(permissions ++ questions, & &1.session_id)
    now = System.monotonic_time(:millisecond)

    state.turns
    |> Enum.reject(fn {sid, turn} ->
      Engine.for(turn.session) != mod or sid in busy_ids or sid in blocked_ids or
        now - turn.started_at < @reconcile_grace_ms
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reduce(state, fn sid, acc ->
      case Map.get(acc.index, sid) do
        nil ->
          acc

        who ->
          Logger.warning(
            "channel #{acc.channel.name}: finishing orphaned turn #{sid} (engine reports it idle)"
          )

          finish_turn(acc, sid, who, :ok)
      end
    end)
  end

  # Turns the engine reports as retrying a failing model call, and which have
  # been at it too long (retrying since well before now, or quiet for the stall
  # window because the retry notices themselves have spaced out), are ended:
  # the engine is told to abort, the turn closes with the provider's message as
  # its error, and the channel gets a note so nobody waits on an agent that
  # will not answer. A fresh retry is left to the engine, which handles
  # transient failures on its own.
  defp abort_stuck_turns(state, _mod, :unknown), do: state

  defp abort_stuck_turns(state, mod, retrying) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(retrying, state, fn %{session_id: sid} = retry, acc ->
      with %{} = turn <- Map.get(acc.turns, sid),
           true <- Engine.for(turn.session) == mod,
           true <- retrying_too_long?(turn, now) or stalled?(turn, now),
           %{} = who <- Map.get(acc.index, sid) do
        end_stuck_turn(acc, mod, sid, turn, who, retry)
      else
        _ -> acc
      end
    end)
  end

  defp end_stuck_turn(state, mod, sid, turn, who, retry) do
    reason = stuck_reason(mod, retry)
    agent_name = agent_name(who.agent_id)
    Logger.warning("channel #{state.channel.name}: ending #{agent_name}'s turn #{sid}: #{reason}")

    {:ok, _} =
      Timeline.record(
        Map.merge(
          %{
            channel_id: state.channel.id,
            agent_id: who.agent_id,
            event_type: "agent_error",
            payload: %{"reason" => reason}
          },
          thread_scope(Map.get(turn, :thread_id))
        )
      )

    {:ok, _} =
      Messages.post_user_note(
        state.channel.id,
        Users.local().id,
        "Ended #{agent_name}'s turn: #{reason}. Mention the agent again to retry."
      )

    abort_turn(state, sid, turn, {:error, reason})
  end

  # Tells the engine to abort the turn and closes it here with `outcome`
  # (`:stopped` for the user's stop, `{:error, reason}` otherwise), without
  # waiting for the engine's report.
  defp abort_turn(state, sid, turn, outcome) do
    {mod, es, state} = engine_of(state, turn.session)

    case mod.abort(ctx(state), es, turn.session) do
      {:ok, _} -> :ok
      {:error, error} -> Logger.warning("abort of #{sid} failed: #{inspect(error)}")
    end

    case Map.get(state.index, sid) do
      nil ->
        Locks.release_turn(turn.session.id, Map.get(turn, :ref))
        %{state | turns: Map.delete(state.turns, sid)}

      who ->
        finish_turn(state, sid, who, outcome)
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp stuck_reason(mod, %{message: message, attempt: attempt}) do
    attempts =
      case attempt do
        n when is_integer(n) and n > 0 -> " after #{n} attempts"
        _ -> ""
      end

    message = if is_binary(message) and message != "", do: ": #{message}", else: ""
    "#{mod.name()} was still retrying#{attempts}#{message}"
  end

  defp agent_name(agent_id) do
    case Agents.get(agent_id) do
      nil -> "the agent"
      agent -> agent.name
    end
  end

  defp replay_prompts(state, :unknown) do
    Logger.debug("prompt reconciliation skipped: the engine did not answer")
    state
  end

  # A prompt the engine still lists is re-recorded (a card resolved or detached
  # here comes back) and marks its turn as awaiting the user again.
  defp replay_prompts(state, events) do
    Enum.reduce(events, state, fn %Event{session_id: sid} = event, acc ->
      case Map.get(acc.index, sid) do
        nil -> acc
        who -> handle_execution(event, who, acc)
      end
    end)
  end

  # The session's turn is over: nothing waits on its cards any more. They stay
  # answerable; an answer now reaches the agent as a new message.
  defp detach_prompts(session) do
    Enum.each(QuestionRequests.waiting_for_session(session.id), &QuestionRequests.detach/1)
    Enum.each(PermissionRequests.waiting_for_session(session.id), &PermissionRequests.detach/1)
  end

  # -- Waking agents ----------------------------------------------------------

  # -- Chatter budget ---------------------------------------------------------
  #
  # Agents waking agents is what keeps a conversation alive, and also what
  # could keep it running unattended. Each turn started since the user's last
  # action counts; past the limit, wakeups are held and the channel says so.

  defp wake_within_budget(%{paused: held} = state, target, text) when is_list(held),
    do: %{state | paused: put_once(held, target, text)}

  defp wake_within_budget(state, target, text) do
    limit = chatter_limit()

    cond do
      # A lock grant that passed on while its wake waited (the lease, a Force
      # release) has nothing left to hand over, and costs no turn.
      stale_grant?(state, target, text) ->
        state

      # A global hold (billing): drop the wake and say so once per channel.
      # The user's next message, after releasing the hold, wakes agents again.
      Canopy.Hold.active?() ->
        note_hold(state)

      # The channel has spent its limit: drop the wake and say so once per limit.
      # Raising the limit and posting again wakes agents.
      over_spend_limit?(state) ->
        note_spend_limit(state)

      is_integer(limit) and state.chatter >= limit and not counted?(text) and
          not charged?(state, text) ->
        pause(state, limit, [{target, text}])

      # Already in line (a delegation waiting for its delegate, then a message
      # about it): merged into that entry, which keeps its place and its task.
      List.keymember?(state.waiting, target, 0) ->
        enqueue_waiting(state, target, text)

      # One turn at a time: agents woken while another works wait their turn,
      # in order. They are counted against the budget when they actually start.
      # A turn waiting on the user does not count: it is not working.
      Canopy.Settings.serialize_turns?() and running_turns(state) > 0 ->
        enqueue_waiting(state, target, text)

      true ->
        state |> charge(text) |> do_wake(target, Map.delete(text, :counted?))
    end
  end

  # Each turn that starts counts once, except a wake already counted when it
  # queued, and the second and later wakes of one team mention: the mention
  # as a whole is one turn (its wakes share a `:charge` key from the router).
  defp charge(state, text) do
    cond do
      counted?(text) ->
        state

      charged?(state, text) ->
        state

      key = Map.get(text, :charge) ->
        %{state | chatter: state.chatter + 1, charged: MapSet.put(state.charged, key)}

      true ->
        %{state | chatter: state.chatter + 1}
    end
  end

  # A team mention already paid for: its other wakes neither count nor pause.
  defp charged?(state, text) do
    case Map.get(text, :charge) do
      nil -> false
      key -> MapSet.member?(state.charged, key)
    end
  end

  # Read fresh: the user changes the limit while the server runs.
  defp over_spend_limit?(state) do
    case Channels.spend_limit(state.channel.id) do
      limit when is_number(limit) -> Costs.channel_total(state.channel.id) >= limit
      _ -> false
    end
  end

  defp note_spend_limit(state) do
    limit = Channels.spend_limit(state.channel.id)

    if state.limit_noted == limit do
      state
    else
      {:ok, _} =
        Timeline.record(%{
          channel_id: state.channel.id,
          event_type: "spend_limit_reached",
          ref_id: state.channel.id,
          payload: %{"limit" => limit, "spent" => Costs.channel_total(state.channel.id)}
        })

      %{state | limit_noted: limit}
    end
  end

  defp note_hold(state) do
    reason = Canopy.Hold.reason()

    if state.hold_noted == reason do
      state
    else
      {:ok, _} =
        Messages.post_user_note(
          state.channel.id,
          Users.local().id,
          "Agent runs are on hold: #{reason}. Release the hold in the banner, then reply to continue."
        )

      %{state | hold_noted: reason}
    end
  end

  # An agent already working stays shown as busy; its waiting wake follows
  # when that turn ends.
  defp enqueue_waiting(state, target, text) do
    state = %{state | waiting: put_once(state.waiting, target, text)}
    agent_id = target_agent_id(target)

    if agent_id && not agent_busy?(state, agent_id),
      do: broadcast(state, {:agent_status, agent_id, :queued})

    state
  end

  # After a turn ends: if the channel is free, start the next waiting wake.
  # A target waits in a list at most once: a later wake for one already there
  # is merged into its entry, which keeps its place in line.
  defp put_once(list, target, wake) do
    case List.keyfind(list, target, 0) do
      nil -> list ++ [{target, wake}]
      {_, old} -> List.keyreplace(list, target, 0, {target, merge_wake(old, wake)})
    end
  end

  # Two wakes for the same target become one: the newer message is the one to
  # start from, and the agent reads everything new when it wakes, so the text
  # is the newer wake's plus a line saying it stands for more. A delegation
  # carries its task, so a delegation wake keeps its text and the message
  # follows it; two delegation wakes keep both texts, in order, so no task is
  # lost. A lock grant has no text of its own (it is written when the prompt
  # goes out): it rides along on the other wake, and the lock claims of both
  # are handed over. Attachments from both ride along.
  defp merge_wake(old, new) do
    attachments =
      (Map.get(old, :attachments, []) ++ Map.get(new, :attachments, []))
      |> Enum.uniq_by(fn {document, _mode} -> document.id end)

    merged =
      case {Map.get(old, :trigger), Map.get(new, :trigger)} do
        {"lock", _} ->
          new

        {_, "lock"} ->
          old

        # A schedule, a watch, or a playbook wake (a start, an approval, a
        # nudge) carries what it is about in its text, like a delegation: the
        # two texts are kept, in order, and the turn is a channel turn.
        {a, b} when a in @automation_triggers or b in @automation_triggers ->
          new
          |> Map.put(:text, scoped_text(old, nil) <> "\n" <> scoped_text(new, nil))
          |> Map.delete(:channel_text)
          |> Map.delete(:playbook_check)
          |> Map.put(:delegation_ids, delegation_ids(old) ++ delegation_ids(new))

        {"delegation", "delegation"} ->
          old
          |> Map.put(:text, old.text <> "\n" <> new.text)
          |> Map.put(:delegation_ids, delegation_ids(old) ++ delegation_ids(new))

        {"delegation", trigger} when trigger != "delegation" ->
          Map.put(old, :text, old.text <> Prompts.delegation_followup(Map.get(new, :message_id)))

        {trigger, "delegation"} when trigger != "delegation" ->
          Map.put(new, :text, new.text <> Prompts.delegation_followup(Map.get(old, :message_id)))

        _ ->
          Map.put(new, :text, scoped_text(new, merged_thread(old, new)) <> @merged_wake_note)
      end

    sources = Enum.uniq(sources(old) ++ sources(new))
    thread_id = merged_thread(old, new)

    merged
    |> Map.put(:attachments, attachments)
    |> Map.put(:lock_claim_ids, Enum.uniq(lock_claim_ids(old) ++ lock_claim_ids(new)))
    |> Map.put(:sources, sources)
    |> Map.put(:thread_id, thread_id)
    |> scope_merged(thread_id, sources)
  end

  # The messages a wake stands for, as `[{message_id, thread_id | nil}]`.
  defp sources(wake), do: Map.get(wake, :sources, [])

  # The text of the newest wake, without its thread's instructions when the
  # merged wakes do not all share that thread.
  defp scoped_text(wake, nil), do: Map.get(wake, :channel_text, wake.text)
  defp scoped_text(wake, _thread_id), do: wake.text

  # A channel turn standing for messages from more than one place (two
  # threads, or a thread and the channel) lists each and where to answer it.
  # Its text is channel-scoped from here on, for any later merge too.
  defp scope_merged(wake, nil, sources) do
    if Enum.any?(sources, fn {_id, thread_id} -> thread_id end) do
      wake
      |> Map.put(:text, wake.text <> Prompts.mixed_scope(sources))
      |> Map.delete(:channel_text)
    else
      wake
    end
  end

  defp scope_merged(wake, _thread_id, _sources), do: wake

  # The thread a merged wake works for: the one both wakes share, or nil (the
  # channel) when they differ. A lock grant has no scope of its own and takes
  # the other wake's.
  defp merged_thread(%{trigger: "lock"}, new), do: Map.get(new, :thread_id)
  defp merged_thread(old, %{trigger: "lock"}), do: Map.get(old, :thread_id)

  defp merged_thread(old, new) do
    case {Map.get(old, :thread_id), Map.get(new, :thread_id)} do
      {thread_id, thread_id} -> thread_id
      _ -> nil
    end
  end

  defp lock_claim_ids(wake), do: Map.get(wake, :lock_claim_ids, [])

  defp start_next_waiting(%{waiting: []} = state), do: state

  defp start_next_waiting(state) do
    if Canopy.Settings.serialize_turns?(),
      do: start_first_waiting(state),
      else: start_free_waiting(state)
  end

  # One turn at a time: the first in line starts once no turn is running
  # (turns waiting on the user do not count). A wake that cannot start (held,
  # dropped, its session failed, or queued on a session that is waiting on the
  # user) leaves the channel free, so the next in line is tried until one runs.
  defp start_first_waiting(state) do
    case {running_turns(state), state.waiting} do
      {0, [{target, text} | rest]} ->
        %{state | waiting: rest}
        |> wake_within_budget(target, text)
        |> start_next_waiting()

      _ ->
        state
    end
  end

  # Turns actually working: a turn blocked on a card is waiting on the user.
  defp running_turns(state),
    do: Enum.count(state.turns, fn {_sid, turn} -> not awaiting?(turn) end)

  # Turns run side by side: every waiting wake goes out, in order; one for an
  # agent still working queues on its session.
  defp start_free_waiting(state) do
    Enum.reduce(state.waiting, %{state | waiting: []}, fn {target, text}, acc ->
      wake_within_budget(acc, target, text)
    end)
  end

  defp waiting_agent_ids(state), do: Enum.map(state.waiting, fn {t, _} -> target_agent_id(t) end)

  defp target_agent_id({:root, agent_id}), do: agent_id

  defp pause(state, limit, held) do
    {:ok, _} =
      Messages.post_user_note(
        state.channel.id,
        Users.local().id,
        "Paused after #{limit} agent turns without you. Reply to keep going, or press Continue."
      )

    broadcast(state, {:chatter, :paused})
    %{state | paused: held}
  end

  defp resume(%{paused: nil, chatter: 0} = state), do: %{state | charged: MapSet.new()}

  defp resume(state) do
    if is_list(state.paused), do: broadcast(state, {:chatter, :resumed})
    %{state | chatter: 0, charged: MapSet.new(), paused: nil, stopped?: false}
  end

  defp user_action?(%Timeline.Event{
         event_type: "message",
         message: %{agent_id: nil, kind: kind}
       }),
       do: kind != "system"

  defp user_action?(%Timeline.Event{event_type: type, payload: p})
       when type in ["delegation_created", "handoff_requested"],
       do: is_nil(p["from_agent_id"])

  defp user_action?(_event), do: false

  # What a wake is attributed to on the turn summary (the Costs page groups by it).
  # An agent that posts while its own turn is still running may post again
  # before it is done (a heads-up, then the file). Wakes its posts cause wait
  # for the turn to end, so whoever is woken reads everything at once.
  defp posting_agent_mid_turn(
         %Timeline.Event{event_type: "message", message: %{agent_id: agent_id, kind: kind}},
         state
       )
       when is_binary(agent_id) and kind in ["post", "thread_reply"] do
    if agent_busy?(state, agent_id), do: agent_id, else: nil
  end

  defp posting_agent_mid_turn(_event, _state), do: nil

  defp agent_busy?(state, agent_id),
    do: Enum.any?(state.turns, fn {_sid, turn} -> turn.agent_id == agent_id end)

  defp defer_wakes(state, _agent_id, [], _message), do: state

  defp defer_wakes(state, agent_id, wakes, message) do
    entries = Enum.map(wakes, fn {target, wake} -> {target, wake, message} end)
    %{state | deferred: Map.update(state.deferred, agent_id, entries, &(&1 ++ entries))}
  end

  # Releases the wakes an agent's posts caused during its turn: one wake per
  # target, built from the last post, carrying every attachment and a note
  # about the earlier posts.
  defp release_deferred(state, agent_id) do
    entries = Map.get(state.deferred, agent_id, [])

    cond do
      entries == [] ->
        state

      # the agent's session is compacting: the wakes go out once that ends
      agent_busy?(state, agent_id) ->
        state

      true ->
        state = %{state | deferred: Map.delete(state.deferred, agent_id)}

        entries
        |> Enum.group_by(fn {target, _, _} -> target end)
        |> Enum.sort_by(fn {_target, [{_, _, first} | _]} -> first.id end)
        |> Enum.reduce(state, fn {target, group}, acc ->
          wake_within_budget(acc, target, merge_wakes(group))
        end)
    end
  end

  defp merge_wakes([{_target, wake, _message}]), do: wake

  defp merge_wakes(group) do
    {_, last, _} = List.last(group)
    earlier = group |> Enum.drop(-1) |> Enum.map(fn {_, _, message} -> message end)

    documents =
      group
      |> Enum.flat_map(fn {_, _, message} -> List.wrap(Map.get(message, :documents)) end)
      |> Enum.reject(&(&1 == %Ecto.Association.NotLoaded{}))
      |> Enum.uniq_by(& &1.id)

    plan = Canopy.Documents.prompt_plan(documents)

    threads = group |> Enum.map(fn {_, wake, _} -> Map.get(wake, :thread_id) end) |> Enum.uniq()
    thread_id = if match?([_], threads), do: hd(threads)
    sources = group |> Enum.flat_map(fn {_, wake, _} -> sources(wake) end) |> Enum.uniq()
    text = scoped_text(last, thread_id)

    last
    |> Map.put(:text, text <> Prompts.earlier_posts(earlier, plan))
    |> Map.put(:attachments, plan)
    |> Map.put(:sources, sources)
    |> Map.put(:thread_id, thread_id)
    |> scope_merged(thread_id, sources)
  end

  # The router hands back plain text, or a map with the attachments plan when
  # the message carried files.
  defp wake_message(text, trigger) when is_binary(text), do: %{text: text, trigger: trigger}
  defp wake_message(%{text: _} = wake, trigger), do: Map.put(wake, :trigger, trigger)

  # A message wake remembers its message, so a merge can point at it, and the
  # thread it is in (its root, nil outside a thread), so the turn works there.
  defp put_message_id(wake, %Timeline.Event{event_type: "message", message: %{id: id} = m}) do
    thread_id = Map.get(m, :thread_id)

    wake
    |> Map.put(:message_id, id)
    |> Map.put(:thread_id, thread_id)
    |> Map.put(:sources, [{id, thread_id}])
  end

  defp put_message_id(wake, _event), do: wake

  # A delegation wake remembers its delegation, so the turn it starts is
  # attributed to it and the delegation is marked working when it goes out.
  defp put_delegation(wake, %Timeline.Event{event_type: "delegation_created", ref_id: id}),
    do: Map.put(wake, :delegation_ids, [id])

  defp put_delegation(wake, _event), do: wake

  defp delegation_ids(wake), do: Map.get(wake, :delegation_ids, [])

  defp trigger_of(%Timeline.Event{event_type: "message", message: %{agent_id: nil}}), do: "user"
  defp trigger_of(%Timeline.Event{event_type: "message"}), do: "agent"
  defp trigger_of(%Timeline.Event{event_type: "delegation_" <> _}), do: "delegation"
  defp trigger_of(%Timeline.Event{event_type: "handoff_" <> _}), do: "handoff"
  defp trigger_of(_event), do: "other"

  defp do_wake(state, {:root, agent_id}, text) do
    case ensure_root_session(state, agent_id) do
      {:ok, session, state} ->
        prompt(state, session, agent_id, text)

      {:error, reason, state} ->
        record_error(state, agent_id, "could not start session: #{inspect(reason)}")
    end
  end

  defp prompt(state, session, agent_id, text) do
    sid = session.engine_session_id

    if Map.has_key?(state.turns, sid) do
      queue =
        case Map.get(state.queues, sid, []) do
          [] -> [text]
          [old | _] -> [merge_wake(old, text)]
        end

      %{state | queues: Map.put(state.queues, sid, queue)}
    else
      send_prompt(state, session, agent_id, text)
    end
  end

  defp send_prompt(state, session, agent_id, %{playbook_check: check} = wake) do
    if Canopy.Playbooks.Runs.nudge_current?(check) do
      send_prompt(state, session, agent_id, Map.delete(wake, :playbook_check))
    else
      Logger.info(
        "channel #{state.channel.name}: dropped a stall nudge for #{agent_name(agent_id)}: the run moved on"
      )

      unless agent_busy?(state, agent_id),
        do: broadcast(state, {:agent_status, agent_id, :idle})

      state
    end
  end

  defp send_prompt(state, session, agent_id, wake) do
    case lock_grants(session, wake) do
      :drop ->
        Logger.info(
          "channel #{state.channel.name}: dropped a lock wake for #{agent_name(agent_id)}: the lock passed on before it could start"
        )

        unless agent_busy?(state, agent_id),
          do: broadcast(state, {:agent_status, agent_id, :idle})

        state

      {lock_text, claim_ids} ->
        send_prompt(state, session, agent_id, wake, lock_text, claim_ids)
    end
  end

  defp send_prompt(
         state,
         session,
         agent_id,
         %{text: text, trigger: trigger} = wake,
         locks,
         claims
       ) do
    agent = Agents.get!(agent_id)
    Canopy.Notes.ensure_workspace(state.repository.path)
    {mod, es, state} = engine_of(state, session)
    es = mod.prepare(ctx(state), es)
    state = put_engine_state(state, mod, es)
    plan = materialize_attachments(state, Map.get(wake, :attachments, []))
    ids = delegation_ids(wake)
    # before the prompt: a quick delegate may report back before it returns
    start_delegations(ids, session)

    prompt = %{
      text:
        text <>
          locks <> pending_delegations(state, agent_id, ids) <> playbook_note(state, agent_id),
      system: Prompts.system(agent, state.channel, state.repository, Repositories.list()),
      attachments: plan
    }

    case mod.send_prompt(ctx(state), es, session, agent, prompt) do
      {:ok, %{attachments: attachments}} ->
        begin_turn(state, session, agent_id, trigger, attachments,
          delegation_ids: ids,
          lock_claim_ids: claims,
          thread_id: Map.get(wake, :thread_id)
        )

      {:error, reason} ->
        record_error(state, agent_id, "prompt failed: #{inspect(reason)}")
    end
  end

  # The delegations a wake carries are worked on in the delegate's session from
  # now on; one already working (or finished) is left as it is.
  defp start_delegations(ids, session) do
    Enum.each(ids, fn id ->
      case Delegations.get(id) do
        %{status: "requested"} = delegation ->
          {:ok, _} = Delegations.start(delegation, session.id)

        _ ->
          :ok
      end
    end)
  end

  # Every prompt reminds the agent of the delegations it still has open in
  # the channel, read when the prompt goes out so a wake that waited is
  # current; the ones this wake hands over are already spelled out in it.
  defp pending_delegations(state, agent_id, except) do
    pending =
      state.channel.id
      |> Delegations.list_pending_for(agent_id)
      |> Enum.reject(&(&1.id in except))
      |> Enum.map(fn d ->
        from = if d.from_agent, do: "@" <> d.from_agent.name, else: Users.local().display_name
        %{id: d.id, description: d.description, from: from}
      end)

    Prompts.pending_delegations(state.channel.name, pending)
  end

  # The coordinator of the channel's playbook run is told where it stands on
  # every prompt, read when the prompt goes out, so the run survives
  # compaction; nobody else is.
  defp playbook_note(state, agent_id) do
    Canopy.Playbooks.Runs.prompt_note(state.channel.id, agent_id) || ""
  end

  # A wake for a lock the session was granted from the line hands it over,
  # read when the prompt goes out: a claim that passed on meanwhile (the
  # lease, a Force release, used and released by an earlier turn) is left
  # out, and a wake that was only the grant is dropped when nothing is left.
  # Returns the text to add and the claims the turn takes over.
  defp lock_grants(session, wake) do
    case lock_claim_ids(wake) do
      [] ->
        {"", []}

      ids ->
        lock? = Map.get(wake, :trigger) == "lock"

        case Locks.pending_grants(session.id, ids) do
          [] when lock? -> :drop
          [] -> {"", []}
          claims -> {Prompts.lock_granted(claims, standalone?: lock?), Enum.map(claims, & &1.id)}
        end
    end
  end

  # The engine accepted a prompt: the session is busy until it reports done.
  # Options: `delegation_ids`, the delegations the wake handed over;
  # `lock_claim_ids`, the granted locks the turn now owns; `thread_id`, the
  # thread the turn works for (nil: the channel).
  defp begin_turn(state, session, agent_id, trigger, attachments, opts \\ []) do
    delegation_ids = Keyword.get(opts, :delegation_ids, [])
    lock_claim_ids = Keyword.get(opts, :lock_claim_ids, [])
    thread_id = Keyword.get(opts, :thread_id)
    ref = Canopy.ID.generate("turn")
    :ok = Locks.stamp_turn(session.id, lock_claim_ids, ref)
    # a coordinator at work is playbook activity; the turn a stall nudge
    # starts is not, or every nudge would clear itself
    if trigger != "playbook_nudge",
      do: Canopy.Playbooks.Runs.note_coordinator_turn(state.channel.id, agent_id)

    {:ok, _} = AgentSessions.set_status(session, "busy")
    broadcast(state, {:agent_status, agent_id, :busy})
    broadcast_turn_thread(state, agent_id, thread_id)

    {:ok, _} =
      Timeline.record(
        Map.merge(
          %{
            channel_id: state.channel.id,
            agent_id: agent_id,
            event_type: "agent_started",
            ref_id: session.id,
            payload: %{"engine_session_id" => session.engine_session_id, "thread_id" => thread_id}
          },
          thread_scope(thread_id)
        )
      )

    turn = %{
      # owns the lock claims taken or handed over during the turn
      ref: ref,
      agent_id: agent_id,
      session: session,
      started_at: System.monotonic_time(:millisecond),
      # bumped by every engine event for this session; the watchdog uses
      # it to tell a working turn from one nothing will ever finish
      last_event_at: System.monotonic_time(:millisecond),
      texts: [],
      tools: 0,
      files: MapSet.new(),
      cost: 0.0,
      passed: nil,
      # set once the agent posts through Canopy tools during this turn
      posted?: false,
      # %{since, message, attempt} while the engine is retrying a failing
      # model call; cleared when the call goes through
      retrying: nil,
      # context of the largest model call (input + cached input tokens)
      context: 0,
      # model calls, and their tokens summed
      steps: 0,
      tokens: %{},
      trigger: trigger,
      # the thread the turn works for, nil for the channel
      thread_id: thread_id,
      delegation_ids: delegation_ids,
      # documents sent along in the prompt; they stay in the session's context
      attachments: attachments,
      # the messages the agent posted during the turn (its fallback reply too)
      message_ids: []
    }

    {model, _source} = turn_model(agent_id)
    card = Map.put(Activity.new(System.system_time(:millisecond)), :model, model)

    %{
      state
      | turns: Map.put(state.turns, session.engine_session_id, turn),
        telemetry: Map.put(state.telemetry, agent_id, card)
    }
  end

  # Every attachment is materialised under the repository's .canopy/files/ so
  # the agent can read it; the plan then tells the engine which ones ride along.
  defp materialize_attachments(state, plan) do
    Enum.each(plan, fn {document, _mode} ->
      case Canopy.Documents.materialize(document, state.repository.path) do
        {:ok, _path} ->
          :ok

        {:error, reason} ->
          Logger.warning("could not materialise #{document.id}: #{inspect(reason)}")
      end
    end)

    plan
  end

  # -- Locks ------------------------------------------------------------------

  # The lease is a backstop: a pass that fails is tried again on the next tick.
  defp expire_locks(state) do
    Locks.expire(channel_id: state.channel.id, active_session_ids: active_session_ids(state))
    state
  rescue
    e ->
      Logger.warning("channel #{state.channel.name}: lock lease failed: #{Exception.message(e)}")
      state
  end

  # A lock passed to a session of this channel: that session is woken like any
  # other wake (holds, spend limit, chatter budget, serialize_turns; queued
  # behind its own turn when busy). The wake carries only the claim; its text
  # is written when the prompt goes out. A user's claim wakes nobody.
  defp wake_grant(state, %Locks.Claim{session_id: session_id, id: claim_id})
       when is_binary(session_id) do
    session =
      session_for_id(state, session_id) ||
        Enum.find(
          AgentSessions.list_for_channel(state.channel.id),
          &(&1.id == session_id and is_nil(&1.parent_session_id))
        )

    case session do
      nil ->
        state

      session ->
        state
        |> put_root(session)
        |> wake_within_budget(
          {:root, session.agent_id},
          %{text: "", trigger: "lock", lock_claim_ids: [claim_id]}
        )
    end
  end

  defp wake_grant(state, _claim), do: state

  defp stale_grant?(state, target, %{trigger: "lock"} = wake) do
    case Map.get(state.sessions, target_agent_id(target)) do
      nil -> false
      session -> Locks.pending_grants(session.id, lock_claim_ids(wake)) == []
    end
  end

  defp stale_grant?(_state, _target, _wake), do: false

  # Sessions that are working, or have a wake on its way (queued behind their
  # turn, or in the channel's line): a lock granted to one of them is about to
  # be used. A wake held by the chatter budget is not on its way; the user is
  # away, and the lease passes such a lock on.
  defp active_session_ids(state) do
    working = Enum.map(state.turns, fn {_sid, turn} -> turn.session.id end)

    queued =
      for {sid, [_ | _]} <- state.queues,
          %{agent_id: agent_id} <- [Map.get(state.index, sid)],
          %{} = session <- [Map.get(state.sessions, agent_id)],
          do: session.id

    waiting =
      for {target, _wake} <- state.waiting,
          %{} = session <- [Map.get(state.sessions, target_agent_id(target))],
          do: session.id

    Enum.uniq(working ++ queued ++ waiting)
  end

  # -- Sessions ---------------------------------------------------------------

  defp ensure_root_session(state, agent_id) do
    case Map.get(state.sessions, agent_id) || AgentSessions.get_root(state.channel.id, agent_id) do
      %AgentSessions.AgentSession{} = session ->
        {:ok, session, put_root(state, session)}

      nil ->
        agent = Agents.get!(agent_id)
        title = "##{state.channel.name} · @#{agent.name}"
        {mod, es, state} = engine_of(state, agent)

        with {:ok, attrs} <- mod.create_session(ctx(state), es, agent, title: title),
             {:ok, session} <-
               AgentSessions.create(
                 Map.merge(attrs, %{
                   channel_id: state.channel.id,
                   agent_id: agent_id,
                   engine: agent.engine
                 })
               ) do
          {:ok, session, put_root(state, session)}
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp put_root(state, session) do
    state = subscribe_once(state, session)

    %{
      state
      | sessions: Map.put(state.sessions, session.agent_id, session),
        index: Map.put(state.index, session.engine_session_id, %{agent_id: session.agent_id})
    }
  end

  defp subscribe_once(state, session) do
    {mod, _es, state} = engine_of(state, session)

    unless Map.has_key?(state.index, session.engine_session_id) do
      :ok = mod.subscribe(session)
    end

    state
  end

  # -- Engines ----------------------------------------------------------------

  defp ctx(state), do: %{repository: state.repository, channel: state.channel}

  # Every member's engine is attached up front so event sources are connected
  # before the first prompt; anything else attaches on first use.
  defp attach_engines(state) do
    state.channel
    |> Channels.members()
    |> Enum.reduce(state, fn agent, acc -> ensure_engine(acc, Engine.for(agent)) end)
  end

  defp ensure_engine(state, mod) do
    if Map.has_key?(state.engines, mod),
      do: state,
      else: put_engine_state(state, mod, mod.attach(ctx(state), state.engine_opts))
  end

  # The adapter and its state for an agent or session, attaching it if needed.
  defp engine_of(state, %{engine: _} = agent_or_session) do
    mod = Engine.for(agent_or_session)
    state = ensure_engine(state, mod)
    {mod, Map.fetch!(state.engines, mod), state}
  end

  # A permission or question request belongs to the session it was recorded
  # for; one recorded without a session goes to the channel's only engine.
  defp engine_for_request(state, %{agent_session_id: id}) when is_binary(id) do
    case session_for_id(state, id) do
      nil -> engine_of(state, AgentSessions.get!(id))
      session -> engine_of(state, session)
    end
  end

  defp engine_for_request(state, _request) do
    case Map.keys(state.engines) do
      [mod] -> {mod, Map.fetch!(state.engines, mod), state}
      _ -> engine_of(state, %{engine: "opencode"})
    end
  end

  defp engine_for_session(state, nil), do: engine_for_request(state, %{})
  defp engine_for_session(state, session), do: engine_of(state, session)

  defp put_engine_state(state, mod, es), do: %{state | engines: Map.put(state.engines, mod, es)}

  defp invalidate_engines(state, reason) do
    engines = Map.new(state.engines, fn {mod, es} -> {mod, mod.invalidate(es, reason)} end)
    %{state | engines: engines}
  end

  # -- Execution events -------------------------------------------------------

  @activity_types [
    :tool_started,
    :tool_completed,
    :file_changed,
    :step_completed,
    :patch,
    :diff,
    :text_delta,
    :text_done
  ]

  # An engine keeps emitting for a session after it reports idle (OpenCode's
  # session.diff, late part updates). Activity outside a turn must not reopen
  # the working card, so it is dropped.
  defp handle_execution(%{type: type, session_id: sid}, _who, %{turns: turns} = state)
       when type in @activity_types and not is_map_key(turns, sid),
       do: state

  # session.diff is empty on every capture so far; an empty diff says nothing.
  defp handle_execution(%{type: :diff, data: %{files: []}}, _who, state), do: state

  defp handle_execution(%{type: type} = event, %{agent_id: agent_id}, state)
       when type in [
              :tool_started,
              :tool_completed,
              :file_changed,
              :step_completed,
              :patch,
              :diff
            ] do
    state = fold_activity(state, agent_id, event)
    update_turn(state, event.session_id, fn turn -> turn_stats(turn, event) end)
  end

  # Streamed text goes to the views only; the finished part replaces it.
  defp handle_execution(%{type: :text_delta} = event, %{agent_id: agent_id}, state) do
    broadcast(state, {:telemetry, agent_id, stamp(event)})
    state
  end

  defp handle_execution(
         %{type: :text_done, data: %{text: text}} = event,
         %{agent_id: agent_id},
         state
       ) do
    # kept with the tool rows so the finished card shows the narration in place
    state = fold_activity(state, agent_id, event)
    update_turn(state, event.session_id, fn turn -> %{turn | texts: [text | turn.texts]} end)
  end

  defp handle_execution(%{type: :turn_usage, data: %{cost: cost}} = event, _who, state)
       when is_number(cost) do
    update_turn(state, event.session_id, fn turn -> %{turn | cost: turn.cost + cost} end)
  end

  # A permission or question prompt holds the agent's tool call open until
  # someone answers it, so the turn stays in flight, marked as awaiting the
  # user; the card in the feed is the only way to release it. A replayed
  # prompt (the engine still lists it) brings back a card resolved or
  # detached here; one already showing is not announced again. A prompt that cannot be recorded would block with no card,
  # so the engine is told to reject it at once.
  defp handle_execution(
         %{type: :approval_required, data: %{request: req}} = event,
         %{agent_id: agent_id},
         state
       ) do
    session = session_for(state, event.session_id)

    attrs = %{
      channel_id: state.channel.id,
      agent_session_id: session && session.id,
      opencode_permission_id: req["id"],
      permission: req["permission"],
      patterns: req["patterns"] || [],
      metadata: req["metadata"] || %{},
      tool_call_id: get_in(req, ["tool", "callID"]),
      status: "pending"
    }

    known? = attached?(PermissionRequests.get_by_opencode_id(req["id"] || ""))

    case PermissionRequests.record(attrs, reopen: replay?(event)) do
      {:ok, request} ->
        unless known?, do: broadcast(state, {:telemetry, agent_id, event})
        mark_awaiting(state, event.session_id, request)

      {:error, error} ->
        Logger.warning(
          "channel #{state.channel.name}: could not record permission #{inspect(req["id"])}, rejecting it: #{inspect(error)}"
        )

        request = %PermissionRequest{
          opencode_permission_id: req["id"],
          permission: req["permission"],
          agent_session: session
        }

        {mod, es, state} = engine_for_session(state, session)
        _ = mod.reply_permission(ctx(state), es, request, :reject)
        state
    end
  end

  defp handle_execution(
         %{type: :approval_resolved, data: %{request_id: rid, reply: reply}},
         _who,
         state
       ) do
    case PermissionRequests.get_by_opencode_id(rid) do
      %{status: "pending"} = request ->
        {:ok, _} = PermissionRequests.resolve(request, reply_atom(reply))
        clear_awaiting(state, request)

      _ ->
        state
    end
  end

  defp handle_execution(
         %{type: :question_required, data: %{request: req}} = event,
         %{agent_id: agent_id},
         state
       ) do
    session = session_for(state, event.session_id)

    attrs = %{
      channel_id: state.channel.id,
      agent_session_id: session && session.id,
      opencode_question_id: req["id"],
      questions: req["questions"] || [],
      tool_call_id: get_in(req, ["tool", "callID"]),
      status: "pending"
    }

    known? = attached?(QuestionRequests.get_by_opencode_id(req["id"] || ""))

    case QuestionRequests.record(attrs, reopen: replay?(event)) do
      {:ok, request} ->
        unless known?, do: broadcast(state, {:telemetry, agent_id, event})
        mark_awaiting(state, event.session_id, request)

      {:error, error} ->
        Logger.warning(
          "channel #{state.channel.name}: could not record question #{inspect(req["id"])}, rejecting it: #{inspect(error)}"
        )

        request = %QuestionRequest{
          opencode_question_id: req["id"],
          questions: req["questions"] || [],
          agent_session: session
        }

        {mod, es, state} = engine_for_session(state, session)
        _ = mod.reply_question(ctx(state), es, request, :rejected)
        state
    end
  end

  defp handle_execution(
         %{type: :question_resolved, data: %{request_id: rid} = data},
         _who,
         state
       ),
       do:
         resolve_question(state, rid, {:answered, normalize_answers(Map.get(data, :answers, []))})

  defp handle_execution(%{type: :question_rejected, data: %{request_id: rid}}, _who, state),
    do: resolve_question(state, rid, :rejected)

  # The engine stopped waiting (Claude Code's question wait ran out, or a
  # prompt's timeout): the agent moves on and the card is detached.
  defp handle_execution(%{type: :question_expired, data: %{request_id: rid}}, _who, state) do
    case QuestionRequests.get_by_opencode_id(rid) do
      %{status: "pending"} = request ->
        {:ok, request} = QuestionRequests.detach(request)
        clear_awaiting(state, request)

      _ ->
        state
    end
  end

  defp handle_execution(%{type: :approval_expired, data: %{request_id: rid}}, _who, state) do
    case PermissionRequests.get_by_opencode_id(rid) do
      %{status: "pending"} = request ->
        {:ok, request} = PermissionRequests.detach(request)
        clear_awaiting(state, request)

      _ ->
        state
    end
  end

  defp handle_execution(%{type: :agent_status, data: %{status: :busy}}, _who, state), do: state

  # The engine's model call failed and it is backing off before trying again.
  # Remembered on the turn, so the watchdog can tell a long retry loop from
  # one that just started; the first notice fixes when it began, and any other
  # event for the session (the call went through) clears it, in touch_turn/3.
  defp handle_execution(
         %{type: :agent_status, data: %{status: :retry} = data} = event,
         _who,
         state
       ) do
    raw = Map.get(data, :raw, %{})

    update_turn(state, event.session_id, fn turn ->
      since =
        case Map.get(turn, :retrying) do
          %{since: since} -> since
          _ -> System.monotonic_time(:millisecond)
        end

      Map.put(turn, :retrying, %{
        since: since,
        message: raw["message"],
        attempt: raw["attempt"]
      })
    end)
  end

  defp handle_execution(%{type: :agent_completed} = event, who, state),
    do: finish_turn(state, event.session_id, who, :ok)

  # OpenCode can emit session.error several times for one failure (with and
  # without a stack trace). Only the first one, while a turn is in flight, is recorded.
  defp handle_execution(%{type: :agent_error, session_id: sid}, _who, %{turns: turns} = state)
       when not is_map_key(turns, sid),
       do: state

  defp handle_execution(%{type: :agent_error, data: %{error: error}} = event, who, state) do
    if Map.get(state.turns[event.session_id], :stopped?) do
      # the engine's report of an abort the user asked for is not an error
      finish_turn(state, event.session_id, who, :stopped)
    else
      record_agent_error(state, event, who, error_message(error))
    end
  end

  # What the session loaded this turn (Claude Code's init), kept for the
  # repository page.
  defp handle_execution(%{type: :mcp_servers, data: %{servers: servers}} = event, _who, state) do
    case session_for(state, event.session_id) do
      nil -> :ok
      session -> AgentSessions.record_mcp_servers(session, servers)
    end

    state
  end

  defp handle_execution(_event, _who, state), do: state

  defp record_agent_error(state, event, who, reason) do
    if Canopy.Hold.billing_error?(reason), do: Canopy.Hold.engage(reason)
    thread_id = state.turns |> Map.get(event.session_id, %{}) |> Map.get(:thread_id)

    {:ok, _} =
      Timeline.record(
        Map.merge(
          %{
            channel_id: state.channel.id,
            agent_id: who.agent_id,
            event_type: "agent_error",
            payload: %{"reason" => reason}
          },
          thread_scope(thread_id)
        )
      )

    finish_turn(state, event.session_id, who, {:error, reason})
  end

  defp finish_turn(state, sid, who, outcome) do
    case Map.pop(state.turns, sid) do
      {nil, _} ->
        state

      {turn, turns} ->
        state = %{state | turns: turns}
        # the user's Abort, however the engine reported it
        outcome = if Map.get(turn, :stopped?), do: :stopped, else: outcome
        detach_prompts(turn.session)
        # reload: the struct captured at prompt time still says "idle", so a
        # changeset built from it would see no change
        session = AgentSessions.get!(turn.session.id)

        {:ok, _} =
          case outcome do
            # the user stopped it: nothing went wrong, the session is idle
            ok when ok in [:ok, :stopped] -> AgentSessions.set_status(session, "idle")
            {:error, reason} -> AgentSessions.set_status(session, "error", reason)
          end

        # The summary goes in before the reply so its activity card sits above
        # the message, where the live card was while the agent worked. The
        # reply's id is chosen first, so the summary can name it.
        card =
          (Map.get(state.telemetry, who.agent_id) || Activity.new())
          |> Activity.drop_trailing_text()

        reply_id = if reply_text(turn), do: Canopy.ID.generate("msg")
        message_ids = Enum.reverse(Map.get(turn, :message_ids, [])) ++ List.wrap(reply_id)

        {model, model_source} = turn_model(who.agent_id)
        thread_id = Map.get(turn, :thread_id)

        # The rows' details go in with the summary, so a view that opens a
        # row as soon as the card arrives finds them.
        summary_attrs = %{
          channel_id: state.channel.id,
          agent_id: who.agent_id,
          event_type: "agent_turn_completed",
          ref_id: session.id,
          thread_id: thread_id,
          in_channel: is_nil(thread_id),
          payload: %{
            "tools" => turn.tools,
            "files" => MapSet.to_list(turn.files),
            "cost" => turn.cost,
            "duration_ms" => System.monotonic_time(:millisecond) - turn.started_at,
            "outcome" => outcome_label(outcome),
            "model" => model,
            "model_source" => model_source,
            # the delegations the turn was woken for: the first, and all
            "delegation_id" => List.first(Map.get(turn, :delegation_ids, [])),
            "delegation_ids" => Map.get(turn, :delegation_ids, []),
            "activity" => Activity.to_payload(card),
            "activity_meta" => Activity.meta_payload(card),
            # what the turn posted, so a reply can link back to its activity
            "message_ids" => message_ids,
            "passed" => is_binary(turn.passed),
            "note" => turn.passed,
            "trigger" => turn.trigger,
            "thread_id" => thread_id,
            "attachments" => Map.get(turn, :attachments, 0),
            "steps" => turn.steps,
            "context" => turn.context,
            "tokens" => turn.tokens,
            "final_text" => if(turn.posted?, do: final_text(turn))
          }
        }

        {:ok, %{summary: summary}} =
          Ecto.Multi.new()
          |> Timeline.multi_record(:summary, summary_attrs)
          |> Ecto.Multi.run(:details, fn _repo, %{summary: summary} ->
            case Activity.details_payload(card) do
              details when map_size(details) == 0 -> {:ok, nil}
              details -> ActivityDetails.put(summary.id, details)
            end
          end)
          |> Canopy.Repo.transaction()

        Timeline.broadcast(summary)

        # The final text is the reply only when the agent said nothing through
        # the tools; after a message_send it is a recap, kept on the card.
        if reply_id, do: post_reply(state, turn, who, reply_id)

        # Whatever the turn held is free now, however it ended; a waiter that
        # gets a lock is woken through {:lock_granted, _}, after this.
        Locks.release_turn(session.id, Map.get(turn, :ref))
        if awaiting?(turn), do: Locks.touch(state.repository.id, session.id)

        broadcast(state, {:agent_status, who.agent_id, status_after_turn(state, who, outcome)})
        broadcast_turn_thread(state, who.agent_id, nil)

        state = %{state | telemetry: Map.delete(state.telemetry, who.agent_id)}
        state = if outcome == :ok, do: maybe_compact(state, session, turn, who), else: state

        state = release_deferred(state, who.agent_id)

        cond do
          state.pending_switch? ->
            state = apply_switch(state)
            if state.pending_switch?, do: state, else: start_next_waiting(state)

          # compaction runs as a turn of its own: the queue drains after it
          Map.has_key?(state.turns, sid) ->
            state

          true ->
            state |> drain_queue(session, who.agent_id) |> start_next_waiting()
        end
    end
  end

  # A wake for the agent waiting in line shows it queued rather than idle
  # until it starts.
  defp status_after_turn(_state, _who, {:error, _}), do: :error

  defp status_after_turn(state, who, _outcome) do
    cond do
      agent_busy?(state, who.agent_id) -> turn_status(state, who.agent_id)
      who.agent_id in waiting_agent_ids(state) -> :queued
      true -> :idle
    end
  end

  # The status of an agent with a turn in flight: waiting on the user when
  # any of its turns is blocked on a card.
  defp turn_status(state, agent_id) do
    if Enum.any?(state.turns, fn {_sid, t} -> t.agent_id == agent_id and awaiting?(t) end),
      do: :awaiting_user,
      else: :busy
  end

  defp outcome_label(:ok), do: "ok"
  defp outcome_label(:stopped), do: "stopped"
  defp outcome_label({:error, _}), do: "error"

  # The DM now works in another repository. Once nothing is in flight, forget
  # every session (they belong to the old directory), reload the channel, and
  # follow the new repository's event stream; the next wake starts fresh there.
  defp apply_switch(%{turns: turns} = state) when map_size(turns) > 0, do: state

  defp apply_switch(state) do
    Enum.each(AgentSessions.list_for_channel(state.channel.id), &AgentSessions.delete/1)
    channel = Channels.get!(state.channel.id)
    repository = Repositories.get!(channel.repository_id)
    :ok = Engine.subscribe_repository(repository.id)
    :ok = Locks.unsubscribe(state.repository.id)
    :ok = Locks.subscribe(repository.id)

    attach_engines(%{
      state
      | channel: channel,
        repository: repository,
        sessions: %{},
        index: %{},
        queues: %{},
        telemetry: %{},
        engines: %{},
        pending_switch?: false
    })
  end

  # A message the agent posted itself (post or thread reply) while its turn is
  # in flight marks that turn, so the closing text is not posted a second time.
  defp note_agent_post(
         %Timeline.Event{
           event_type: "message",
           message: %{id: message_id, agent_id: agent_id, kind: kind}
         },
         state
       )
       when is_binary(agent_id) and kind in ["post", "thread_reply"] do
    turns =
      Map.new(state.turns, fn
        {sid, %{agent_id: ^agent_id} = turn} ->
          {sid,
           turn
           |> Map.put(:posted?, true)
           |> Map.update(:message_ids, [message_id], &[message_id | &1])}

        other ->
          other
      end)

    %{state | turns: turns}
  end

  defp note_agent_post(_event, state), do: state

  defp final_text(%{texts: [last | _]}) when is_binary(last) do
    case String.trim(last) do
      "" -> nil
      text -> text
    end
  end

  defp final_text(_turn), do: nil

  # The last text part of the turn is the agent's reply, unless it passed or
  # already posted through the tools; earlier parts are narration.
  defp reply_text(%{passed: nil, posted?: false} = turn), do: final_text(turn)
  defp reply_text(_turn), do: nil

  # A turn working for a thread answers in that thread.
  defp post_reply(state, turn, who, id) do
    text = reply_text(turn)

    case Map.get(turn, :thread_id) do
      nil ->
        {:ok, _} = Messages.post_agent_reply(state.channel.id, who.agent_id, text, id: id)

      thread_id ->
        {:ok, _} =
          Messages.thread_reply(thread_id, {:agent, who.agent_id}, text, kind: "reply", id: id)
    end
  end

  # The engine's label for the model the agent runs on, and whether that is the
  # agent's own choice, its engine's default from Settings, or the engine's pick.
  defp turn_model(agent_id) do
    case Agents.get(agent_id) do
      nil ->
        {"unknown", nil}

      agent ->
        {Engine.for(agent).model_label(agent),
         Atom.to_string(Agents.effective_model(agent).source)}
    end
  end

  # The wake that queued on the session while its turn ran. Under
  # serialize_turns, with another turn running (one that started while this
  # turn waited on the user), it joins the line instead of starting beside it;
  # it was already counted against the chatter budget when it queued.
  defp drain_queue(state, session, agent_id) do
    sid = session.engine_session_id

    case Map.get(state.queues, sid, []) do
      [] ->
        state

      [next | rest] ->
        state = %{state | queues: Map.put(state.queues, sid, rest)}

        if Canopy.Settings.serialize_turns?() and running_turns(state) > 0,
          do: enqueue_waiting(state, {:root, agent_id}, counted(next)),
          else: send_prompt(state, session, agent_id, next)
    end
  end

  # A wake already counted against the chatter budget: it neither counts again
  # nor pauses the channel when it finally starts.
  defp counted(wake), do: Map.put(wake, :counted?, true)
  defp counted?(wake), do: Map.get(wake, :counted?, false)

  defp turn_stats(turn, %{type: :tool_completed}), do: %{turn | tools: turn.tools + 1}

  # Notes are memory, not work: edits under .canopy/ do not count as changed files.
  defp turn_stats(turn, %{type: :file_changed, data: %{path: path}}) do
    if String.contains?(path, "/.canopy/"),
      do: turn,
      else: %{turn | files: MapSet.put(turn.files, path)}
  end

  # Each step is one model call; keep the largest context it carried and sum
  # the tokens, the way the provider bills them.
  defp turn_stats(turn, %{type: :step_completed, data: %{tokens: tokens}}) when is_map(tokens) do
    context = number(tokens["input"]) + number(get_in(tokens, ["cache", "read"]))

    step = %{
      "input" => number(tokens["input"]),
      "output" => number(tokens["output"]),
      "reasoning" => number(tokens["reasoning"]),
      "cache_read" => number(get_in(tokens, ["cache", "read"])),
      "cache_write" => number(get_in(tokens, ["cache", "write"]))
    }

    %{
      turn
      | context: max(turn.context, context),
        steps: turn.steps + 1,
        tokens: Map.merge(turn.tokens, step, fn _k, a, b -> a + b end)
    }
  end

  defp turn_stats(turn, _), do: turn

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0

  @doc "The default context cap (tokens per model call); engines may set their own."
  def context_cap, do: Application.get_env(:canopy, :context_cap, 40_000)

  # A session that has grown past the cap gets compacted by its engine: its
  # history becomes a summary, so the next turn starts small. Memory and the
  # channel tools carry everything else. Best effort: a failure is logged.
  defp maybe_compact(state, session, %{context: context}, who) when context > 0 do
    {mod, es, state} = engine_of(state, session)
    cap = mod.context_cap()

    if context > cap do
      record = fn ->
        {:ok, _} =
          Timeline.record(%{
            channel_id: state.channel.id,
            agent_id: who.agent_id,
            event_type: "session_compacted",
            ref_id: session.id,
            payload: %{"context" => context, "cap" => cap}
          })
      end

      case mod.compact(ctx(state), es, session, Agents.get!(who.agent_id)) do
        :ok ->
          record.()
          state

        # The engine compacts by running a turn: track it so its events and
        # cost land, and so nothing else is sent until it ends.
        {:ok, :turn} ->
          record.()
          begin_turn(state, session, who.agent_id, "compact", 0)

        {:error, :no_model} ->
          Logger.warning("no model to compact #{session.engine_session_id} with")
          state

        {:error, reason} ->
          Logger.warning("compaction failed for #{session.engine_session_id}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp maybe_compact(state, _session, _turn, _who), do: state

  # Map.put, not %{turn | ...}: a turn started before this field existed (a dev
  # code reload mid-turn) would otherwise crash the server. A retry notice is
  # not progress: it keeps the retry clock running; anything else stops it.
  defp touch_turn(state, sid, %Event{type: :agent_status, data: %{status: :retry}}),
    do: update_turn(state, sid, &Map.put(&1, :last_event_at, System.monotonic_time(:millisecond)))

  defp touch_turn(state, sid, _event) do
    update_turn(state, sid, fn turn ->
      turn
      |> Map.put(:last_event_at, System.monotonic_time(:millisecond))
      |> Map.put(:retrying, nil)
    end)
  end

  defp update_turn(state, sid, fun) do
    case Map.get(state.turns, sid) do
      nil -> state
      turn -> %{state | turns: Map.put(state.turns, sid, fun.(turn))}
    end
  end

  # An activity event is stamped and slimmed once, broadcast to the views,
  # and folded into the turn's card here, so a view that mounts mid-turn gets
  # the same card the others folded.
  defp fold_activity(state, agent_id, event) do
    event = event |> stamp() |> Activity.slim_event()
    broadcast(state, {:telemetry, agent_id, event})
    card = Map.get(state.telemetry, agent_id) || Activity.new()
    %{state | telemetry: Map.put(state.telemetry, agent_id, Activity.fold(event, card))}
  end

  defp stamp(%Event{data: data} = event),
    do: %{event | data: Map.put(data, :at, System.system_time(:millisecond))}

  defp session_for(state, sid),
    do: Enum.find_value(state.sessions, fn {_, s} -> s.engine_session_id == sid && s end)

  defp session_for_id(state, id),
    do: Enum.find_value(state.sessions, fn {_, s} -> s.id == id && s end)

  # -- Helpers ----------------------------------------------------------------

  defp router_ctx(state) do
    members = Enum.map(Channels.members(state.channel), & &1.id)

    %{
      channel: state.channel,
      members: members,
      teams: Teams.complete_in(members),
      owner_agent_id: state.channel.owner_agent_id,
      user_name: Users.local().display_name,
      lookup: &Agents.get/1,
      thread_root: &Messages.get/1,
      thread_last_agent: &Messages.thread_last_agent/2
    }
  end

  defp maybe_refresh_channel(%{event_type: type}, state)
       when type in ["owner_changed", "handoff_accepted"],
       do: %{state | channel: Channels.get!(state.channel.id)}

  defp maybe_refresh_channel(_event, state), do: state

  defp resolve_if_pending(%{status: "pending"} = request, reply),
    do: PermissionRequests.resolve(request, reply)

  defp resolve_if_pending(request, _reply), do: {:ok, request}

  defp resolve_question_if_pending(%{status: "pending"} = request, outcome),
    do: QuestionRequests.resolve(request, outcome, by: "user")

  defp resolve_question_if_pending(request, _outcome), do: {:ok, request}

  # Answered or rejected elsewhere (another engine client, or our own reply
  # coming back around as an event): record it once.
  defp resolve_question(state, opencode_question_id, outcome) do
    case QuestionRequests.get_by_opencode_id(opencode_question_id) do
      %{status: "pending"} = request ->
        {:ok, _} = QuestionRequests.resolve(request, outcome)
        clear_awaiting(state, request)

      _ ->
        state
    end
  end

  # -- Waiting on the user ----------------------------------------------------

  # Reconciliation marks the prompts it lists as replays (`data.replay`).
  defp replay?(%Event{data: %{replay: true}}), do: true
  defp replay?(_event), do: false

  # A card already showing and waiting: a replay of it changes nothing on screen.
  defp attached?(%{status: "pending", detached_at: nil}), do: true
  defp attached?(_request), do: false

  defp awaiting?(turn), do: MapSet.size(Map.get(turn, :awaiting_user, MapSet.new())) > 0

  # A card the agent's turn is blocked on. The first one marks the turn as
  # awaiting the user and, under serialize_turns, frees the channel for the
  # next wake in line.
  defp mark_awaiting(state, sid, %{status: "pending", detached_at: nil, id: id}) do
    case Map.get(state.turns, sid) do
      nil ->
        state

      turn ->
        first? = not awaiting?(turn)

        turn =
          turn
          |> Map.put(:awaiting_user, MapSet.put(Map.get(turn, :awaiting_user, MapSet.new()), id))
          |> Map.put_new(:awaiting_since, System.monotonic_time(:millisecond))

        state = %{state | turns: Map.put(state.turns, sid, turn)}

        if first? do
          broadcast(state, {:agent_status, turn.agent_id, :awaiting_user})
          # a lock it holds now waits on the user too; the lock views say so
          Locks.touch(state.repository.id, turn.session.id)
          start_next_waiting(state)
        else
          state
        end
    end
  end

  defp mark_awaiting(state, _sid, _request), do: state

  # The card no longer blocks its turn (answered, rejected, expired). With
  # none left, the turn is working again.
  defp clear_awaiting(state, %{id: id, agent_session: %{engine_session_id: sid}}) do
    case Map.get(state.turns, sid) do
      %{awaiting_user: %MapSet{} = ids} = turn ->
        if MapSet.member?(ids, id) do
          ids = MapSet.delete(ids, id)

          turn =
            if MapSet.size(ids) == 0,
              do: turn |> Map.delete(:awaiting_user) |> Map.delete(:awaiting_since),
              else: Map.put(turn, :awaiting_user, ids)

          state = %{state | turns: Map.put(state.turns, sid, turn)}
          broadcast(state, {:agent_status, turn.agent_id, turn_status(state, turn.agent_id)})
          if MapSet.size(ids) == 0, do: Locks.touch(state.repository.id, turn.session.id)
          state
        else
          state
        end

      _ ->
        state
    end
  end

  defp clear_awaiting(state, _request), do: state

  # Read fresh: the channel may have been archived since the server started.
  defp archived?(state), do: Channels.archived?(Channels.get!(state.channel.id))

  # The agent stopped waiting before the user answered. The answer is posted to
  # the channel as a message from the user mentioning the agent, so it wakes it
  # through the router like any message (merging, holds, spend limits, the
  # chatter budget) and stays in the channel for canopy_messages_read. Only
  # then is the card resolved, naming the message. A rejection only clears the
  # card.
  defp deliver_late_answer(_state, %{status: "pending"} = request, :rejected, _opts),
    do: QuestionRequests.resolve(request, :rejected, by: "user")

  defp deliver_late_answer(state, %{status: "pending"} = request, {:answered, answers}, opts) do
    body = Prompts.answer_message(asker_name(request), request.questions, answers, opts)

    with {:ok, message} <- Messages.post_user_message(state.channel.id, Users.local().id, body) do
      QuestionRequests.resolve(request, {:answered, answers},
        by: "user",
        delivered: "message",
        message_id: message.id
      )
    end
  end

  defp deliver_late_answer(_state, request, _outcome, _opts), do: {:ok, request}

  defp deliver_late_permission(_state, %{status: "pending"} = request, :reject),
    do: PermissionRequests.resolve(request, :reject)

  defp deliver_late_permission(state, %{status: "pending"} = request, reply) do
    body = Prompts.approval_message(asker_name(request), request, reply)

    with {:ok, message} <- Messages.post_user_message(state.channel.id, Users.local().id, body) do
      PermissionRequests.resolve(request, reply, delivered: "message", message_id: message.id)
    end
  end

  defp deliver_late_permission(_state, request, _reply), do: {:ok, request}

  defp asker_name(%{agent_session: %{agent: %{name: name}}}), do: name
  defp asker_name(%{agent_session: %{agent_id: id}}), do: agent_name(id)

  # OpenCode sends one list of chosen labels per question; older payloads used a
  # bare string per question.
  defp normalize_answers(answers) when is_list(answers), do: Enum.map(answers, &List.wrap/1)
  defp normalize_answers(_), do: []

  defp record_error(state, agent_id, reason) do
    Logger.warning("channel #{state.channel.name}: #{reason}")

    {:ok, _} =
      Timeline.record(%{
        channel_id: state.channel.id,
        agent_id: agent_id,
        event_type: "agent_error",
        payload: %{"reason" => reason}
      })

    broadcast(state, {:agent_status, agent_id, :error})
    state
  end

  defp broadcast(state, message),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, Timeline.topic(state.channel.id), message)

  defp broadcast_turn_thread(state, agent_id, thread_id) do
    broadcast(state, {:turn_thread, agent_id, thread_id})
    Canopy.Threads.broadcast_turn(state.channel.id, agent_id, thread_id)
  end

  # Where a turn's lines go: only the thread for a thread turn, else the feed.
  defp thread_scope(nil), do: %{}
  defp thread_scope(thread_id), do: %{thread_id: thread_id, in_channel: false}

  defp reply_atom("once"), do: :once
  defp reply_atom("always"), do: :always
  defp reply_atom(_), do: :reject

  @error_max 300

  defp error_message(%{"data" => %{"message" => m}} = error) when is_binary(m) do
    m
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, @error_max)
    |> add_hint(error)
  end

  defp error_message(%{"name" => n}) when is_binary(n), do: n
  defp error_message(other), do: other |> inspect() |> String.slice(0, @error_max)

  defp add_hint(message, %{"name" => "ProviderModelNotFoundError"}),
    do:
      message <>
        " (check the agent's model on the Agents page, or the default model in Settings)"

  defp add_hint(message, _), do: message
end
