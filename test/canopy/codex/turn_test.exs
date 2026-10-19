defmodule Canopy.Codex.TurnTest do
  use ExUnit.Case, async: false

  alias Canopy.Codex.{Command, Supervisor, Turn}
  alias Canopy.Engine
  alias Canopy.Engine.Event

  @fake Path.expand("../../support/fake_codex.sh", __DIR__)
  @fixtures Path.expand("../../support/codex_fixtures", __DIR__)
  @thread "019a0000-0000-7000-8000-000000000001"

  setup do
    dir = Path.join([File.cwd!(), "_build", "test", "tmp", "codex-" <> suffix()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    sid = Ecto.UUID.generate()
    :ok = Engine.subscribe_session(sid)
    :ok = Engine.subscribe_session(@thread)
    {:ok, dir: dir, sid: sid, log: Path.join(dir, "calls.log")}
  end

  defp suffix, do: System.unique_integer([:positive]) |> Integer.to_string(36)

  defp fixture(name), do: Path.join(@fixtures, name)

  defp script!(dir, lines) do
    path = Path.join(dir, "script-#{suffix()}.jsonl")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp work_dir(ctx), do: fn sid -> Path.join([ctx.dir, "work", sid]) end

  defp start(ctx, env, opts \\ []) do
    sid = Keyword.get(opts, :sid, ctx.sid)
    mode = Keyword.get(opts, :permission_mode, "acceptEdits")
    {sandbox, approval} = Command.policy(mode)
    File.mkdir_p!(work_dir(ctx).(sid))
    test = self()

    command =
      Command.build(
        binary: @fake,
        cwd: ctx.dir,
        stderr_file: Path.join(work_dir(ctx).(sid), "stderr.log"),
        mcp_url: "http://127.0.0.1:4002/mcp",
        token: "tok-123",
        extra_env: [{"FAKE_CODEX_LOG", ctx.log} | env]
      )

    turn_opts =
      [
        repository_id: "repo_test",
        cwd: ctx.dir,
        command: command,
        flag: Keyword.get(opts, :flag, :new),
        thread_params: %{
          "cwd" => ctx.dir,
          "sandbox" => sandbox,
          "approvalPolicy" => approval,
          "approvalsReviewer" => "user"
        },
        turn_params: %{
          "input" => [%{"type" => "text", "text" => "do it", "text_elements" => []}],
          "approvalPolicy" => approval,
          "approvalsReviewer" => "user",
          "sandboxPolicy" => Command.sandbox_policy(mode, ctx.dir)
        },
        system: Keyword.get(opts, :system, "You are a Canopy agent."),
        permission_mode: mode,
        work_dir: work_dir(ctx),
        on_thread_id: fn old, new ->
          send(test, {:renamed, old, new})
          :ok
        end
      ]
      |> Keyword.merge(Keyword.drop(opts, [:sid, :permission_mode, :flag, :system]))

    {:ok, pid} = Supervisor.start_turn(sid, turn_opts)
    Process.monitor(pid)
    pid
  end

  defp sent(log, method) do
    for "STDIN " <> json <- log |> File.read!() |> String.split("\n"),
        {:ok, %{"method" => ^method} = msg} <- [JSON.decode(json)],
        do: msg
  end

  defp responses(log) do
    for "STDIN " <> json <- log |> File.read!() |> String.split("\n"),
        {:ok, %{"id" => _} = msg} <- [JSON.decode(json)],
        not Map.has_key?(msg, "method"),
        do: msg
  end

  defp await_event(type, timeout \\ 3_000) do
    receive do
      {:engine_event, %Event{type: ^type} = event} -> event
    after
      timeout -> flunk("no #{type} event")
    end
  end

  defp await_down(pid) do
    receive do
      {:DOWN, _, :process, ^pid, reason} -> reason
    after
      5_000 -> flunk("turn did not end")
    end
  end

  describe "a first turn" do
    test "starts a thread, renames the session and reports the turn under the thread id",
         ctx do
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}])

      assert_receive {:renamed, sid, @thread}, 3_000
      assert sid == ctx.sid

      assert %Event{session_id: @thread, data: %{session: %{"model" => "gpt-5-codex"}}} =
               await_event(:session_updated)

      assert %Event{session_id: @thread} = await_event(:agent_status)
      assert %Event{data: %{delta: "Hello from Codex."}} = await_event(:text_delta)
      assert %Event{data: %{text: "Hello from Codex."}} = await_event(:text_done)

      step = await_event(:step_completed)
      assert step.data.tokens["input"] == 600
      assert step.data.tokens["cache"]["read"] == 400
      assert step.data.cost_estimated == true

      usage = await_event(:turn_usage)
      assert usage.data.cost_estimated == true
      assert usage.data.tokens["output"] == 100
      assert usage.data.cost > 0
      assert %Event{session_id: @thread} = await_event(:agent_completed)
      assert await_down(pid) == :normal

      # the duplicate usage update counted once
      refute_received {:engine_event, %Event{type: :step_completed}}

      assert [start] = sent(ctx.log, "thread/start")
      assert start["params"]["developerInstructions"] == "You are a Canopy agent."
      assert start["params"]["approvalsReviewer"] == "user"
      assert start["params"]["sandbox"] == "workspace-write"
      assert start["params"]["approvalPolicy"] == "on-request"

      assert [turn] = sent(ctx.log, "turn/start")
      assert turn["params"]["threadId"] == @thread
      assert turn["params"]["approvalsReviewer"] == "user"
      assert turn["params"]["sandboxPolicy"]["writableRoots"] == [Command.resolve(ctx.dir)]
      assert turn["params"]["sandboxPolicy"]["networkAccess"] == false
      assert sent(ctx.log, "thread/inject_items") == []

      log = File.read!(ctx.log)
      assert log =~ ~s(notify=[])
      refute log =~ "tok-123"
      assert log =~ "TOKEN_SHA256"

      # the work dir followed the thread
      assert File.read!(Path.join(work_dir(ctx).(@thread), "instructions.sha256")) =~
               ~r/^[0-9a-f]{64}$/
    end

    test "a session reset before the rename ends the turn quietly, before turn/start", ctx do
      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}],
          on_thread_id: fn _old, _new -> {:error, :session_gone} end
        )

      assert %Event{session_id: sid} = await_event(:agent_completed)
      assert sid == ctx.sid
      assert await_down(pid) == :normal
      refute_received {:engine_event, %Event{type: :agent_error}}
      assert sent(ctx.log, "turn/start") == []
    end

    test "registers under the placeholder and the thread id while it runs", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          ~s({"sleep":400}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      _ = await_event(:agent_status)
      assert Supervisor.whereis(ctx.sid) == pid
      assert Supervisor.whereis(@thread) == pid
      assert ctx.sid in Supervisor.running() and @thread in Supervisor.running()
      await_down(pid)
    end

    test "a retry names the thread id, never the placeholder", ctx do
      retry =
        ~s({"send":{"method":"error","params":{"threadId":"$THREAD","turnId":"$TURN","willRetry":true,"error":{"message":"Reconnecting... 1/5","codexErrorInfo":null,"additionalDetails":null}}}})

      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          retry,
          ~s({"sleep":400}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      assert_receive {:engine_event, %Event{type: :agent_status, data: %{status: :retry}}}, 2000

      assert %{session_id: @thread, message: "Reconnecting... 1/5", attempt: 1} =
               Turn.retrying(pid)

      await_down(pid)
    end
  end

  describe "resume" do
    test "resumes with excludeTurns, counts from the replayed totals and renames nothing", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          usage_line(6000, 2000, 600),
          usage_line(6000, 2000, 600),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}], sid: @thread, flag: :resume)

      usage = await_event(:turn_usage)
      # the replay was 5000 in (2000 cached) / 500 out
      assert usage.data.tokens["input"] == 1000
      assert usage.data.tokens["output"] == 100
      assert usage.data.tokens["cache"]["read"] == 0
      await_event(:agent_completed)
      await_down(pid)

      refute_received {:renamed, _, _}
      assert [resume] = sent(ctx.log, "thread/resume")
      assert resume["params"]["threadId"] == @thread
      assert resume["params"]["excludeTurns"] == true
      assert resume["params"]["approvalsReviewer"] == "user"
      refute Map.has_key?(resume["params"], "developerInstructions")
    end

    test "a thread with no rollout starts again as a new thread and renames", ctx do
      old = Ecto.UUID.generate()

      pid =
        start(
          ctx,
          [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}, {"FAKE_CODEX_RESUME", "not_found"}],
          sid: old,
          flag: :resume
        )

      assert_receive {:renamed, ^old, @thread}, 3_000
      await_event(:agent_completed)
      await_down(pid)
      assert [_] = sent(ctx.log, "thread/resume")
      assert [start] = sent(ctx.log, "thread/start")
      assert start["params"]["developerInstructions"]
    end

    test "thread/start and thread/resume never let Codex mark the repo trusted", ctx do
      old = Ecto.UUID.generate()

      pid =
        start(
          ctx,
          [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}, {"FAKE_CODEX_RESUME", "not_found"}],
          sid: old,
          flag: :resume
        )

      await_event(:agent_completed)
      await_down(pid)
      untrusted = %{"projects" => %{ctx.dir => %{"trust_level" => "untrusted"}}}
      assert [resume] = sent(ctx.log, "thread/resume")
      assert [start] = sent(ctx.log, "thread/start")
      assert resume["params"]["config"] == untrusted
      assert start["params"]["config"] == untrusted
      assert start["params"]["sandbox"] == "workspace-write"
    end
  end

  describe "instructions" do
    test "a resume after a change injects the new text as a developer message, once", ctx do
      opts = [sid: @thread, flag: :resume, system: "Version two."]
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}], opts)
      await_down(pid)

      assert [inject] = sent(ctx.log, "thread/inject_items")
      assert [item] = inject["params"]["items"]
      assert item["role"] == "developer"
      assert [%{"text" => text}] = item["content"]
      assert text =~ "Your Canopy instructions have changed"
      assert text =~ "Version two."

      # before turn/start
      methods = ctx.log |> File.read!() |> String.split("\n") |> Enum.flat_map(&method/1)

      assert Enum.find_index(methods, &(&1 == "thread/inject_items")) <
               Enum.find_index(methods, &(&1 == "turn/start"))

      # the same text again: nothing more is sent
      File.rm!(ctx.log)
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}], opts)
      await_down(pid)
      assert sent(ctx.log, "thread/inject_items") == []
    end

    test "a failed inject keeps the old hash and the turn still runs", ctx do
      hash_file = Path.join(work_dir(ctx).(@thread), "instructions.sha256")
      File.mkdir_p!(Path.dirname(hash_file))
      File.write!(hash_file, "old")

      script =
        script!(ctx.dir, [
          ~s({"await_thread":true}),
          ~s({"await":"thread/inject_items"}),
          ~s({"send":{"id":$ID,"error":{"code":-32600,"message":"no"}}}),
          ~s({"await":"turn/start"}),
          ~s({"send":{"id":$ID,"result":{"turn":{"id":"$TURN"}}}}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}], sid: @thread, flag: :resume)
      await_event(:agent_completed)
      await_down(pid)
      assert File.read!(hash_file) == "old"
    end
  end

  describe "approvals" do
    test "a command card's reply goes back to Codex as its decision", ctx do
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-approval-command.jsonl")}])

      %Event{data: %{request: request}} = await_event(:approval_required)
      assert request["permission"] == "Bash"
      assert request["metadata"]["command"] == "npm install csv-stringify"
      assert request["metadata"]["network"] == true
      assert request["metadata"]["unsandboxed"] == true
      refute Map.has_key?(request["metadata"], "once_only")
      assert request["metadata"]["always_prefix"] == "npm install"

      assert [_] = Turn.open_events(pid)
      assert :ok = Turn.answer(pid, request["id"], :once)
      assert {:error, :gone} = Turn.answer(pid, request["id"], :once)
      await_event(:agent_completed)
      await_down(pid)

      assert [%{"id" => 0, "result" => %{"decision" => "accept"}}] = responses(ctx.log)
    end

    test "a plan agent's command card is once-only and Always is answered as Once", ctx do
      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-approval-command.jsonl")}],
          permission_mode: "plan"
        )

      %Event{data: %{request: request}} = await_event(:approval_required)
      assert request["metadata"]["unsandboxed"] == true
      assert request["metadata"]["once_only"] == true
      assert :ok = Turn.answer(pid, request["id"], :always)
      await_down(pid)

      assert [%{"result" => %{"decision" => "accept"}}] = responses(ctx.log)

      assert Canopy.Codex.Approvals.rules(@thread) |> Enum.filter(&match?({:command, _, _}, &1)) ==
               []
    end

    test "an Always is remembered for the session's later turns", ctx do
      sid = "019a0000-0000-7000-8000-00000000c0de"
      :ok = Engine.subscribe_session(sid)
      on_exit(fn -> Canopy.Codex.Approvals.forget(sid) end)

      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-approval-command.jsonl")}],
          sid: sid,
          flag: :resume
        )

      %Event{data: %{request: request}} = await_event(:approval_required)
      :ok = Turn.answer(pid, request["id"], :always)
      await_down(pid)
      assert [%{"result" => %{"decision" => "acceptForSession"}}] = responses(ctx.log)
      assert [{:command, ["npm", "install"], _}] = Canopy.Codex.Approvals.rules(sid)

      # the next turn's same request is answered without a card
      File.rm!(ctx.log)

      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-approval-command.jsonl")}],
          sid: sid,
          flag: :resume
        )

      await_event(:agent_completed)
      await_down(pid)
      refute_received {:engine_event, %Event{type: :approval_required}}
      assert [%{"result" => %{"decision" => "acceptForSession"}}] = responses(ctx.log)
    end

    test "an unanswered card expires: Codex hears decline and the card detaches", ctx do
      prev = Application.get_env(:canopy, :claude_code, [])
      Application.put_env(:canopy, :claude_code, Keyword.put(prev, :prompt_timeout_ms, 200))
      on_exit(fn -> Application.put_env(:canopy, :claude_code, prev) end)

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-approval-command.jsonl")}])
      %Event{data: %{request: %{"id" => id}}} = await_event(:approval_required)
      assert %Event{data: %{request_id: ^id}} = await_event(:approval_expired)
      await_down(pid)
      assert [%{"result" => %{"decision" => "decline"}}] = responses(ctx.log)
    end

    test "a request Codex withdraws detaches its card", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          ~s({"send":{"method":"item/fileChange/requestApproval","id":0,"params":{"threadId":"$THREAD","turnId":"$TURN","itemId":"x"}}}),
          ~s({"sleep":200}),
          ~s({"send":{"method":"serverRequest/resolved","params":{"threadId":"$THREAD","requestId":0}}}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      %Event{data: %{request: %{"id" => id}}} = await_event(:approval_required)
      assert %Event{data: %{request_id: ^id}} = await_event(:approval_expired)
      await_down(pid)
      assert Turn.answer(pid, id, :once) == {:error, :gone}
    end

    test "a plan agent's file change is declined with no card", ctx do
      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-approval-file.jsonl")}],
          permission_mode: "plan"
        )

      await_event(:agent_completed)
      await_down(pid)
      refute_received {:engine_event, %Event{type: :approval_required}}
      assert [%{"result" => %{"decision" => "decline"}}] = responses(ctx.log)
    end

    test "ask first accepts a plain git command itself", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          ~s({"send":{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"$THREAD","turnId":"$TURN","itemId":"x","command":"/bin/zsh -lc 'git status'","commandActions":[{"type":"unknown","command":"git status"}]}}}),
          ~s({"await_response":0}),
          ~s({"send":{"method":"item/commandExecution/requestApproval","id":1,"params":{"threadId":"$THREAD","turnId":"$TURN","itemId":"y","command":"/bin/zsh -lc 'git status; ls'","commandActions":[{"type":"unknown","command":"git status; ls"}]}}}),
          ~s({"await_response":1}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}], permission_mode: "default")
      %Event{data: %{request: request}} = await_event(:approval_required)
      assert request["patterns"] == ["git status; ls"]
      refute Map.has_key?(request["metadata"], "unsandboxed")
      :ok = Turn.answer(pid, request["id"], :reject)
      await_down(pid)

      assert [
               %{"id" => 0, "result" => %{"decision" => "accept"}},
               %{"id" => 1, "result" => %{"decision" => "decline"}}
             ] = responses(ctx.log)
    end

    test "a question card's answers go back keyed by question id", ctx do
      # the question wait otherwise comes from Settings
      prev = Application.get_env(:canopy, :claude_code, [])
      Application.put_env(:canopy, :claude_code, Keyword.put(prev, :question_wait_ms, 60_000))
      on_exit(fn -> Application.put_env(:canopy, :claude_code, prev) end)

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-question.jsonl")}])
      %Event{data: %{request: request}} = await_event(:question_required)
      assert [%{"question" => "Which database?", "custom" => true}] = request["questions"]
      :ok = Turn.answer(pid, request["id"], {:answered, [["SQLite"]]})
      await_event(:agent_completed)
      await_down(pid)

      assert [%{"result" => %{"answers" => %{"q1" => %{"answers" => ["SQLite"]}}}}] =
               responses(ctx.log)
    end

    test "an unknown server request gets an error reply at once", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          ~s({"send":{"method":"item/tool/call","id":0,"params":{"threadId":"$THREAD"}}}),
          ~s({"await_response":0}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      await_event(:agent_completed)
      await_down(pid)
      assert [%{"id" => 0, "error" => %{"code" => -32601}}] = responses(ctx.log)
    end
  end

  describe "steer" do
    test "a steered message is consumed when Codex echoes its client id", ctx do
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("steer.jsonl")}])
      await_event(:tool_started)
      assert :ok = Turn.steer(pid, [%{"type" => "text", "text" => "also this"}], "ref-1")
      await_event(:agent_completed)
      await_down(pid)
      refute_received {:engine_event, %Event{type: :prompts_unconsumed}}

      assert [steer] = sent(ctx.log, "turn/steer")
      assert steer["params"]["clientUserMessageId"] == "ref-1"
      assert steer["params"]["expectedTurnId"]
    end

    test "a steer never echoed is reported unconsumed before the end", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          ~s({"await":"turn/steer"}),
          ~s({"send":{"id":$ID,"result":{"turnId":"$TURN"}}}),
          completed_line()
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      await_event(:agent_status)
      Process.sleep(100)
      assert :ok = Turn.steer(pid, [], "ref-2")
      assert %Event{data: %{refs: ["ref-2"]}} = await_event(:prompts_unconsumed)
      await_event(:agent_completed)
      await_down(pid)
    end

    test "is refused before the turn has an id", ctx do
      script =
        script!(ctx.dir, [
          ~s({"await_thread":true}),
          ~s({"await":"turn/start"}),
          ~s({"sleep":2000})
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      assert {:error, :not_running} = Turn.steer(pid, [], "ref")
      Turn.abort(pid)
      await_down(pid)
    end
  end

  describe "abort" do
    test "interrupts the turn, which completes with its usage", ctx do
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-hang.jsonl")}])
      await_event(:agent_status)
      Process.sleep(100)
      assert :ok = Turn.abort(pid)
      assert %Event{data: %{finish: "interrupted"}} = await_event(:turn_usage)
      await_event(:agent_completed)
      await_down(pid)
      assert [_] = sent(ctx.log, "turn/interrupt")
    end

    test "before the turn has an id, kills the process and completes", ctx do
      script =
        script!(ctx.dir, [
          ~s({"await_thread":true}),
          ~s({"await":"turn/start"}),
          ~s({"sleep":5000})
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      Process.sleep(300)
      assert {:ok, :killed} = Turn.abort(pid)
      await_event(:agent_completed)
      await_down(pid)
    end

    # The channel server stops a turn that is waiting for that server's rename
    # ack: the call gives up instead of exiting the caller, and the turn acts on
    # the abort once the rename is through.
    test "a turn busy renaming its session takes the abort later; the caller never exits",
         ctx do
      script =
        script!(ctx.dir, [
          ~s({"await_thread":true}),
          ~s({"await":"turn/start"}),
          ~s({"sleep":5000})
        ])

      test = self()

      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", script}],
          on_thread_id: fn _old, _new ->
            send(test, {:renaming, self()})
            receive do: (:ack -> :ok)
          end
        )

      assert_receive {:renaming, ^pid}, 3_000
      assert {:ok, :pending} = Turn.abort(pid, 100)
      send(pid, :ack)
      await_event(:agent_completed)
      await_down(pid)
      assert sent(ctx.log, "turn/interrupt") == []
    end

    test "a turn that has already ended is no turn", ctx do
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")}])
      await_event(:agent_completed)
      await_down(pid)
      assert {:error, :no_turn} = Turn.abort(pid)
    end
  end

  describe "stall" do
    test "no output for the stall window kills the turn", ctx do
      script =
        script!(ctx.dir, [
          ~s({"include":"#{fixture("turn-start.jsonl")}"}),
          ~s({"sleep":3000})
        ])

      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}], stall_ms: 300)
      %Event{data: %{error: error}} = await_event(:agent_error)
      assert error["data"]["message"] =~ "no output from codex"
      await_down(pid)
    end

    test "a command still running is not a stall", ctx do
      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-command-open.jsonl")}], stall_ms: 300)

      await_event(:agent_completed, 5_000)
      await_down(pid)
      refute_received {:engine_event, %Event{type: :agent_error}}
    end

    test "but the item ceiling still applies", ctx do
      pid =
        start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-command-open.jsonl")}],
          stall_ms: 300,
          item_stall_ms: 500
        )

      %Event{data: %{error: error}} = await_event(:agent_error, 5_000)
      assert error["data"]["message"] =~ "no output from codex"
      await_down(pid)
    end
  end

  describe "failures" do
    test "a process that exits early is an error with its status", ctx do
      script = script!(ctx.dir, [~s({"await":"initialize"}), ~s({"exit":3})])
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", script}])
      %Event{data: %{error: error}} = await_event(:agent_error)
      assert error["data"]["message"] =~ "codex exited with status 3"
      await_down(pid)
    end

    test "a failed turn reports its usage and Codex's error", ctx do
      pid = start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("turn-failed.jsonl")}])
      await_event(:turn_usage)
      %Event{data: %{error: error}} = await_event(:agent_error)
      assert error["name"] == "badRequest"
      assert error["data"]["message"] =~ "does not exist"
      await_down(pid)
    end
  end

  test "compaction runs thread/compact/start and reports the turn", ctx do
    pid =
      start(ctx, [{"FAKE_CODEX_SCRIPT", fixture("compact.jsonl")}],
        sid: @thread,
        flag: :resume,
        compact?: true
      )

    assert %Event{data: %{message: %{"compact" => _}}} = await_event(:message_updated)
    await_event(:agent_completed)
    await_down(pid)
    assert [_] = sent(ctx.log, "thread/compact/start")
    assert sent(ctx.log, "turn/start") == []
  end

  defp method(line) do
    with "STDIN " <> json <- line,
         {:ok, %{"method" => m}} <- JSON.decode(json) do
      [m]
    else
      _ -> []
    end
  end

  defp usage_line(input, cached, output) do
    b = %{
      "totalTokens" => input + output,
      "inputTokens" => input,
      "cachedInputTokens" => cached,
      "cacheWriteInputTokens" => 0,
      "outputTokens" => output,
      "reasoningOutputTokens" => 0
    }

    JSON.encode!(%{
      "send" => %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "threadId" => "$THREAD",
          "turnId" => "$TURN",
          "tokenUsage" => %{"total" => b, "last" => b, "modelContextWindow" => 258_400}
        }
      }
    })
  end

  defp completed_line,
    do:
      ~s({"send":{"method":"turn/completed","params":{"threadId":"$THREAD","turn":{"id":"$TURN","status":"completed","items":[],"error":null}}}})
end
