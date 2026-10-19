defmodule Canopy.Codex.Client do
  @moduledoc """
  A short-lived `codex app-server` for one-off calls outside a turn:
  `account/read` (the readiness check), `model/list` and the transcript's
  `thread/read` / `thread/turns/list`.

  `with_server(opts, fun)` spawns the server under a port owned by the
  calling process, initializes it, runs `fun.(call)` where `call.(method,
  params)` returns `{:ok, result} | {:error, reason}`, and closes it (stdin
  EOF, which ends the server). Notifications are ignored and any server
  request is refused, so a call never hangs on Codex asking something.

  Options: `:binary` (a path; required), `:config_dir` (`CODEX_HOME`),
  `:cwd`, `:timeout_ms` per call (default 15 s), `:extra_env`.
  """

  alias Canopy.Codex.{Command, RPC}

  @default_timeout_ms 15_000

  def with_server(opts, fun) when is_function(fun, 1) do
    binary = Keyword.fetch!(opts, :binary)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    env =
      Command.env(config_dir: opts[:config_dir], extra_env: opts[:extra_env] || extra_env())

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 1_000_000},
        {:args,
         ["-c", ~s(exec "$0" "$@" 2>/dev/null), binary, "app-server", "--listen", "stdio://"] ++
           ["-c", "notify=[]"]},
        {:cd, opts[:cwd] || System.tmp_dir!()},
        {:env, env}
      ])

    state = %{port: port, next: 1, timeout: timeout}

    try do
      with {:ok, _} <- call(state, "initialize", Command.client_info()) do
        Port.command(port, RPC.notification("initialized"))
        fun.(fn method, params -> call(state, method, params) end)
      end
    after
      close(port)
    end
  rescue
    e in ErlangError -> {:error, "could not run #{opts[:binary]}: #{Exception.message(e)}"}
  end

  defp call(state, method, params) do
    id = System.unique_integer([:positive])
    Port.command(state.port, RPC.request(id, method, params))
    await(state, id, "", System.monotonic_time(:millisecond) + state.timeout)
  rescue
    ArgumentError -> {:error, "codex app-server exited"}
  end

  defp await(state, id, buffer, deadline) do
    port = state.port
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await(state, id, buffer <> chunk, deadline)

      {^port, {:data, {:eol, chunk}}} ->
        case RPC.decode(buffer <> chunk) do
          {:response, ^id, result} ->
            {:ok, result}

          {:error, ^id, error} ->
            {:error, error["message"] || inspect(error)}

          {:request, rid, _method, _params} ->
            Port.command(port, RPC.error(rid, -32601, "not supported by Canopy"))
            await(state, id, "", deadline)

          _ ->
            await(state, id, "", deadline)
        end

      {^port, {:exit_status, status}} ->
        {:error, "codex app-server exited with status #{status}"}
    after
      remaining -> {:error, "codex app-server did not answer in time"}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    flush(port)
  rescue
    ArgumentError -> flush(port)
  end

  # whatever the port still had queued for this process
  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp extra_env,
    do: Keyword.get(Application.get_env(:canopy, :codex, []), :env, [])
end
