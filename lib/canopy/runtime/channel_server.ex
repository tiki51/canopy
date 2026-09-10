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

  defstruct [
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
    stream_seen?: false
  ]

  # -- API --------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def respond_permission(server, permission_request_id, reply)
      when reply in [:once, :always, :reject],
      do: GenServer.call(server, {:respond_permission, permission_request_id, reply})

  def abort(server, agent_id), do: GenServer.call(server, {:abort, agent_id})
  def telemetry(server, agent_id), do: GenServer.call(server, {:telemetry, agent_id})
  def status(server), do: GenServer.call(server, :status)
  def wake(server, agent_id, text), do: GenServer.cast(server, {:wake, {:root, agent_id}, text})

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

    {:reply, statuses, state}
  end

  @impl true
  def handle_cast({:wake, target, text}, state), do: {:noreply, do_wake(state, target, text)}

  @impl true
  def handle_info({:timeline, %Timeline.Event{} = event}, state) do
    state = maybe_refresh_channel(event, state)
    ctx = router_ctx(state)

    state =
      event
      |> Router.wakeups(ctx)
      |> Enum.reduce(state, fn {target, text}, acc -> do_wake(acc, target, text) end)

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

  def handle_info({:opencode_stream, :connected, _repository_id}, state),
    do: {:noreply, reconcile(state)}

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

  defp send_prompt(state, session, agent_id, text) do
    agent = Agents.get!(agent_id)
    state = ensure_mcp(state)
    body = prompt_body(agent, state, text)

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
          cost: 0.0
        }

        %{state | turns: Map.put(state.turns, session.opencode_session_id, turn)}

      {:error, reason} ->
        record_error(state, agent_id, "prompt failed: #{inspect(reason)}")
    end
  end

  defp prompt_body(agent, state, text) do
    body = %{
      parts: [%{type: "text", text: text}],
      agent: agent.opencode_agent || "build",
      system: Prompts.system(agent, state.channel, state.repository),
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

  defp ensure_mcp(state) do
    dir = state.repository.path
    name = Canopy.MCP.registration_name()

    registered? =
      case client().mcp_status(dir, state.client_opts) do
        {:ok, %{^name => %{"status" => "connected"}}} -> true
        _ -> false
      end

    registered? =
      registered? or
        match?(
          {:ok, _},
          client().add_mcp(dir, name, Canopy.MCP.registration_config(:current), state.client_opts)
        )

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
              "delegation_id" => who.delegation_id,
              "activity" => activity
            }
          })

        maybe_post_reply(state, turn, who)

        broadcast(
          state,
          {:agent_status, who.agent_id, if(outcome == :ok, do: :idle, else: :error)}
        )

        state = %{state | telemetry: Map.delete(state.telemetry, who.agent_id)}
        drain_queue(state, session, who.agent_id)
    end
  end

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

  defp turn_stats(turn, %{type: :file_changed, data: %{path: path}}),
    do: %{turn | files: MapSet.put(turn.files, path)}

  defp turn_stats(turn, _), do: turn

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
