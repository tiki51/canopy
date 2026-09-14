defmodule Canopy.ClaudeCode.Turn do
  @moduledoc """
  One `claude -p` process for one turn, driven through an Erlang port.

  Spawns the command, writes the prompt line, decodes every stdout line with
  `Canopy.ClaudeCode.Events`, and broadcasts the events on the engine topics
  under the session's id. Ends when the `result` line arrives (the port is
  closed, which is the process's EOF) or the process exits first.

  Recoveries, each tried once:

    * `--session-id` for a session Claude Code already knows ("already in
      use"), or `--resume` for one it does not ("No conversation found"): the
      command is rebuilt with the other flag.
    * A `result` with zero turns and no assistant output on an ordinary turn:
      Claude Code consumed the process on housekeeping and never sent the
      prompt (seen after an auto-backgrounded task); the turn is resent.

  Abort sends SIGINT; Claude Code then writes an `error_during_execution`
  result, which is reported as a completed turn rather than an error.
  A turn that prints nothing for `:stall_ms` is killed and reported as an error.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Canopy.ClaudeCode.Events
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
      port: nil,
      os_pid: nil,
      buffer: "",
      acc: Events.new(Keyword.get(opts, :cwd)),
      saw_assistant?: false,
      done?: false,
      aborted?: false,
      flag_retried?: false,
      resend_retried?: false,
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
    if System.monotonic_time(:millisecond) - state.last_line_at > state.stall_ms do
      Logger.warning(
        "claude turn #{state.session_id}: no output for #{state.stall_ms} ms, killing"
      )

      signal(state, "-KILL")
      fail(state, "no output from claude for #{div(state.stall_ms, 1000)} s")
    else
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

  @impl true
  def terminate(_reason, %{port: port} = state) when port != nil do
    signal(state, "-KILL")
    close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Lines --------------------------------------------------------------------

  defp handle_line(%{"type" => "result"} = json, state) do
    {events, acc} = Events.normalize(json, state.acc)
    state = %{state | acc: acc}

    cond do
      dropped_prompt?(json, state) ->
        Logger.info("claude turn #{state.session_id}: empty result before any output, resending")
        close(state.port)
        {:noreply, %{state | port: nil, resend_retried?: true}, {:continue, :spawn}}

      true ->
        events
        |> Enum.map(&if(state.aborted?, do: as_completed(&1), else: &1))
        |> broadcast(state)

        close(state.port)
        {:stop, :normal, %{state | port: nil, done?: true}}
    end
  end

  defp handle_line(json, state) do
    {events, acc} = Events.normalize(json, state.acc)
    broadcast(events, state)
    saw? = state.saw_assistant? or json["type"] == "assistant"
    {:noreply, %{state | acc: acc, saw_assistant?: saw?}}
  end

  # Claude Code answered without ever calling the model on a turn that asked
  # for work: the prompt was lost to housekeeping. Compaction turns look the
  # same and are fine.
  defp dropped_prompt?(json, state) do
    not state.compact? and not state.resend_retried? and not state.saw_assistant? and
      json["num_turns"] == 0 and (json["result"] || "") == ""
  end

  defp as_completed(%Event{type: :agent_error}), do: %Event{type: :agent_completed, data: %{}}
  defp as_completed(event), do: event

  defp broadcast(events, state) do
    Enum.each(events, fn %Event{} = event ->
      Engine.broadcast_event(state.repository_id, %Event{event | session_id: state.session_id})
    end)
  end

  defp fail(state, reason) do
    broadcast(
      [
        %Event{
          type: :agent_error,
          data: %{error: %{"name" => "claude", "data" => %{"message" => reason}}}
        }
      ],
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
