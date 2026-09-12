defmodule Canopy.Runtime.ChannelServer do
  @moduledoc """
  One process per open channel. It owns the OpenCode sessions of the channel's
  agents, turns durable collaboration events into agent wake-ups, and turns
  OpenCode execution events into durable state and live telemetry.

  Inputs:
    * `{:timeline, %Canopy.Timeline.Event{}}` from `Canopy.Timeline` (messages,
      delegations, handoffs). Routed by `Canopy.Runtime.Router`.
    * `{:opencode_event, %Canopy.OpenCode.Event{}}` from the repository's event
      stream, delivered on per-session topics.

  Outputs on the channel topic (`"channel:<id>"`):
    * `{:telemetry, agent_id, %Canopy.OpenCode.Event{}}` — ephemeral tool/text activity
    * `{:agent_status, agent_id, :idle | :busy | :error}`

  The MCP tools never call this process; they write through contexts and the
  resulting timeline events arrive here like any other.
  """

  use GenServer
  require Logger

  alias Canopy.{
    Agents,
    AgentSessions,
    Channels,
    Costs,
    Delegations,
    Messages,
    PermissionRequests,
    Repositories,
    Settings,
    Timeline,
    Users
  }

  alias Canopy.OpenCode
  alias Canopy.OpenCode.Client
  alias Canopy.Runtime.{Activity, Prompts, Router}

  @telemetry_cap 200
  @reconcile_grace_ms 15_000

  @fields [
    :channel,
    :repository,
    :client_opts,
    # agent_id => %AgentSession{} (root sessions)
    sessions: %{},
    # delegation_id => %AgentSession{} (child sessions)
    child_sessions: %{},
    # opencode_session_id => %{agent_id, delegation_id | nil}
    index: %{},
    # opencode_session_id => turn accumulator while busy
    turns: %{},
    # opencode_session_id => [pending prompt text]
    queues: %{},
    # agent_id => [event] newest first
    telemetry: %{},
    mcp_registered?: false,
    start_stream?: true,
    stream_seen?: false,
    # agent turns started since the user last did something
    chatter: 0,
    # nil, or the wakeups held back once the chatter budget ran out
    paused: nil,
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

  def respond_permission(server, permission_request_id, reply)
      when reply in [:once, :always, :reject],
      do: GenServer.call(server, {:respond_permission, permission_request_id, reply})

  def abort(server, agent_id), do: GenServer.call(server, {:abort, agent_id})

  def reset_session(server, agent_id, by),
    do: GenServer.call(server, {:reset_session, agent_id, by})

  def telemetry(server, agent_id), do: GenServer.call(server, {:telemetry, agent_id})
  def status(server), do: GenServer.call(server, :status)
  def paused?(server), do: GenServer.call(server, :paused?)

  def pass(server, opencode_session_id, reason),
    do: GenServer.call(server, {:pass, opencode_session_id, reason})

  def continue(server), do: GenServer.call(server, :continue)

  def wake(server, agent_id, text),
    do: GenServer.cast(server, {:wake, {:root, agent_id}, %{text: text, trigger: "scheduled"}})

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
      client_opts: [base_url: Keyword.get(opts, :base_url) || Settings.get().opencode_url],
      start_stream?: Keyword.get(opts, :start_stream, stream_default())
    }

    # Subscribe and load sessions before start_link returns, so a message posted
    # right after ensure_channel/1 cannot be broadcast before we are listening.
    {:ok, attach(state)}
  end

  defp upgrade(state), do: struct(__MODULE__, Map.from_struct(state))

  defp attach(state) do
    :ok = Timeline.subscribe(state.channel.id)
    :ok = OpenCode.Supervisor.subscribe_repository(state.repository.id)
    :ok = Settings.subscribe()
    if state.start_stream?, do: ensure_stream(state)

    Enum.reduce(AgentSessions.list_for_channel(state.channel.id), state, fn session, acc ->
      case session.parent_session_id do
        nil ->
          acc |> put_root(session)

        _ ->
          case Delegations.get_by_child_session(session.id) do
            %{id: did} -> put_child(acc, did, session)
            _ -> acc
          end
      end
    end)
  end

  @impl true
  def handle_call(msg, from, %__MODULE__{} = state) when map_size(state) != @field_count,
    do: handle_call(msg, from, upgrade(state))

  def handle_call({:respond_permission, request_id, reply}, _from, state) do
    request = PermissionRequests.get!(request_id)

    with {:ok, _} <-
           client().reply_permission(
             state.repository.path,
             request.opencode_permission_id,
             reply,
             state.client_opts
           ),
         {:ok, request} <- resolve_if_pending(request, reply) do
      {:reply, {:ok, request}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Drops the agent's root session in this channel so its next wake starts a
  # fresh OpenCode session: the cure for a poisoned or bloated context.
  def handle_call({:reset_session, agent_id, by}, _from, state) do
    session =
      Map.get(state.sessions, agent_id) || AgentSessions.get_root(state.channel.id, agent_id)

    cond do
      is_nil(session) ->
        {:reply, {:error, :no_session}, state}

      Map.has_key?(state.turns, session.opencode_session_id) ->
        {:reply, {:error, :busy}, state}

      true ->
        {:ok, _} = AgentSessions.delete(session)

        {:ok, _} =
          Timeline.record(%{
            channel_id: state.channel.id,
            agent_id: agent_id,
            event_type: "session_reset",
            ref_id: session.id,
            payload: %{"by" => by, "opencode_session_id" => session.opencode_session_id}
          })

        state = %{
          state
          | sessions: Map.delete(state.sessions, agent_id),
            index: Map.delete(state.index, session.opencode_session_id),
            queues: Map.delete(state.queues, session.opencode_session_id),
            telemetry: Map.delete(state.telemetry, agent_id)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call({:abort, agent_id}, _from, state) do
    case Map.get(state.sessions, agent_id) do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        result =
          client().abort(state.repository.path, session.opencode_session_id, state.client_opts)

        {:reply, result, state}
    end
  end

  def handle_call({:telemetry, agent_id}, _from, state),
    do: {:reply, state.telemetry |> Map.get(agent_id, []) |> Enum.reverse(), state}

  def handle_call(:status, _from, state) do
    statuses =
      Map.new(state.sessions, fn {agent_id, session} ->
        {agent_id,
         if(Map.has_key?(state.turns, session.opencode_session_id), do: :busy, else: :idle)}
      end)

    queued = Map.new(waiting_agent_ids(state), &{&1, :queued})
    {:reply, Map.merge(statuses, queued), state}
  end

  def handle_call(:paused?, _from, state), do: {:reply, is_list(state.paused), state}

  # The agent chose not to respond: the turn ends without a reply message.
  def handle_call({:pass, sid, reason}, _from, state) do
    if Map.has_key?(state.turns, sid),
      do: {:reply, :ok, update_turn(state, sid, &%{&1 | passed: reason || ""})},
      else: {:reply, {:error, :no_turn}, state}
  end

  # The user pressed Continue: the held wakeups run, against a fresh budget.
  def handle_call(:continue, _from, state) do
    held = state.paused || []
    state = %{state | chatter: 0, paused: nil}
    broadcast(state, {:chatter, :resumed})

    {:reply, :ok,
     Enum.reduce(held, state, fn {t, text}, acc -> wake_within_budget(acc, t, text) end)}
  end

  @impl true
  def handle_cast(msg, %__MODULE__{} = state) when map_size(state) != @field_count,
    do: handle_cast(msg, upgrade(state))

  def handle_cast({:wake, target, text}, state),
    do: {:noreply, wake_within_budget(%{state | chatter: 0, paused: nil}, target, text)}

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
        {target, wake_message(wake, trigger)}
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

  # `file.edited` carries no session id; attribute it to every turn in flight in
  # this channel (almost always exactly one agent is busy).
  def handle_info(
        {:opencode_event, %OpenCode.Event{type: :file_changed, session_id: nil} = event},
        state
      ) do
    state =
      Enum.reduce(state.turns, state, fn {sid, _turn}, acc ->
        case Map.get(acc.index, sid) do
          nil -> acc
          who -> handle_execution(%{event | session_id: sid}, who, acc)
        end
      end)

    {:noreply, state}
  end

  def handle_info({:opencode_event, %OpenCode.Event{session_id: sid} = event}, state) do
    case Map.get(state.index, sid) do
      nil -> {:noreply, state}
      who -> {:noreply, handle_execution(event, who, state)}
    end
  end

  # The event stream reconnected: events may have been missed, so reconcile
  # against OpenCode's view of session status and pending permissions. The very
  # first connect after start carries nothing to reconcile and races the first
  # prompt, so it is skipped.
  def handle_info({:opencode_stream, :connected, _repository_id}, %{stream_seen?: false} = state),
    do: {:noreply, %{state | stream_seen?: true}}

  # A reconnect usually means OpenCode restarted, and its MCP registrations are
  # process-local: forget ours so the next prompt checks and re-registers.
  def handle_info({:opencode_stream, :connected, _repository_id}, state),
    do: {:noreply, reconcile(%{state | mcp_registered?: false})}

  # The MCP token changed: the registration OpenCode holds is stale.
  def handle_info({:settings, :mcp_token_rotated}, state),
    do: {:noreply, %{state | mcp_registered?: false}}

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def reconcile(state) do
    dir = state.repository.path

    busy_ids =
      case client().session_status(dir, state.client_opts) do
        {:ok, statuses} when is_map(statuses) ->
          statuses
          |> Enum.reject(fn {_, st} -> st["type"] == "idle" end)
          |> Enum.map(&elem(&1, 0))

        _ ->
          # unknown: leave turns alone
          Map.keys(state.turns)
      end

    # turns we think are running but OpenCode reports idle: finish them. A turn
    # younger than the grace period may not be marked busy yet; leave it alone.
    now = System.monotonic_time(:millisecond)

    state =
      state.turns
      |> Enum.reject(fn {sid, turn} ->
        sid in busy_ids or now - turn.started_at < @reconcile_grace_ms
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.reduce(state, fn sid, acc ->
        case Map.get(acc.index, sid) do
          nil -> acc
          who -> finish_turn(acc, sid, who, :ok)
        end
      end)

    # permissions raised while we were disconnected (endpoint may 400: best effort)
    case client().pending_permissions(dir, state.client_opts) do
      {:ok, requests} when is_list(requests) ->
        Enum.each(requests, fn req ->
          case Map.get(state.index, req["sessionID"]) do
            nil ->
              :ok

            who ->
              handle_execution(
                %OpenCode.Event{
                  type: :approval_required,
                  session_id: req["sessionID"],
                  data: %{request: req}
                },
                who,
                state
              )
          end
        end)

      {:error, reason} ->
        Logger.debug("permission reconciliation skipped: #{inspect(reason)}")
    end

    state
  end

  # -- Waking agents ----------------------------------------------------------

  # -- Chatter budget ---------------------------------------------------------
  #
  # Agents waking agents is what keeps a conversation alive, and also what
  # could keep it running unattended. Each turn started since the user's last
  # action counts; past the limit, wakeups are held and the channel says so.

  defp wake_within_budget(%{paused: held} = state, target, text) when is_list(held),
    do: %{state | paused: held ++ [{target, text}]}

  defp wake_within_budget(state, target, text) do
    limit = chatter_limit()

    cond do
      # A global hold (billing): drop the wake and say so once per channel.
      # The user's next message, after releasing the hold, wakes agents again.
      Canopy.Hold.active?() ->
        note_hold(state)

      # The channel has spent its limit: drop the wake and say so once per limit.
      # Raising the limit and posting again wakes agents.
      over_spend_limit?(state) ->
        note_spend_limit(state)

      is_integer(limit) and state.chatter >= limit ->
        pause(state, limit, [{target, text}])

      # One turn at a time: agents woken while another works wait their turn,
      # in order. They are counted against the budget when they actually start.
      Canopy.Settings.serialize_turns?() and map_size(state.turns) > 0 ->
        enqueue_waiting(state, target, text)

      true ->
        do_wake(%{state | chatter: state.chatter + 1}, target, text)
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

  defp enqueue_waiting(state, target, text) do
    state = %{state | waiting: state.waiting ++ [{target, text}]}
    agent_id = waiting_agent_id(target)
    if agent_id, do: broadcast(state, {:agent_status, agent_id, :queued})
    state
  end

  # After a turn ends: if the channel is free, start the next waiting wake.
  defp start_next_waiting(%{waiting: []} = state), do: state
  defp start_next_waiting(%{turns: turns} = state) when map_size(turns) > 0, do: state

  defp start_next_waiting(%{waiting: [{target, text} | rest]} = state),
    do: wake_within_budget(%{state | waiting: rest}, target, text)

  defp waiting_agent_ids(state),
    do: state.waiting |> Enum.map(fn {t, _} -> waiting_agent_id(t) end) |> Enum.reject(&is_nil/1)

  defp waiting_agent_id({:root, agent_id}), do: agent_id

  defp waiting_agent_id({:child, delegation_id}) do
    case Delegations.get(delegation_id) do
      %{to_agent_id: id} -> id
      _ -> nil
    end
  end

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

  defp resume(%{paused: nil, chatter: 0} = state), do: state

  defp resume(state) do
    if is_list(state.paused), do: broadcast(state, {:chatter, :resumed})
    %{state | chatter: 0, paused: nil}
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

      # another turn of the same agent (a child session) is still running
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

    last
    |> Map.put(:text, last.text <> Prompts.earlier_posts(earlier, plan))
    |> Map.put(:attachments, plan)
  end

  # The router hands back plain text, or a map with the attachments plan when
  # the message carried files.
  defp wake_message(text, trigger) when is_binary(text), do: %{text: text, trigger: trigger}
  defp wake_message(%{text: _} = wake, trigger), do: Map.put(wake, :trigger, trigger)

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

  defp do_wake(state, {:child, delegation_id}, text) do
    delegation = Delegations.get!(delegation_id)

    with {:ok, parent, state} <- ensure_root_session(state, delegation.from_agent_id),
         {:ok, child, state} <- ensure_child_session(state, delegation, parent) do
      prompt(state, child, delegation.to_agent_id, text)
    else
      {:error, reason, state} ->
        record_error(
          state,
          delegation.to_agent_id,
          "could not start child session: #{inspect(reason)}"
        )
    end
  end

  defp prompt(state, session, agent_id, text) do
    sid = session.opencode_session_id

    if Map.has_key?(state.turns, sid) do
      %{state | queues: Map.update(state.queues, sid, [text], &(&1 ++ [text]))}
    else
      send_prompt(state, session, agent_id, text)
    end
  end

  defp send_prompt(state, session, agent_id, %{text: text, trigger: trigger} = wake) do
    agent = Agents.get!(agent_id)
    Canopy.Notes.ensure_agent_notes(state.repository.path, agent)
    state = ensure_mcp(state)
    parts = attachment_parts(state, Map.get(wake, :attachments, []))
    body = prompt_body(agent, state, text, parts)

    case client().prompt_async(
           state.repository.path,
           session.opencode_session_id,
           body,
           state.client_opts
         ) do
      {:ok, _} ->
        {:ok, _} = AgentSessions.set_status(session, "busy")
        broadcast(state, {:agent_status, agent_id, :busy})

        {:ok, _} =
          Timeline.record(%{
            channel_id: state.channel.id,
            agent_id: agent_id,
            event_type: "agent_started",
            ref_id: session.id,
            payload: %{"opencode_session_id" => session.opencode_session_id}
          })

        turn = %{
          agent_id: agent_id,
          session: session,
          started_at: System.monotonic_time(:millisecond),
          texts: [],
          tools: 0,
          files: MapSet.new(),
          cost: 0.0,
          passed: nil,
          # set once the agent posts through Canopy tools during this turn
          posted?: false,
          # context of the largest model call (input + cached input tokens)
          context: 0,
          # model calls, and their tokens summed
          steps: 0,
          tokens: %{},
          trigger: trigger,
          # documents sent along as file parts; they stay in the session's context
          attachments: length(parts)
        }

        %{state | turns: Map.put(state.turns, session.opencode_session_id, turn)}

      {:error, reason} ->
        record_error(state, agent_id, "prompt failed: #{inspect(reason)}")
    end
  end

  # Every attachment is materialised under the repository's .canopy/files/ so
  # the agent can read it; the ones the plan marks as parts ride along too.
  defp attachment_parts(state, plan) do
    Enum.flat_map(plan, fn {document, mode} ->
      case Canopy.Documents.materialize(document, state.repository.path) do
        {:ok, _path} ->
          :ok

        {:error, reason} ->
          Logger.warning("could not materialise #{document.id}: #{inspect(reason)}")
      end

      case mode do
        :part -> List.wrap(Canopy.Documents.prompt_part(document))
        :path -> []
      end
    end)
  end

  defp prompt_body(agent, state, text, parts) do
    body = %{
      parts: [%{type: "text", text: text} | parts],
      agent: agent.opencode_agent || "build",
      system: Prompts.system(agent, state.channel, state.repository, Repositories.list()),
      tools: %{"canopy_*" => true}
    }

    case {agent.model_provider, agent.model_id} do
      {p, m} when is_binary(p) and is_binary(m) ->
        Map.put(body, :model, %{providerID: p, modelID: m})

      _ ->
        body
    end
  end

  # -- Sessions ---------------------------------------------------------------

  defp ensure_root_session(state, agent_id) do
    case Map.get(state.sessions, agent_id) || AgentSessions.get_root(state.channel.id, agent_id) do
      %AgentSessions.AgentSession{} = session ->
        {:ok, session, put_root(state, session)}

      nil ->
        agent = Agents.get!(agent_id)
        title = "##{state.channel.name} · @#{agent.name}"

        with {:ok, %{"id" => oc_id}} <-
               client().create_session(
                 state.repository.path,
                 %{title: title, agent: agent.opencode_agent || "build"},
                 state.client_opts
               ),
             {:ok, session} <-
               AgentSessions.create(%{
                 channel_id: state.channel.id,
                 agent_id: agent_id,
                 opencode_session_id: oc_id
               }) do
          {:ok, session, put_root(state, session)}
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp ensure_child_session(state, delegation, parent) do
    case Map.get(state.child_sessions, delegation.id) do
      %AgentSessions.AgentSession{} = child ->
        {:ok, child, state}

      nil ->
        agent = Agents.get!(delegation.to_agent_id)
        title = "##{state.channel.name} · @#{agent.name} (delegated)"

        with {:ok, %{"id" => oc_id}} <-
               client().create_session(
                 state.repository.path,
                 %{
                   title: title,
                   agent: agent.opencode_agent || "build",
                   parentID: parent.opencode_session_id
                 },
                 state.client_opts
               ),
             {:ok, child} <-
               AgentSessions.create(%{
                 channel_id: state.channel.id,
                 agent_id: delegation.to_agent_id,
                 opencode_session_id: oc_id,
                 parent_session_id: parent.id
               }),
             {:ok, _} <- Delegations.start(delegation, child.id) do
          {:ok, child, put_child(state, delegation.id, child)}
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp put_root(state, session) do
    subscribe_once(state, session)

    %{
      state
      | sessions: Map.put(state.sessions, session.agent_id, session),
        index:
          Map.put(state.index, session.opencode_session_id, %{
            agent_id: session.agent_id,
            delegation_id: nil
          })
    }
  end

  defp put_child(state, delegation_id, session) do
    subscribe_once(state, session)

    %{
      state
      | child_sessions: Map.put(state.child_sessions, delegation_id, session),
        index:
          Map.put(state.index, session.opencode_session_id, %{
            agent_id: session.agent_id,
            delegation_id: delegation_id
          })
    }
  end

  defp subscribe_once(state, session) do
    unless Map.has_key?(state.index, session.opencode_session_id) do
      OpenCode.Supervisor.subscribe_session(session.opencode_session_id)
    end
  end

  defp ensure_stream(state) do
    OpenCode.Supervisor.start_stream(state.repository.id, state.repository.path,
      base_url: state.client_opts[:base_url]
    )
  end

  defp ensure_mcp(%{mcp_registered?: true} = state), do: state

  # A registration OpenCode still reports as connected is reused only if this
  # Canopy process made it: an older one carries the tool list from before
  # Canopy last restarted. Otherwise it is (re)posted, which is idempotent.
  defp ensure_mcp(state) do
    dir = state.repository.path
    name = Canopy.MCP.registration_name()
    repository_id = state.repository.id

    # The identity plugin must be in this repository; a fresh install only
    # takes effect once OpenCode recreates its instance for the directory.
    case Canopy.MCP.ensure_project_plugin(dir) do
      {:ok, :installed} -> client().dispose_instance(dir, state.client_opts)
      _ -> :ok
    end

    connected? =
      match?(
        {:ok, %{^name => %{"status" => "connected"}}},
        client().mcp_status(dir, state.client_opts)
      )

    registered? =
      (connected? and Canopy.MCP.registered_this_boot?(repository_id)) or
        match?(
          {:ok, _},
          client().add_mcp(dir, name, Canopy.MCP.registration_config(:current), state.client_opts)
        )

    if registered?, do: Canopy.MCP.mark_registered(repository_id)
    %{state | mcp_registered?: registered?}
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

  # OpenCode keeps emitting for a session after session.idle (session.diff,
  # late part updates). Activity outside a turn must not reopen the working
  # card, so it is dropped.
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
    broadcast(state, {:telemetry, agent_id, event})
    state = buffer(state, agent_id, event)
    update_turn(state, event.session_id, fn turn -> turn_stats(turn, event) end)
  end

  defp handle_execution(%{type: :text_delta} = event, %{agent_id: agent_id}, state) do
    broadcast(state, {:telemetry, agent_id, event})
    state
  end

  defp handle_execution(
         %{type: :text_done, data: %{text: text}} = event,
         %{agent_id: agent_id},
         state
       ) do
    broadcast(state, {:telemetry, agent_id, event})
    update_turn(state, event.session_id, fn turn -> %{turn | texts: [text | turn.texts]} end)
  end

  defp handle_execution(%{type: :turn_usage, data: %{cost: cost}} = event, _who, state)
       when is_number(cost) do
    update_turn(state, event.session_id, fn turn -> %{turn | cost: turn.cost + cost} end)
  end

  defp handle_execution(
         %{type: :approval_required, data: %{request: req}} = event,
         %{agent_id: agent_id},
         state
       ) do
    session = session_for(state, event.session_id)

    {:ok, _} =
      PermissionRequests.record(%{
        channel_id: state.channel.id,
        agent_session_id: session && session.id,
        opencode_permission_id: req["id"],
        permission: req["permission"],
        patterns: req["patterns"] || [],
        metadata: req["metadata"] || %{},
        tool_call_id: get_in(req, ["tool", "callID"]),
        status: "pending"
      })

    broadcast(state, {:telemetry, agent_id, event})
    state
  end

  defp handle_execution(
         %{type: :approval_resolved, data: %{request_id: rid, reply: reply}},
         _who,
         state
       ) do
    case PermissionRequests.get_by_opencode_id(rid) do
      %{status: "pending"} = request ->
        {:ok, _} = PermissionRequests.resolve(request, reply_atom(reply))

      _ ->
        :ok
    end

    state
  end

  defp handle_execution(%{type: :agent_status, data: %{status: :busy}}, _who, state), do: state

  defp handle_execution(%{type: :agent_completed} = event, who, state),
    do: finish_turn(state, event.session_id, who, :ok)

  # OpenCode can emit session.error several times for one failure (with and
  # without a stack trace). Only the first one, while a turn is in flight, is recorded.
  defp handle_execution(%{type: :agent_error, session_id: sid}, _who, %{turns: turns} = state)
       when not is_map_key(turns, sid),
       do: state

  defp handle_execution(%{type: :agent_error, data: %{error: error}} = event, who, state) do
    reason = error_message(error)
    if Canopy.Hold.billing_error?(reason), do: Canopy.Hold.engage(reason)

    {:ok, _} =
      Timeline.record(%{
        channel_id: state.channel.id,
        agent_id: who.agent_id,
        event_type: "agent_error",
        payload: %{"reason" => reason}
      })

    finish_turn(state, event.session_id, who, {:error, reason})
  end

  defp handle_execution(_event, _who, state), do: state

  defp finish_turn(state, sid, who, outcome) do
    case Map.pop(state.turns, sid) do
      {nil, _} ->
        state

      {turn, turns} ->
        state = %{state | turns: turns}
        # reload: the struct captured at prompt time still says "idle", so a
        # changeset built from it would see no change
        session = AgentSessions.get!(turn.session.id)

        {:ok, _} =
          case outcome do
            :ok -> AgentSessions.set_status(session, "idle")
            {:error, reason} -> AgentSessions.set_status(session, "error", reason)
          end

        # The summary goes in before the reply so its activity card sits above
        # the message, where the live card was while the agent worked.
        activity =
          state.telemetry
          |> Map.get(who.agent_id, [])
          |> Enum.reverse()
          |> Activity.fold_all()
          |> Activity.to_payload()

        {:ok, _} =
          Timeline.record(%{
            channel_id: state.channel.id,
            agent_id: who.agent_id,
            event_type: "agent_turn_completed",
            ref_id: session.id,
            payload: %{
              "tools" => turn.tools,
              "files" => MapSet.to_list(turn.files),
              "cost" => turn.cost,
              "duration_ms" => System.monotonic_time(:millisecond) - turn.started_at,
              "outcome" => if(outcome == :ok, do: "ok", else: "error"),
              "model" => turn_model(who.agent_id),
              "delegation_id" => who.delegation_id,
              "activity" => activity,
              "passed" => is_binary(turn.passed),
              "note" => turn.passed,
              "trigger" => turn.trigger,
              "attachments" => Map.get(turn, :attachments, 0),
              "steps" => turn.steps,
              "context" => turn.context,
              "tokens" => turn.tokens,
              "final_text" => if(turn.posted?, do: final_text(turn))
            }
          })

        # The final text is the reply only when the agent said nothing through
        # the tools; after a message_send it is a recap, kept on the card.
        if is_nil(turn.passed) and not turn.posted?, do: maybe_post_reply(state, turn, who)

        broadcast(
          state,
          {:agent_status, who.agent_id, if(outcome == :ok, do: :idle, else: :error)}
        )

        state = %{state | telemetry: Map.delete(state.telemetry, who.agent_id)}
        state = if outcome == :ok, do: maybe_compact(state, session, turn, who), else: state

        state = release_deferred(state, who.agent_id)

        if state.pending_switch?,
          do: apply_switch(state),
          else: state |> drain_queue(session, who.agent_id) |> start_next_waiting()
    end
  end

  # The DM now works in another repository. Once nothing is in flight, forget
  # every session (they belong to the old directory), reload the channel, and
  # follow the new repository's event stream; the next wake starts fresh there.
  defp apply_switch(%{turns: turns} = state) when map_size(turns) > 0, do: state

  defp apply_switch(state) do
    Enum.each(AgentSessions.list_for_channel(state.channel.id), &AgentSessions.delete/1)
    channel = Channels.get!(state.channel.id)
    repository = Repositories.get!(channel.repository_id)
    :ok = OpenCode.Supervisor.subscribe_repository(repository.id)

    state = %{
      state
      | channel: channel,
        repository: repository,
        sessions: %{},
        child_sessions: %{},
        index: %{},
        queues: %{},
        telemetry: %{},
        mcp_registered?: false,
        pending_switch?: false
    }

    if state.start_stream?, do: ensure_stream(state)
    state
  end

  # A message the agent posted itself (post or thread reply) while its turn is
  # in flight marks that turn, so the closing text is not posted a second time.
  defp note_agent_post(
         %Timeline.Event{event_type: "message", message: %{agent_id: agent_id, kind: kind}},
         state
       )
       when is_binary(agent_id) and kind in ["post", "thread_reply"] do
    turns =
      Map.new(state.turns, fn
        {sid, %{agent_id: ^agent_id} = turn} -> {sid, %{turn | posted?: true}}
        other -> other
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

  # The last text part of the turn is the agent's reply; earlier parts are narration.
  defp maybe_post_reply(state, %{texts: [last | _]}, who) when is_binary(last) do
    case String.trim(last) do
      "" ->
        nil

      text ->
        {:ok, message} = Messages.post_agent_reply(state.channel.id, who.agent_id, text)
        message.id
    end
  end

  defp maybe_post_reply(_state, _turn, _who), do: nil

  # "provider/model" as configured on the agent; OpenCode's default otherwise.
  defp turn_model(agent_id) do
    case Agents.get(agent_id) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) -> p <> "/" <> m
      _ -> "opencode default"
    end
  end

  defp drain_queue(state, session, agent_id) do
    case Map.get(state.queues, session.opencode_session_id, []) do
      [] ->
        state

      [next | rest] ->
        state = %{state | queues: Map.put(state.queues, session.opencode_session_id, rest)}
        send_prompt(state, session, agent_id, next)
    end
  end

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

  @doc "Context (tokens per model call) above which a session is compacted after its turn."
  def context_cap, do: Application.get_env(:canopy, :context_cap, 40_000)

  # A session that has grown past the cap gets compacted by OpenCode: its
  # history becomes a summary, so the next turn starts small. Memory and the
  # channel tools carry everything else. Best effort: a failure is logged.
  defp maybe_compact(state, session, %{context: context}, who) when context > 0 do
    if context > context_cap() do
      case compaction_model(who.agent_id) do
        {provider, model} ->
          case client().summarize(
                 state.repository.path,
                 session.opencode_session_id,
                 %{providerID: provider, modelID: model},
                 state.client_opts
               ) do
            {:ok, _} ->
              {:ok, _} =
                Timeline.record(%{
                  channel_id: state.channel.id,
                  agent_id: who.agent_id,
                  event_type: "session_compacted",
                  ref_id: session.id,
                  payload: %{"context" => context, "cap" => context_cap()}
                })

            {:error, reason} ->
              Logger.warning(
                "compaction failed for #{session.opencode_session_id}: #{inspect(reason)}"
              )
          end

        nil ->
          Logger.warning("no model to compact #{session.opencode_session_id} with")
      end
    end

    state
  end

  defp maybe_compact(state, _session, _turn, _who), do: state

  # The agent's own model, else OpenCode's default for the first provider.
  defp compaction_model(agent_id) do
    case Agents.get(agent_id) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) ->
        {p, m}

      _ ->
        case client().providers([]) do
          {:ok, %{"default" => defaults}} when map_size(defaults) > 0 ->
            defaults |> Enum.min_by(fn {p, _} -> p end)

          _ ->
            nil
        end
    end
  end

  defp update_turn(state, sid, fun) do
    case Map.get(state.turns, sid) do
      nil -> state
      turn -> %{state | turns: Map.put(state.turns, sid, fun.(turn))}
    end
  end

  defp buffer(state, agent_id, event) do
    events =
      state.telemetry |> Map.get(agent_id, []) |> then(&[event | &1]) |> Enum.take(@telemetry_cap)

    %{state | telemetry: Map.put(state.telemetry, agent_id, events)}
  end

  defp session_for(state, sid) do
    Enum.find_value(state.sessions, fn {_, s} -> s.opencode_session_id == sid && s end) ||
      Enum.find_value(state.child_sessions, fn {_, s} -> s.opencode_session_id == sid && s end)
  end

  # -- Helpers ----------------------------------------------------------------

  defp router_ctx(state) do
    %{
      channel: state.channel,
      members: Enum.map(Channels.members(state.channel), & &1.id),
      owner_agent_id: state.channel.owner_agent_id,
      user_name: Users.local().display_name,
      lookup: &Agents.get/1,
      thread_root: &Messages.get/1
    }
  end

  defp maybe_refresh_channel(%{event_type: type}, state)
       when type in ["owner_changed", "handoff_accepted"],
       do: %{state | channel: Channels.get!(state.channel.id)}

  defp maybe_refresh_channel(_event, state), do: state

  defp resolve_if_pending(%{status: "pending"} = request, reply),
    do: PermissionRequests.resolve(request, reply)

  defp resolve_if_pending(request, _reply), do: {:ok, request}

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
    do: message <> " (check the agent's model provider and id on the Agents page)"

  defp add_hint(message, _), do: message

  defp client, do: Client.impl()

  defp stream_default,
    do: Keyword.get(Application.get_env(:canopy, :opencode, []), :start_streams, true)
end
