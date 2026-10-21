defmodule Canopy.Engine.CodexTest do
  @moduledoc "The Codex adapter: its readiness check, and a Codex agent driven through the channel runtime with the fake binary."
  use Canopy.DataCase, async: false

  alias Canopy.{AgentSessions, Fixtures, GlobalPermissions, PermissionRequests, Runtime, Timeline}
  alias Canopy.Engine.Codex
  alias Canopy.MCP.Identity

  @fake Path.expand("../../support/fake_codex.sh", __DIR__)
  @fixtures Path.expand("../../support/codex_fixtures", __DIR__)

  setup do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "tmp",
        "codex-engine-" <> Fixtures.unique_suffix()
      ])

    File.mkdir_p!(dir)
    previous = Application.get_env(:canopy, :codex)
    thread = Ecto.UUID.generate()

    on_exit(fn ->
      Application.put_env(:canopy, :codex, previous)
      File.rm_rf(dir)
    end)

    # the version is cached per binary; tests vary it
    :ets.match_delete(Canopy.Codex.Supervisor.cache(), {{:version, :_, :_}, :_})
    {:ok, dir: dir, log: Path.join(dir, "calls.log"), thread: thread, previous: previous}
  end

  defp put_env(ctx, env, extra \\ []) do
    Application.put_env(
      :canopy,
      :codex,
      ctx.previous
      |> Keyword.merge(binary: @fake, env: env)
      |> Keyword.merge(extra)
    )
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "check/2 and readiness/1" do
    test "signed in with ChatGPT: version, plan and email", ctx do
      put_env(ctx, [])
      assert {:ok, check} = Codex.check(@fake, nil)
      assert check.version == "9.9.9"
      assert check.logged_in
      assert check.auth_method == "chatgpt"
      assert check.plan == "Pro"
      assert check.email == "dev@example.com"
      assert check.path == @fake
      assert Codex.readiness({:ok, check}) == :ready
    end

    test "signed out", ctx do
      put_env(ctx, [{"FAKE_CODEX_ACCOUNT", "none"}])
      assert {:ok, %{logged_in: false, plan: nil}} = result = Codex.check(@fake, nil)
      assert Codex.readiness(result) == :signed_out
    end

    test "an API key", ctx do
      put_env(ctx, [{"FAKE_CODEX_ACCOUNT", "api_key"}])

      assert {:ok, %{logged_in: true, auth_method: "api_key", plan: nil}} =
               Codex.check(@fake, nil)
    end

    test "not on PATH" do
      result = Codex.check("/nonexistent/codex", nil)
      assert {:error, "/nonexistent/codex not found on PATH"} = result
      assert Codex.readiness(result) == :not_found
    end

    test "older than the minimum version fails with the reason", ctx do
      put_env(ctx, [{"FAKE_CODEX_VERSION", "0.150.0"}])
      result = Codex.check(@fake, nil)
      assert {:error, "codex 0.150.0 is older than 0.163.0; upgrade it"} = result
      assert Codex.readiness(result) == :failed
    end

    test "a config dir that does not exist", ctx do
      assert {:error, reason} = Codex.check(@fake, Path.join(ctx.dir, "missing"))
      assert reason =~ "does not exist"
    end

    test "a user MCP server named canopy fails the check", ctx do
      put_env(ctx, [])
      home = Path.join(ctx.dir, "home")
      File.mkdir_p!(home)
      File.write!(Path.join(home, "config.toml"), "[mcp_servers.canopy]\ncommand = \"x\"\n")

      result = Codex.check(@fake, home)
      assert {:error, reason} = result
      assert reason =~ "defines an MCP server named canopy"
      assert Codex.readiness(result) == :failed
    end

    test "plan names" do
      assert Codex.plan("plus") == "Plus"
      assert Codex.plan("prolite") == "Pro Lite"
      assert Codex.plan("team") == "Team"
      assert Codex.plan(nil) == nil
    end
  end

  describe "the adapter" do
    test "model_label and model_error?" do
      agent = Fixtures.agent_fixture(%{engine: "codex", model_id: "gpt-5-codex"})
      assert Codex.model_label(agent, :main) == "gpt-5-codex"
      assert Codex.model_label(%{agent | model_id: nil}, :main) == "codex default"
      assert Codex.model_error?("model gpt-9 does not exist")
      assert Codex.model_error?("unknown model foo")
      refute Codex.model_error?("rate limited")
      assert Codex.context_cap() == 200_000
    end

    test "rename_session reports a session reset meanwhile instead of raising" do
      assert Codex.rename_session("as_gone", Ecto.UUID.generate(), Ecto.UUID.generate()) ==
               {:error, :session_gone}
    end

    test "the rename moves the turn's agent_started to the thread id, so the transcript lists one session",
         ctx do
      put_env(ctx, [], rename_ack_ms: 0)
      coder = Fixtures.agent_fixture(%{engine: "codex"})
      %{channel: channel} = Fixtures.scenario(members: [coder])
      placeholder = Ecto.UUID.generate()
      earlier = Ecto.UUID.generate()

      session =
        Fixtures.session_fixture(%{
          channel: channel,
          agent_id: coder.id,
          engine: "codex",
          engine_session_id: placeholder
        })

      started = fn sid ->
        {:ok, _} =
          Timeline.record(%{
            channel_id: channel.id,
            agent_id: coder.id,
            event_type: "agent_started",
            ref_id: session.id,
            payload: %{"engine_session_id" => sid, "engine" => "codex"}
          })
      end

      # a thread from before a reset is a real earlier session and stays listed
      started.(earlier)
      started.(placeholder)

      assert :ok = Codex.rename_session(session.id, placeholder, ctx.thread)

      ids =
        Canopy.Transcripts.list_sessions(channel.id, coder.id)
        |> Enum.map(&{&1.kind, &1.engine_session_id})

      assert ids == [{:current, ctx.thread}, {:earlier, earlier}]
    end

    test "an agent_started written after the rename began still ends up under the thread id",
         ctx do
      coder = Fixtures.agent_fixture(%{engine: "codex"})
      %{channel: channel} = Fixtures.scenario(members: [coder])
      placeholder = Ecto.UUID.generate()

      session =
        Fixtures.session_fixture(%{
          channel: channel,
          agent_id: coder.id,
          engine: "codex",
          engine_session_id: placeholder
        })

      # stands in for the channel server: busy in send_prompt when the rename
      # arrives, it writes agent_started and only then acks
      :ok = Canopy.Engine.subscribe_session(placeholder)
      rename = Task.async(fn -> Codex.rename_session(session.id, placeholder, ctx.thread) end)
      assert_receive {:engine_session_renamed, ^placeholder, _, {pid, ref}}, 1_000

      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: coder.id,
          event_type: "agent_started",
          ref_id: session.id,
          payload: %{"engine_session_id" => placeholder, "engine" => "codex"}
        })

      send(pid, {:engine_session_renamed_ack, ref})
      assert :ok = Task.await(rename)

      assert [%{kind: :current, engine_session_id: thread}] =
               Canopy.Transcripts.list_sessions(channel.id, coder.id)

      assert thread == ctx.thread
    end

    test "create_session returns a placeholder id and a token" do
      assert {:ok, %{engine_session_id: id, mcp_token: token}} =
               Codex.create_session(nil, %{}, nil, [])

      assert {:ok, _} = Ecto.UUID.cast(id)
      assert is_binary(token)
    end
  end

  describe "a late Always (the turn that asked has ended)" do
    defp late(metadata, permission \\ "Bash") do
      sid = Ecto.UUID.generate()
      on_exit(fn -> Canopy.Codex.Approvals.forget(sid) end)

      request = %PermissionRequests.PermissionRequest{
        opencode_permission_id: "cdx-1",
        permission: permission,
        metadata: metadata,
        agent_session: %{engine_session_id: sid}
      }

      assert {:error, :gone} = Codex.reply_permission(%{}, nil, request, :always)
      Canopy.Codex.Approvals.rules(sid)
    end

    test "remembers the rule with the card's sandbox" do
      assert late(%{"always_prefix" => "npm install"}) == [{:command, ["npm", "install"], false}]

      assert late(%{"always_prefix" => "npm install", "unsandboxed" => true}) ==
               [{:command, ["npm", "install"], true}]

      assert late(%{}, "file_change") == [:file_change]
    end

    test "remembers nothing for a once-only or no-Always card, or an unmatchable git prefix" do
      assert late(%{"always_prefix" => "gh pr", "once_only" => true}) == []
      assert late(%{"always_prefix" => "git push", "no_always" => true}) == []
      assert late(%{"always_prefix" => "git push"}) == []
      assert late(%{"always_prefix" => "git log"}) == [{:command, ["git", "log"], false}]
    end
  end

  describe "a Codex agent in a channel" do
    setup ctx do
      put_env(ctx, [
        {"FAKE_CODEX_SCRIPT", fixture("turn-text.jsonl")},
        {"FAKE_CODEX_LOG", ctx.log},
        {"FAKE_CODEX_THREAD", ctx.thread}
      ])

      coder =
        Fixtures.agent_fixture(%{
          name: "coder" <> Fixtures.unique_suffix(),
          engine: "codex",
          model_id: "gpt-5-codex",
          permission_mode: "acceptEdits"
        })

      scenario = Fixtures.scenario(members: [coder])
      Timeline.subscribe(scenario.channel.id)
      {:ok, _pid} = Runtime.ensure_channel(scenario.channel.id, start_stream: false)
      on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
      {:ok, Map.put(scenario, :coder, coder)}
    end

    defp script(ctx, name) do
      put_env(ctx, [
        {"FAKE_CODEX_SCRIPT", fixture(name)},
        {"FAKE_CODEX_LOG", ctx.log},
        {"FAKE_CODEX_THREAD", ctx.thread}
      ])
    end

    defp sent(log, method) do
      for "STDIN " <> json <- log |> File.read!() |> String.split("\n"),
          {:ok, %{"method" => ^method} = msg} <- [JSON.decode(json)],
          do: msg
    end

    test "a mention wakes it: the session takes the thread id, the turn is priced as an estimate",
         ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} say hello")

      assert_receive {:timeline, %{event_type: "agent_turn_completed", payload: payload}}, 10_000
      assert payload["engine"] == "codex"
      assert payload["cost_estimated"] == true
      assert payload["cost"] > 0
      assert payload["model"] == "gpt-5-codex"
      assert payload["tokens"]["cache_read"] == 400
      assert payload["tokens"]["output"] == 100
      assert payload["engine_session_id"] == ctx.thread
      assert payload["outcome"] == "ok"

      assert_receive {:timeline, %{event_type: "message", message: %{body: "Hello from Codex."}}},
                     5_000

      session = AgentSessions.get_root(ctx.channel.id, ctx.coder.id)
      assert session.engine == "codex"
      assert session.engine_session_id == ctx.thread
      assert session.last_seen_at

      assert [start] = sent(ctx.log, "thread/start")
      assert start["params"]["developerInstructions"] =~ "Canopy"
      assert [turn] = sent(ctx.log, "turn/start")
      assert turn["params"]["model"] == "gpt-5-codex"
      assert turn["params"]["approvalsReviewer"] == "user"

      log = File.read!(ctx.log)
      refute log =~ session.mcp_token
      assert log =~ "TOKEN_SHA256 " <> sha(session.mcp_token)
      assert log =~ ~s(mcp_servers.canopy.url="#{Canopy.MCP.url()}")

      # the MCP connection made before the rename still finds the session
      frame = %{
        assigns: %{
          canopy_session: %{id: session.id, engine: "codex", engine_session_id: "placeholder"}
        }
      }

      assert {:ok, %{session: %{id: id}, agent: %{id: agent_id}}} = Identity.from_frame(frame)
      assert id == session.id
      assert agent_id == ctx.coder.id
    end

    test "the next wake resumes the thread", ctx do
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} first")
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} second")
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      assert [_] = sent(ctx.log, "thread/start")
      assert [resume] = sent(ctx.log, "thread/resume")
      assert resume["params"]["threadId"] == ctx.thread
    end

    test "a command approval is a card with its session, answered through the turn", ctx do
      script(ctx, "turn-approval-command.jsonl")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} install it")

      assert_receive {:timeline, %{event_type: "permission_requested"}}, 10_000
      assert [request] = PermissionRequests.pending_for_channel(ctx.channel.id)
      assert request.permission == "Bash"
      assert request.agent_session_id
      assert request.metadata["unsandboxed"] == true
      assert request.metadata["action"] == "command"
      assert AgentSessions.get!(request.agent_session_id).engine_session_id == ctx.thread

      assert {:ok, _} = Runtime.respond_permission(ctx.channel.id, request.id, :once)
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      assert ctx.log
             |> File.read!()
             |> String.contains?(~s("result":{"decision":"accept"}))
    end

    test "a plan agent's command card shows despite a global Bash grant, and Always counts as Once",
         ctx do
      {:ok, coder} =
        Canopy.Agents.update(ctx.coder, %{permission_mode: "plan"})

      {:ok, _} = GlobalPermissions.grant(coder.id, "Bash")
      script(ctx, "turn-approval-command.jsonl")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} install it")

      assert_receive {:timeline, %{event_type: "permission_requested"}}, 10_000
      refute_received {:timeline, %{event_type: "permission_auto_approved"}}
      assert [request] = PermissionRequests.pending_for_channel(ctx.channel.id)
      assert request.metadata["once_only"] == true

      assert {:ok, resolved} = Runtime.respond_permission(ctx.channel.id, request.id, :always)
      assert resolved.status != "always"
      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 10_000

      log = File.read!(ctx.log)
      assert log =~ ~s("result":{"decision":"accept"})
      refute log =~ "acceptForSession"
      assert Canopy.Codex.Approvals.rules(ctx.thread) == []
    end

    test "a usage-limit error pauses Codex; with no rate limits known it waits for Release",
         ctx do
      script(ctx, "turn-usage-limit.jsonl")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
      assert_receive {:timeline, %{event_type: "engine_paused", payload: payload}}, 10_000
      assert payload["engine"] == "codex"
      assert payload["reason"] == "usage limit"
      assert payload["resets_at"] == nil
      assert %{kind: "usage", resets_at: nil} = Canopy.EnginePauses.get("codex")
      refute_received {:timeline, %{event_type: "agent_error"}}
      assert File.read!(ctx.log) =~ "account/rateLimits/read"
    end

    test "a usage limit's reset time comes from the rate-limit snapshot", ctx do
      script(ctx, "turn-usage-limit-with-reset.jsonl")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
      assert_receive {:timeline, %{event_type: "engine_paused", payload: payload}}, 10_000
      assert payload["resets_at"] == "2100-01-01T00:00:00.000000Z"
      assert payload["nudge_at"] == "2100-01-01T00:01:00.000000Z"
      refute File.read!(ctx.log) =~ "account/rateLimits/read"
    end

    test "with no snapshot yet, the reset time is read once from account/rateLimits/read", ctx do
      script(ctx, "turn-usage-limit-read.jsonl")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
      assert_receive {:timeline, %{event_type: "engine_paused", payload: payload}}, 10_000
      assert payload["resets_at"] == "2100-01-01T00:00:00.000000Z"
      assert payload["reason"] == "weekly usage limit"
    end

    test "a limit reported only on the error notification still reads the reset time", ctx do
      script(ctx, "turn-usage-limit-error-note.jsonl")
      {:ok, _} = Runtime.post_user_message(ctx.channel.id, "@#{ctx.coder.name} go")
      assert_receive {:timeline, %{event_type: "engine_paused", payload: payload}}, 10_000
      assert payload["resets_at"] == "2100-01-01T00:00:00.000000Z"
    end
  end

  defp sha(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
