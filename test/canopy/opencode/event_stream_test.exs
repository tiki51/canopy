defmodule Canopy.OpenCode.EventStreamTest do
  # Runs a real Bandit server that speaks SSE, so this cannot share the Req.Test plug.
  use ExUnit.Case, async: false

  alias Canopy.Engine.Event
  alias Canopy.OpenCode.EventStream
  alias Canopy.OpenCodeFixtures, as: Fixtures

  defmodule FakeOpenCode do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/event"} = conn, opts) do
      conn = fetch_query_params(conn)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:connected, conn.query_params["directory"]})

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, "data: {\"type\":\"server.connected\",\"properties\":{}}\n\n")
      {:ok, conn} = chunk(conn, Fixtures.sse(Keyword.fetch!(opts, :fixture)))
      # keep the connection open briefly so the client can drain it, then close
      Process.sleep(100)
      conn
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  setup do
    port = free_port()
    fixture = "turn_read_bash_patch"
    Req.Test.set_req_test_to_shared()
    # bypass the Req.Test plug configured in test.exs for this real server
    original = Application.get_env(:canopy, :opencode)
    Application.put_env(:canopy, :opencode, Keyword.delete(original, :req_options))
    on_exit(fn -> Application.put_env(:canopy, :opencode, original) end)

    {:ok, _} =
      start_supervised(
        {Bandit,
         plug: {FakeOpenCode, test_pid: self(), fixture: fixture},
         port: port,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, base_url: "http://127.0.0.1:#{port}"}
  end

  test "streams normalized events to the session topic once and reconnects when closed", %{
    base_url: base_url
  } do
    repo_id = "repo_test_#{System.unique_integer([:positive])}"
    session = "ses_f7afbd250ffeYpTVGJ30g9OyRZ"
    Phoenix.PubSub.subscribe(Canopy.PubSub, EventStream.session_topic(session))

    test_pid = self()

    spawn_link(fn ->
      Phoenix.PubSub.subscribe(Canopy.PubSub, EventStream.repository_topic(repo_id))
      send(test_pid, :relay_ready)

      relay = fn relay ->
        receive do
          msg -> send(test_pid, {:relayed, msg})
        end

        relay.(relay)
      end

      relay.(relay)
    end)

    assert_receive :relay_ready

    {:ok, pid} =
      EventStream.start_link(repository_id: repo_id, directory: "/repo/path", base_url: base_url)

    assert_receive {:connected, "/repo/path"}, 2_000

    # tool telemetry arrives on the session topic
    assert_receive {:engine_event,
                    %Event{type: :tool_started, session_id: ^session, data: %{tool: "read"}}},
                   2_000

    # text deltas are attributed and reasoning deltas dropped
    assert_receive {:engine_event, %Event{type: :text_delta, data: %{delta: delta}}}, 2_000
    assert is_binary(delta)
    refute_received {:engine_event, %Event{type: :part_delta}}

    assert_receive {:engine_event, %Event{type: :agent_completed, session_id: ^session}}, 2_000

    # ...and only there: a subscriber to the repository topic alone sees the
    # connect notice but no session-bearing event
    assert_receive {:relayed, {:engine_stream, :connected, ^repo_id}}, 2_000
    refute_received {:relayed, {:engine_event, %Event{session_id: ^session}}}

    # the fake server closes the connection; the stream reconnects after backoff (1 s)
    assert_receive {:connected, "/repo/path"}, 5_000
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "supervisor starts one stream per repository", %{base_url: base_url} do
    repo_id = "repo_sup_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Canopy.OpenCode.Supervisor.start_stream(repo_id, "/repo", base_url: base_url)

    assert {:ok, ^pid} =
             Canopy.OpenCode.Supervisor.start_stream(repo_id, "/repo", base_url: base_url)

    assert Canopy.OpenCode.Supervisor.stream_pid(repo_id) == pid
    ref = Process.monitor(pid)
    assert :ok = Canopy.OpenCode.Supervisor.stop_stream(repo_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    # Registry drops the entry asynchronously after the process exits
    assert eventually(fn -> Canopy.OpenCode.Supervisor.stream_pid(repo_id) == nil end)
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
