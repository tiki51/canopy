defmodule Canopy.ClaudeCode.Turn do
  @moduledoc """
  One `claude -p` process for one turn, driven through an Erlang port.

  Spawns the command, writes the prompt line, decodes every stdout line with
  `Canopy.ClaudeCode.Events`, and broadcasts the events on the engine topics
  under the session's id. Ends when the final `result` line arrives (the
  port is closed, which is the process's EOF) or the process exits first.

  Steering (`steer/3`): while the turn runs, more user lines can be written
  to stdin, each with a client `uuid` and `priority: "next"`, which Claude
  Code is believed to fold into the running turn between tool rounds (found
  in the 2.1.283 binary, not verified live: see the Agent Interrupt plan).
  One that arrives too late to fold runs as a further turn in the same
  process: a `result` with `queued_turn_count > 0` reports its usage but does
  not end the turn, and stdin and stdout stay open until a result with none
  queued. That final result's `:agent_completed` / `:agent_error` is preceded
  by `:prompts_unconsumed` for every written uuid no result listed in
  `user_message_uuids` (a CLI that never reports the field counts them all as
  read), and a process that dies or is killed reports every one of them, so
  the runtime sends them again. Steering is refused once the turn is done or
  being aborted, and below `:steer_min_version` (read from `system/init`).

  Recoveries, each tried once:

    * `--session-id` for a session Claude Code already knows ("already in
      use"), or `--resume` for one it does not ("No conversation found"): the
      command is rebuilt with the other flag.
    * A `result` with zero turns and no assistant output on an ordinary turn:
      Claude Code consumed the process on housekeeping and never sent the
      prompt (seen after an auto-backgrounded task); the turn is resent.

  Abort sends SIGINT; Claude Code then writes an `error_during_execution`
  result, which is reported as a completed turn rather than an error.
  A turn that prints nothing for `:stall_ms` is killed and reported as an
  error, unless it is waiting on a permission or question prompt
  (`Canopy.ClaudeCode.Prompts.waiting?/1`): the CLI prints nothing while the
  user decides, and the prompt's own timeout bounds that wait. The first check
  after the prompt closes restarts the stall window, so the resumed turn gets
  all of it. When the process ends, any prompt it still waited on is dropped.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Canopy.ClaudeCode.{Events, Prompts}
  alias Canopy.Engine
  alias Canopy.Engine.Event

  @default_stall_ms 120_000
  @abort_grace_ms 10_000
  @stderr_tail 600

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Interrupts the turn; the result still arrives and is reported as completed."
  def abort(server), do: GenServer.call(server, :abort)

  @doc """
  Writes a further user `line` (built with `Canopy.ClaudeCode.Command.user_message/2`,
  carrying `ref` as its uuid) into the running turn. `{:error, :not_running}`
  once the turn is done or being aborted; `{:error, :unsupported}` below the
  minimum CLI version, or before the CLI said which version it is.
  """
  def steer(server, line, ref) do
    GenServer.call(server, {:steer, line, ref})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      repository_id: Keyword.fetch!(opts, :repository_id),
      # fn flag -> %Canopy.ClaudeCode.Command{}; flag is :new or :resume
      command: Keyword.fetch!(opts, :command),
      flag: Keyword.get(opts, :flag, :new),
      message: Keyword.fetch!(opts, :message),
      stderr_file: Keyword.get(opts, :stderr_file),
      cwd: Keyword.get(opts, :cwd),
      compact?: Keyword.get(opts, :compact?, false),
      stall_ms: Keyword.get(opts, :stall_ms, @default_stall_ms),
      # nil: any CLI may be steered
      steer_min_version: Keyword.get(opts, :steer_min_version),
      # from system/init
      version: nil,
      # the uuids of the lines steer/3 wrote to this process, in order
      written_refs: [],
      # written to a process that was replaced (a resend): never read
      lost_refs: [],
      # every result's user_message_uuids, and whether any result had the field
      consumed_refs: MapSet.new(),
      uuids_reported?: false,
      # results seen; only the first may be a dropped prompt
      results: 0,
      port: nil,
      os_pid: nil,
      buffer: "",
      acc: Events.new(Keyword.get(opts, :cwd)),
      saw_assistant?: false,
      done?: false,
      aborted?: false,
      flag_retried?: false,
      resend_retried?: false,
      # whether the last stall check found a prompt open
      prompt_open?: false,
      last_line_at: System.monotonic_time(:millisecond)
    }

    {:ok, state, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state) do
    command = state.command.(state.flag)

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

    Port.command(port, state.message)
    schedule_stall_check(state)

    {:noreply,
     %{
       state
       | port: port,
         os_pid: os_pid,
         lost_refs: state.lost_refs ++ state.written_refs,
         written_refs: [],
         buffer: "",
         acc: Events.new(state.cwd),
         saw_assistant?: false,
         last_line_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call(:abort, _from, %{port: nil} = state), do: {:reply, {:error, :no_turn}, state}

  def handle_call(:abort, _from, state) do
    signal(state, "-INT")
    Process.send_after(self(), :abort_deadline, @abort_grace_ms)
    {:reply, :ok, %{state | aborted?: true}}
  end

  def handle_call({:steer, line, ref}, _from, state) do
    cond do
      state.port == nil or state.done? or state.aborted? ->
        {:reply, {:error, :not_running}, state}

      not steerable_version?(state) ->
        {:reply, {:error, :unsupported}, state}

      true ->
        Port.command(state.port, line)
        {:reply, :ok, %{state | written_refs: state.written_refs ++ [ref]}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    state = %{state | buffer: "", last_line_at: System.monotonic_time(:millisecond)}

    case JSON.decode(line) do
      {:ok, json} when is_map(json) -> handle_line(json, state)
      _ -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil}

    cond do
      state.done? ->
        {:stop, :normal, state}

      not state.flag_retried? and flag_mismatch(stderr_tail(state)) != nil ->
        other = flag_mismatch(stderr_tail(state))
        Logger.info("claude turn #{state.session_id}: retrying with --#{other}")
        {:noreply, %{state | flag: other, flag_retried?: true}, {:continue, :spawn}}

      true ->
        reason = "claude exited with status #{status}" <> stderr_suffix(state)
        fail(state, reason)
    end
  end

  def handle_info(:stall_check, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:stall_check, state) do
    waiting? = Prompts.waiting?(state.session_id)
    now = System.monotonic_time(:millisecond)

    cond do
      # Quiet because the user has not answered yet: not a stall. Nor is the
      # quiet just after the answer: the window restarts once the prompt has
      # closed, so the resumed turn gets all of it.
      waiting? or state.prompt_open? ->
        schedule_stall_check(state)
        {:noreply, %{state | last_line_at: now, prompt_open?: waiting?}}

      now - state.last_line_at > state.stall_ms ->
        stall(state)

      true ->
        schedule_stall_check(state)
        {:noreply, state}
    end
  end

  def handle_info(:abort_deadline, %{done?: false, port: port} = state) when port != nil do
    signal(state, "-KILL")
    fail(state, "aborted")
  end

  def handle_info(:abort_deadline, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp stall(state) do
    Logger.warning("claude turn #{state.session_id}: no output for #{state.stall_ms} ms, killing")

    signal(state, "-KILL")
    fail(state, "no output from claude for #{div(state.stall_ms, 1000)} s")
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      signal(state, "-KILL")
      close(state.port)
    end

    # whatever the process still waited on can never be read now
    drop_prompts(state.session_id)
    :ok
  end

  defp drop_prompts(session_id) do
    Prompts.drop_session(session_id)
  catch
    :exit, _ -> :ok
  end

  # -- Lines --------------------------------------------------------------------

  defp handle_line(%{"type" => "result"} = json, state) do
    {events, acc} = Events.normalize(json, state.acc)
    state = state |> Map.put(:acc, acc) |> note_consumed(json)

    cond do
      dropped_prompt?(json, state) ->
        Logger.info("claude turn #{state.session_id}: empty result before any output, resending")
        close(state.port)
        {:noreply, %{state | port: nil, resend_retried?: true}, {:continue, :spawn}}

      # A steered line that came too late to fold runs as a further turn in
      # this process: its usage counts, the turn goes on. An abort ends it.
      queued_turns(json) > 0 and not state.aborted? ->
        events |> Enum.reject(&terminal?/1) |> broadcast(state)
        {:noreply, %{state | results: state.results + 1}}

      true ->
        events
        |> Enum.map(&if(state.aborted?, do: as_completed(&1), else: &1))
        |> add_unconsumed(unconsumed(state))
        |> broadcast(state)

        close(state.port)
        {:stop, :normal, %{state | port: nil, done?: true}}
    end
  end

  defp handle_line(json, state) do
    {events, acc} = Events.normalize(json, state.acc)
    broadcast(events, state)
    saw? = state.saw_assistant? or json["type"] == "assistant"
    state = %{state | acc: acc, saw_assistant?: saw?}

    case json do
      %{"type" => "system", "subtype" => "init", "claude_code_version" => version}
      when is_binary(version) ->
        {:noreply, %{state | version: version}}

      _ ->
        {:noreply, state}
    end
  end

  defp queued_turns(%{"queued_turn_count" => n}) when is_integer(n), do: n
  defp queued_turns(_json), do: 0

  defp terminal?(%Event{type: type}), do: type in [:agent_completed, :agent_error]

  defp note_consumed(state, %{"user_message_uuids" => uuids}) when is_list(uuids),
    do: %{
      state
      | consumed_refs: MapSet.union(state.consumed_refs, MapSet.new(uuids)),
        uuids_reported?: true
    }

  defp note_consumed(state, _json), do: state

  # What the turn never read: lines written to a process that was replaced,
  # and, when the CLI reports what it consumed, every written line it did not
  # list. A CLI that never reports the field counts them as read.
  defp unconsumed(state) do
    read =
      if state.uuids_reported?,
        do: Enum.reject(state.written_refs, &MapSet.member?(state.consumed_refs, &1)),
        else: []

    state.lost_refs ++ read
  end

  # Just before the terminal event, so the runtime knows before the turn closes.
  defp add_unconsumed(events, []), do: events

  defp add_unconsumed(events, refs) do
    {before, terminal} = Enum.split_with(events, &(not terminal?(&1)))
    before ++ [%Event{type: :prompts_unconsumed, data: %{refs: refs}} | terminal]
  end

  defp steerable_version?(%{steer_min_version: nil}), do: true
  defp steerable_version?(%{version: nil}), do: false

  defp steerable_version?(%{version: version, steer_min_version: min}) do
    with {:ok, have} <- Version.parse(version),
         {:ok, need} <- Version.parse(min) do
      Version.compare(have, need) != :lt
    else
      _ -> false
    end
  end

  # Claude Code answered without ever calling the model on a turn that asked
  # for work: the prompt was lost to housekeeping. Compaction turns look the
  # same and are fine.
  defp dropped_prompt?(json, state) do
    state.results == 0 and not state.compact? and not state.resend_retried? and
      not state.saw_assistant? and
      json["num_turns"] == 0 and (json["result"] || "") == ""
  end

  defp as_completed(%Event{type: :agent_error}), do: %Event{type: :agent_completed, data: %{}}
  defp as_completed(event), do: event

  defp broadcast(events, state) do
    Enum.each(events, fn %Event{} = event ->
      Engine.broadcast_event(state.repository_id, %Event{event | session_id: state.session_id})
    end)
  end

  # Whatever was written to the process is unread as far as anyone knows.
  defp fail(state, reason) do
    broadcast(
      add_unconsumed(
        [
          %Event{
            type: :agent_error,
            data: %{error: %{"name" => "claude", "data" => %{"message" => reason}}}
          }
        ],
        state.lost_refs ++ state.written_refs
      ),
      state
    )

    if state.port, do: close(state.port)
    {:stop, :normal, %{state | port: nil, done?: true}}
  end

  # -- Process control ------------------------------------------------------------

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
      {:ok, text} -> text |> String.trim() |> String.slice(-@stderr_tail, @stderr_tail)
      _ -> ""
    end
  end

  defp stderr_tail(_state), do: ""

  defp stderr_suffix(state) do
    case stderr_tail(state) do
      "" -> ""
      tail -> ": " <> (tail |> String.split("\n") |> List.last())
    end
  end

  defp flag_mismatch(tail) do
    cond do
      String.contains?(tail, "already in use") -> :resume
      String.contains?(tail, "No conversation found") -> :new
      true -> nil
    end
  end
end
