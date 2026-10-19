defmodule Canopy.Codex.Turn do
  @moduledoc """
  One `codex app-server` process for one turn, driven through an Erlang port
  speaking JSON-RPC lines (§5.2 of the design).

      spawn → initialize → initialized → thread/start | thread/resume
            → [thread/inject_items] → turn/start → … → turn/completed → stdin EOF

  **Thread ids.** Codex picks a thread's id. A session's first turn starts
  a thread under Canopy's placeholder id; the `thread/start` response names
  the real one, and before `turn/start` the Turn calls `:on_thread_id`
  (`fn old, new -> :ok end`, which renames the session row and moves the
  runtime over), registers itself under the new id, moves its work dir, and
  from then on broadcasts under the new id. No event goes out before
  `turn/start`, so nothing is lost. A resume that finds no thread (`no
  rollout found for thread id`) starts a fresh one,
  once, and renames again.

  **System text.** It goes in as `developerInstructions` on `thread/start`
  only: a thread keeps those for good. On resume, the Turn compares a hash
  of the current text with the one the thread last received
  (`instructions.sha256` in the work dir) and, when they differ, sends the
  full text with `thread/inject_items` as a developer message before
  `turn/start`. A failed inject keeps the old hash and the turn goes on.

  **Approvals and questions** are Codex's server requests: each is decided
  by `Canopy.Codex.Approvals` (an answer, or a card), and an open card waits
  in `open` until `answer/3`, its timeout (30 min; the question wait for
  questions), or Codex withdrawing it (`serverRequest/resolved`).

  **Stall.** No stdout line for `:stall_ms` (120 s) kills the turn, except
  while a card is open, or a work item (a command, an MCP call, a file
  change) has started and not completed: Codex completes a command item only
  when the command exits, so a silent build is not a stall. While an item is
  open, `:item_stall_ms` (60 min) still applies.

  **Abort** sends `turn/interrupt`: Codex ends the turn as `interrupted`
  with its usage, reported as a completed turn. Before the turn has an id
  there is nothing to interrupt, so the process is killed at once. Closing
  stdin is never used to abort: it loses the turn's usage. A caller never
  waits on a busy turn for more than a second (see `abort/2`).
  """

  use GenServer, restart: :temporary
  require Logger

  alias Canopy.ClaudeCode.Prompts
  alias Canopy.Codex.{Approvals, Events, RPC}
  alias Canopy.Engine
  alias Canopy.Engine.Event

  @default_stall_ms 120_000
  @default_item_stall_ms :timer.minutes(60)
  @abort_grace_ms 10_000
  @abort_call_ms 1_000
  @stderr_tail 600
  @registry Canopy.Codex.TurnRegistry

  @inject_preamble "Your Canopy instructions have changed. This replaces the earlier version in full; where they differ, follow this one.\n\n"

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Interrupts the turn; it still reports its usage and completes. A turn busy
  past `timeout` (renaming its session, which waits for the channel server's
  ack while that server may be the one calling here) still has the abort in
  its mailbox and acts on it next: `{:ok, :pending}`. `{:error, :no_turn}`
  when the turn has already ended.
  """
  def abort(server, timeout \\ @abort_call_ms) do
    GenServer.call(server, :abort, timeout)
  catch
    :exit, {:timeout, _} -> {:ok, :pending}
    :exit, _ -> {:error, :no_turn}
  end

  @doc """
  Sends `input` (Codex `UserInput`s) into the running turn with `ref` as its
  client id. `{:error, :not_running}` before the turn has an id, once it is
  done, or while it is being aborted.
  """
  def steer(server, input, ref) do
    GenServer.call(server, {:steer, input, ref})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Answers an open card by its card id: a permission reply (`:once | :always
  | :global | :reject`) or a question outcome (`{:answered, answers} |
  :rejected`). `{:error, :gone}` when the turn no longer holds it.
  """
  def answer(server, card_id, reply) do
    GenServer.call(server, {:answer, card_id, reply})
  catch
    :exit, _ -> {:error, :gone}
  end

  @doc "The cards still open, as `:approval_required` / `:question_required` events (`replay: true`)."
  def open_events(server) do
    GenServer.call(server, :open_events)
  catch
    :exit, _ -> []
  end

  @doc """
  The retry the turn is stuck in (`%{session_id, message, attempt}`), or nil.
  `session_id` is the id the turn runs under now: its thread id once renamed.
  """
  def retrying(server) do
    GenServer.call(server, :retrying)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    sid = Keyword.fetch!(opts, :session_id)
    work_dir = Keyword.fetch!(opts, :work_dir)
    cwd = Keyword.fetch!(opts, :cwd)

    state = %{
      session_id: sid,
      repository_id: Keyword.fetch!(opts, :repository_id),
      cwd: cwd,
      # %Canopy.Codex.Command{} map
      command: Keyword.fetch!(opts, :command),
      # :new (thread/start) or :resume
      flag: Keyword.get(opts, :flag, :new),
      # sandbox, approvalPolicy, approvalsReviewer, cwd (thread/start and resume;
      # thread_params/1 adds the trust override)
      thread_params: Keyword.get(opts, :thread_params, %{}),
      # input, model, effort, sandboxPolicy, approvalPolicy, approvalsReviewer, …
      turn_params: Keyword.get(opts, :turn_params, %{}),
      system: Keyword.get(opts, :system),
      compact?: Keyword.get(opts, :compact?, false),
      permission_mode: Keyword.get(opts, :permission_mode) || "default",
      # fn sid -> the session's work dir
      work_dir: work_dir,
      stderr_file: Keyword.get(opts, :stderr_file) || Path.join(work_dir.(sid), "stderr.log"),
      on_thread_id: Keyword.get(opts, :on_thread_id, fn _old, _new -> :ok end),
      stall_ms: Keyword.get(opts, :stall_ms, @default_stall_ms),
      item_stall_ms: Keyword.get(opts, :item_stall_ms, @default_item_stall_ms),
      card_prefix: "cx-#{sid}-#{random_tag()}",
      port: nil,
      os_pid: nil,
      buffer: "",
      next_id: 1,
      # our request id => what it was for
      pending_out: %{},
      thread_id: nil,
      turn_id: nil,
      acc: Events.new(cwd, model: get_in(Keyword.get(opts, :turn_params, %{}), ["model"])),
      # json-rpc id => %{kind, request, method, params, timer}
      open: %{},
      written_refs: [],
      consumed_refs: MapSet.new(),
      retrying: nil,
      done?: false,
      aborted?: false,
      resume_retried?: false,
      started?: false,
      wait_open?: false,
      last_line_at: System.monotonic_time(:millisecond)
    }

    {:ok, state, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state) do
    command = state.command

    port =
      Port.open({:spawn_executable, command.executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 1_000_000},
        {:args, command.args},
        {:cd, command.cwd},
        {:env, command.env}
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %{state | port: port, os_pid: os_pid}
    state = request(state, "initialize", Canopy.Codex.Command.client_info(), :initialize)
    schedule_stall_check(state)
    {:noreply, state}
  end

  # -- Calls ------------------------------------------------------------------------

  @impl true
  def handle_call(:abort, _from, %{port: nil} = state), do: {:reply, {:error, :no_turn}, state}

  def handle_call(:abort, _from, %{turn_id: nil} = state) do
    signal(state, "-KILL")
    close(state.port)
    broadcast([event(:agent_completed, %{})] |> add_unconsumed(state.written_refs), state)
    {:stop, :normal, {:ok, :killed}, %{state | port: nil, done?: true, aborted?: true}}
  end

  def handle_call(:abort, _from, state) do
    state =
      if state.aborted?,
        do: state,
        else:
          request(
            state,
            "turn/interrupt",
            %{"threadId" => state.thread_id, "turnId" => state.turn_id},
            :interrupt
          )

    Process.send_after(self(), :abort_deadline, @abort_grace_ms)
    {:reply, :ok, %{state | aborted?: true}}
  end

  def handle_call({:steer, input, ref}, _from, state) do
    if state.port == nil or state.turn_id == nil or state.done? or state.aborted? do
      {:reply, {:error, :not_running}, state}
    else
      params = %{
        "threadId" => state.thread_id,
        "expectedTurnId" => state.turn_id,
        "clientUserMessageId" => ref,
        "input" => input
      }

      state = request(state, "turn/steer", params, {:steer, ref})
      {:reply, :ok, %{state | written_refs: state.written_refs ++ [ref]}}
    end
  end

  def handle_call({:answer, card_id, reply}, _from, state) do
    case Enum.find(state.open, fn {_id, e} -> e.request["id"] == card_id end) do
      nil ->
        {:reply, {:error, :gone}, state}

      {rpc_id, entry} ->
        state = respond(state, rpc_id, entry, reply)
        {:reply, :ok, state}
    end
  end

  def handle_call(:open_events, _from, state) do
    events =
      for {_id, e} <- Enum.sort_by(state.open, &elem(&1, 0)) do
        type = if e.kind == :question, do: :question_required, else: :approval_required

        %Event{
          type: type,
          session_id: state.session_id,
          data: %{request: e.request, replay: true},
          raw_type: "reconcile"
        }
      end

    {:reply, events, state}
  end

  def handle_call(:retrying, _from, %{retrying: nil} = state), do: {:reply, nil, state}

  def handle_call(:retrying, _from, state),
    do: {:reply, Map.put(state.retrying, :session_id, state.session_id), state}

  # -- Port ---------------------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    state = %{state | buffer: "", last_line_at: System.monotonic_time(:millisecond)}

    case RPC.decode(line) do
      {:response, id, result} -> on_response(id, {:ok, result}, state)
      {:error, id, error} -> on_response(id, {:error, error}, state)
      {:request, id, method, params} -> {:noreply, on_request(id, method, params, state)}
      {:notification, method, params} -> on_notification(method, params, state)
      :invalid -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil}

    cond do
      state.done? ->
        {:stop, :normal, state}

      state.aborted? ->
        finish([event(:agent_completed, %{})], state)

      true ->
        fail(state, "codex exited with status #{status}" <> stderr_suffix(state))
    end
  end

  def handle_info(:stall_check, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:stall_check, state) do
    now = System.monotonic_time(:millisecond)
    waiting? = state.open != %{}

    cond do
      # Quiet because the user has not answered yet: not a stall. The window
      # restarts once the card has closed, so the resumed turn gets all of it.
      waiting? or state.wait_open? ->
        schedule_stall_check(state)
        {:noreply, %{state | last_line_at: now, wait_open?: waiting?}}

      Events.item_open?(state.acc) and now - state.last_line_at > state.item_stall_ms ->
        stall(state, state.item_stall_ms)

      Events.item_open?(state.acc) ->
        schedule_stall_check(state)
        {:noreply, state}

      now - state.last_line_at > state.stall_ms ->
        stall(state, state.stall_ms)

      true ->
        schedule_stall_check(state)
        {:noreply, state}
    end
  end

  def handle_info({:expire, rpc_id}, state) do
    case state.open[rpc_id] do
      nil -> {:noreply, state}
      entry -> {:noreply, expire(state, rpc_id, entry)}
    end
  end

  def handle_info(:abort_deadline, %{done?: false, port: port} = state) when port != nil do
    signal(state, "-KILL")
    close(port)
    finish([event(:agent_completed, %{})], %{state | port: nil})
  end

  def handle_info(:abort_deadline, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port do
      signal(state, "-KILL")
      close(state.port)
    end

    :ok
  end

  # -- Responses to our requests --------------------------------------------------------

  defp on_response(id, result, state) do
    {tag, pending} = Map.pop(state.pending_out, id)
    state = %{state | pending_out: pending}
    handle_response(tag, result, state)
  end

  defp handle_response(:initialize, {:ok, _result}, state) do
    send_line(state, RPC.notification("initialized"))
    {:noreply, start_thread(state)}
  end

  defp handle_response(:initialize, {:error, error}, state),
    do: fail(state, "codex app-server did not start: " <> error_text(error))

  defp handle_response(tag, {:ok, result}, state) when tag in [:thread_start, :thread_resume],
    do: on_thread(tag, result, state)

  defp handle_response(:thread_resume, {:error, error}, state) do
    if not state.resume_retried? and thread_missing?(error) do
      Logger.info("codex turn #{state.session_id}: no thread to resume, starting a new one")
      {:noreply, start_thread(%{state | flag: :new, resume_retried?: true})}
    else
      fail(state, "codex could not resume the thread: " <> error_text(error))
    end
  end

  defp handle_response(:thread_start, {:error, error}, state),
    do: fail(state, "codex could not start a thread: " <> error_text(error))

  defp handle_response({:inject, hash}, {:ok, _}, state) do
    write_hash(state, hash)
    {:noreply, start_turn(state)}
  end

  defp handle_response({:inject, _hash}, {:error, error}, state) do
    Logger.warning(
      "codex turn #{state.session_id}: could not update the instructions: #{error_text(error)}"
    )

    {:noreply, start_turn(state)}
  end

  defp handle_response(:turn_start, {:ok, %{"turn" => %{"id" => turn_id}}}, state),
    do: {:noreply, %{state | turn_id: turn_id, acc: Events.put_turn(state.acc, turn_id)}}

  defp handle_response(:turn_start, {:ok, _}, state), do: {:noreply, state}

  defp handle_response(:turn_start, {:error, error}, state),
    do: fail(state, "codex could not start the turn: " <> error_text(error))

  defp handle_response(:compact, {:error, error}, state),
    do: fail(state, "codex could not compact the thread: " <> error_text(error))

  # steer, interrupt, compact ok: nothing to do (an unread steer is reported at the end)
  defp handle_response(_tag, _result, state), do: {:noreply, state}

  # Codex 0.163's only wording for a thread it has no rollout for (probed:
  # -32600 "no rollout found for thread id <id>"). Anything else fails the
  # turn rather than start a new thread and lose the agent's context.
  defp thread_missing?(%{"message" => message}) when is_binary(message),
    do: message =~ ~r/no rollout found for thread id/i

  defp thread_missing?(_error), do: false

  # -- Thread, instructions, turn -------------------------------------------------------

  defp start_thread(%{flag: :resume} = state) do
    params =
      state
      |> thread_params()
      |> Map.put("threadId", state.session_id)
      |> Map.put("excludeTurns", true)

    request(state, "thread/resume", params, :thread_resume)
  end

  defp start_thread(state) do
    params =
      case state.system do
        text when is_binary(text) and text != "" ->
          Map.put(thread_params(state), "developerInstructions", text)

        _ ->
          thread_params(state)
      end

    request(state, "thread/start", params, :thread_start)
  end

  # Codex 0.163's app-server otherwise writes `trust_level = "trusted"` for an
  # untrusted cwd into the user's ~/.codex/config.toml (probed, workspace-write).
  # This thread-only override stops the write and leaves the sandbox and
  # approval policy as asked; a repo the user already trusts keeps its trust.
  defp thread_params(state) do
    cwd = state.thread_params["cwd"] || state.cwd
    trust = %{"projects" => %{cwd => %{"trust_level" => "untrusted"}}}
    Map.put(state.thread_params, "config", trust)
  end

  defp on_thread(tag, result, state) do
    thread_id = get_in(result, ["thread", "id"]) || state.session_id

    case rename(state, thread_id) do
      {:ok, state} -> on_thread(tag, result, thread_id, state)
      {:gone, state} -> session_gone(state)
    end
  end

  defp on_thread(tag, result, thread_id, state) do
    model = get_in(state.turn_params, ["model"]) || result["model"]
    acc = %{state.acc | model: model}

    broadcast(
      [Events.session_event(result, %{"permission_mode" => state.permission_mode})],
      state
    )

    state = %{state | thread_id: thread_id, acc: acc}
    hash = hash(state.system)

    cond do
      tag == :thread_start ->
        write_hash(state, hash)
        {:noreply, start_turn(state)}

      hash != nil and hash != read_hash(state) ->
        item = %{
          "type" => "message",
          "role" => "developer",
          "content" => [%{"type" => "input_text", "text" => @inject_preamble <> state.system}]
        }

        params = %{"threadId" => thread_id, "items" => [item]}
        {:noreply, request(state, "thread/inject_items", params, {:inject, hash})}

      true ->
        {:noreply, start_turn(state)}
    end
  end

  # thread/compact/start takes only threadId (0.163 schema), so there is no
  # sandbox to pin here. The compaction runs no tools, and the thread/resume
  # before it has already pinned the mode's sandbox.
  defp start_turn(%{compact?: true} = state),
    do: request(state, "thread/compact/start", %{"threadId" => state.thread_id}, :compact)

  defp start_turn(state) do
    params = Map.put(state.turn_params, "threadId", state.thread_id)
    request(%{state | started?: true}, "turn/start", params, :turn_start)
  end

  # The thread's real id: the session is renamed before any event goes out.
  # `{:gone, state}` when the session's row is gone (reset during the turn).
  defp rename(%{session_id: id} = state, id), do: {:ok, state}

  defp rename(state, new) do
    old = state.session_id

    case safe_call(fn -> state.on_thread_id.(old, new) end) do
      :ok ->
        do_rename(state, old, new)

      {:error, :session_gone} ->
        {:gone, state}

      other ->
        Logger.warning("codex turn #{old}: renaming to #{new}: #{inspect(other)}")
        do_rename(state, old, new)
    end
  end

  defp do_rename(state, old, new) do
    _ = Registry.register(@registry, new, nil)
    old_dir = state.work_dir.(old)
    new_dir = state.work_dir.(new)

    stderr =
      case File.rename(old_dir, new_dir) do
        :ok -> Path.join(new_dir, Path.basename(state.stderr_file))
        _ -> state.stderr_file
      end

    {:ok, %{state | session_id: new, stderr_file: stderr}}
  end

  # The session was reset while its first turn started: nothing is left to
  # run the turn for, so it ends with no error, before turn/start.
  defp session_gone(state) do
    Logger.info("codex turn #{state.session_id}: its session is gone (reset); ending the turn")
    signal(state, "-KILL")
    finish([event(:agent_completed, %{})], state)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp hash(text) when is_binary(text) and text != "",
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp hash(_text), do: nil

  defp hash_file(state), do: Path.join(state.work_dir.(state.session_id), "instructions.sha256")

  defp read_hash(state) do
    case File.read(hash_file(state)) do
      {:ok, text} -> String.trim(text)
      _ -> nil
    end
  end

  defp write_hash(_state, nil), do: :ok

  defp write_hash(state, hash) do
    path = hash_file(state)
    File.mkdir_p(Path.dirname(path))
    File.write(path, hash)
  end

  # -- Server requests (approvals, questions) --------------------------------------------

  defp on_request(rpc_id, method, params, state) do
    ctx = %{
      session_id: state.session_id,
      card_prefix: state.card_prefix,
      permission_mode: state.permission_mode,
      repository_path: state.cwd,
      items: state.acc.items
    }

    case Approvals.handle(method, rpc_id, params, ctx) do
      {:answer, result} ->
        send_line(state, RPC.response(rpc_id, result))
        state

      {:error, code, message} ->
        Logger.info("codex turn #{state.session_id}: declined server request #{method}")
        send_line(state, RPC.error(rpc_id, code, message))
        state

      {:card, request} ->
        open(state, rpc_id, :permission, request, method, params, Prompts.timeout_ms())

      {:question, request} ->
        open(state, rpc_id, :question, request, method, params, Prompts.question_timeout_ms())
    end
  end

  defp open(state, rpc_id, kind, request, method, params, timeout) do
    timer = Process.send_after(self(), {:expire, rpc_id}, timeout)
    entry = %{kind: kind, request: request, method: method, params: params, timer: timer}
    type = if kind == :question, do: :question_required, else: :approval_required

    broadcast(
      [%Event{type: type, data: %{request: request}, raw_type: "codex:" <> method}],
      state
    )

    %{state | open: Map.put(state.open, rpc_id, entry)}
  end

  defp respond(state, rpc_id, %{kind: :question} = entry, outcome) do
    send_line(state, RPC.response(rpc_id, Approvals.question_result(entry.request, outcome)))
    close_entry(state, rpc_id, entry)
  end

  defp respond(state, rpc_id, entry, reply) do
    {result, rule} = Approvals.result(entry.request, entry.params, reply)
    if rule, do: Approvals.remember(state.session_id, rule)
    send_line(state, RPC.response(rpc_id, result))
    close_entry(state, rpc_id, entry)
  end

  defp expire(state, rpc_id, %{kind: :question} = entry) do
    send_line(state, RPC.response(rpc_id, Approvals.question_result(entry.request, :expired)))
    broadcast([event(:question_expired, %{request_id: entry.request["id"]})], state)
    close_entry(state, rpc_id, entry)
  end

  defp expire(state, rpc_id, entry) do
    {result, _rule} = Approvals.result(entry.request, entry.params, :expired)
    send_line(state, RPC.response(rpc_id, result))
    broadcast([event(:approval_expired, %{request_id: entry.request["id"]})], state)
    close_entry(state, rpc_id, entry)
  end

  defp close_entry(state, rpc_id, entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    %{state | open: Map.delete(state.open, rpc_id)}
  end

  # -- Notifications ------------------------------------------------------------------

  # Codex withdrew a request still open here (the turn moved on without it).
  defp on_notification("serverRequest/resolved", %{"requestId" => rpc_id}, state) do
    case state.open[rpc_id] do
      nil ->
        {:noreply, state}

      entry ->
        type = if entry.kind == :question, do: :question_expired, else: :approval_expired
        broadcast([event(type, %{request_id: entry.request["id"]})], state)
        {:noreply, close_entry(state, rpc_id, entry)}
    end
  end

  defp on_notification("turn/completed", %{"turn" => turn} = params, state) do
    if state.turn_id != nil and turn["id"] != state.turn_id do
      {:noreply, state}
    else
      {events, acc} = Events.normalize("turn/completed", params, state.acc)
      events = if state.aborted?, do: Enum.map(events, &as_completed/1), else: events
      finish(events, %{state | acc: acc})
    end
  end

  defp on_notification("error", %{"willRetry" => true, "error" => error} = params, state) do
    {events, acc} = Events.normalize("error", params, state.acc)
    broadcast(events, state)
    attempt = ((state.retrying && state.retrying[:attempt]) || 0) + 1
    {:noreply, %{state | acc: acc, retrying: %{message: error["message"], attempt: attempt}}}
  end

  defp on_notification(method, params, state) do
    {events, acc} = Events.normalize(method, params, state.acc)
    broadcast(events, state)
    state = %{state | acc: acc} |> note_consumed(method, params) |> clear_retry(method)
    {:noreply, state}
  end

  defp note_consumed(state, method, %{"item" => %{"type" => "userMessage", "clientId" => ref}})
       when method in ["item/started", "item/completed"] and is_binary(ref),
       do: %{state | consumed_refs: MapSet.put(state.consumed_refs, ref)}

  defp note_consumed(state, _method, _params), do: state

  defp clear_retry(%{retrying: nil} = state, _method), do: state

  defp clear_retry(state, method) when method in ["item/started", "item/agentMessage/delta"],
    do: %{state | retrying: nil}

  defp clear_retry(state, _method), do: state

  # -- Ending ---------------------------------------------------------------------------

  defp finish(events, state) do
    events |> add_unconsumed(unconsumed(state)) |> broadcast(state)
    drop_open(state)
    if state.port, do: close(state.port)
    {:stop, :normal, %{state | port: nil, done?: true, open: %{}}}
  end

  defp fail(state, reason) do
    {usage, error} =
      if state.started?,
        do: {[Events.turn_usage(state.acc, "failed")], reason},
        else: {[], reason}

    events =
      usage ++
        [
          event(:agent_error, %{
            error: %{"name" => "codex", "data" => %{"message" => error}}
          })
        ]

    if state.aborted?,
      do: finish(Enum.map(events, &as_completed/1), state),
      else: finish(events, state)
  end

  defp stall(state, ms) do
    Logger.warning("codex turn #{state.session_id}: no output for #{ms} ms, killing")
    signal(state, "-KILL")
    fail(state, "no output from codex for #{div(ms, 1000)} s")
  end

  # Cards the process held can never be answered now: they detach.
  defp drop_open(state) do
    Enum.each(state.open, fn {_id, entry} ->
      if entry.timer, do: Process.cancel_timer(entry.timer)
      type = if entry.kind == :question, do: :question_expired, else: :approval_expired
      broadcast([event(type, %{request_id: entry.request["id"]})], state)
    end)
  end

  defp unconsumed(state),
    do: Enum.reject(state.written_refs, &MapSet.member?(state.consumed_refs, &1))

  defp add_unconsumed(events, []), do: events

  defp add_unconsumed(events, refs) do
    {before, terminal} = Enum.split_with(events, &(not terminal?(&1)))
    before ++ [%Event{type: :prompts_unconsumed, data: %{refs: refs}} | terminal]
  end

  defp terminal?(%Event{type: type}), do: type in [:agent_completed, :agent_error]

  defp as_completed(%Event{type: :agent_error}), do: event(:agent_completed, %{})
  defp as_completed(event), do: event

  # -- Plumbing -------------------------------------------------------------------------

  defp request(state, method, params, tag) do
    id = state.next_id
    send_line(state, RPC.request(id, method, params))
    %{state | next_id: id + 1, pending_out: Map.put(state.pending_out, id, tag)}
  end

  defp send_line(%{port: nil}, _line), do: :ok

  defp send_line(%{port: port}, line) do
    Port.command(port, line)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp broadcast(events, state) do
    Enum.each(events, fn %Event{} = event ->
      Engine.broadcast_event(state.repository_id, %Event{event | session_id: state.session_id})
    end)
  end

  defp event(type, data),
    do: %Event{type: type, data: data, raw_type: "codex:" <> Atom.to_string(type)}

  defp signal(%{os_pid: pid}, sig) when is_integer(pid) do
    System.cmd("kill", [sig, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp signal(_state, _sig), do: :ok

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp schedule_stall_check(state),
    do: Process.send_after(self(), :stall_check, max(div(state.stall_ms, 4), 250))

  defp stderr_tail(%{stderr_file: file}) when is_binary(file) do
    case File.read(file) do
      {:ok, text} ->
        text
        |> String.replace(~r/\e\[[0-9;]*m/, "")
        |> String.trim()
        |> String.slice(-@stderr_tail, @stderr_tail)

      _ ->
        ""
    end
  end

  defp stderr_tail(_state), do: ""

  defp stderr_suffix(state) do
    case stderr_tail(state) do
      "" -> ""
      tail -> ": " <> (tail |> String.split("\n") |> List.last())
    end
  end

  defp error_text(%{"message" => m}) when is_binary(m), do: m
  defp error_text(other), do: inspect(other)

  defp random_tag, do: :crypto.strong_rand_bytes(5) |> Base.url_encode64(padding: false)
end
