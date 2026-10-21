defmodule Canopy.EnginePausesTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Canopy.Fixtures
  import Mox

  alias Canopy.{EnginePauses, Runtime, Schedules, Timeline}
  alias Canopy.EnginePauses.{LiftWorker, PauseAgent}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Schedules.Schedule

  setup :set_mox_global

  @now ~U[2026-10-20 12:00:00.000000Z]

  defp usage(resets_at),
    do: %{
      kind: "usage",
      reason: "usage limit",
      resets_at: resets_at,
      detail: "You've hit your limit"
    }

  defp in_hours(h), do: DateTime.add(DateTime.utc_now(), h * 3600, :second)

  # Nudges wake OpenCode agents: their sessions and prompts are answered here.
  defp stub_opencode(test_pid) do
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> unique_suffix()}}
    end)

    stub(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)
  end

  describe "engage/2" do
    test "pauses the engine once, with its reset, and enqueues the lift a minute after" do
      EnginePauses.subscribe()
      at = in_hours(2)
      {:ok, pause} = EnginePauses.engage("claude_code", usage(at))
      assert_receive {:engine_pauses, :changed}

      assert EnginePauses.paused?("claude_code")
      refute EnginePauses.paused?("codex")
      assert pause.schedule_reason == "paused: Claude Code usage limit"

      assert [%{engine: "claude_code", resets_at: ^at, waiting: 0, on_fallback: 0}] =
               EnginePauses.list()

      assert_enqueued(
        worker: LiftWorker,
        args: %{pause_id: pause.id},
        scheduled_at: DateTime.add(at, 60, :second)
      )

      # idempotent: the same pause, and still one job
      {:ok, again} = EnginePauses.engage("claude_code", usage(at))
      assert again.id == pause.id
      assert length(all_enqueued(worker: LiftWorker)) == 1
    end

    test "a later reset re-times the pause, its lift and its Auto nudges" do
      %{channel: channel, agent: agent} = scenario()
      {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))
      {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
      row = EnginePauses.ensure_nudge(pause, row)

      later = in_hours(5)
      {:ok, pause} = EnginePauses.engage("opencode", usage(later))
      assert pause.resets_at == later

      assert [job] = all_enqueued(worker: LiftWorker)
      assert DateTime.compare(job.scheduled_at, DateTime.add(later, 50, :second)) == :gt

      schedule = Schedules.get!(row.schedule_id)
      assert schedule.next_run_at == DateTime.add(later, 60, :second)

      # an earlier one changes nothing
      {:ok, same} = EnginePauses.engage("opencode", usage(in_hours(2)))
      assert same.resets_at == later
    end

    test "a reset in the past or under a minute away counts as unknown: no lift, no nudge" do
      %{channel: channel, agent: agent} = scenario()

      for at <- [
            DateTime.add(DateTime.utc_now(), -3600, :second),
            DateTime.add(DateTime.utc_now(), 30, :second)
          ] do
        {:ok, pause} = EnginePauses.engage("opencode", usage(at))
        assert pause.resets_at == nil
        {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
        assert EnginePauses.ensure_nudge(pause, row).schedule_id == nil
        # lifted without nudging anyone, for the next round
        Repo.update_all(Canopy.EnginePauses.Pause, set: [lifted_at: DateTime.utc_now()])
      end

      refute_enqueued(worker: LiftWorker)
      assert EnginePauses.clamp(DateTime.add(@now, 61, :second), @now)
      refute EnginePauses.clamp(DateTime.add(@now, 60, :second), @now)
    end

    test "a billing limit's window reset is dropped: it lasts until Release" do
      billing = %{kind: "billing", reason: "insufficient balance", resets_at: in_hours(1)}
      {:ok, pause} = EnginePauses.engage("codex", billing)
      assert pause.resets_at == nil
      refute_enqueued(worker: LiftWorker)

      # a usage limit on top still brings a real reset
      {:ok, pause} = EnginePauses.engage("codex", usage(in_hours(2)))
      assert pause.resets_at
      assert pause.kind == "usage"
    end

    test "pauses the schedules of agents that now wait, not Auto ones or other engines'" do
      %{channel: channel, agent: agent} = scenario()
      other = agent_fixture(%{engine: "claude_code"})

      {:ok, mine} =
        Schedules.create(%{
          channel_id: channel.id,
          agent_id: agent.id,
          instruction: "check",
          when: "2h"
        })

      {:ok, theirs} =
        Schedules.create(%{
          channel_id: channel.id,
          agent_id: other.id,
          instruction: "check",
          when: "2h"
        })

      {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))

      assert %{status: "paused", status_reason: "paused: OpenCode usage limit"} =
               Schedules.get!(mine.id)

      assert %{status: "active"} = Schedules.get!(theirs.id)

      # resuming brings back exactly those
      stub_opencode(self())
      :ok = EnginePauses.resume("opencode")
      assert %{status: "active"} = Schedules.get!(mine.id)
      assert EnginePauses.get_pause(pause.id).lifted_by == "user"
    end
  end

  describe "mark/4 and counts" do
    test "one line per state; a flip notes again; agents count once per state" do
      %{channel: channel, agent: agent} = scenario()
      other_channel = channel_fixture(%{owner_agent_id: agent.id})
      {:ok, pause} = EnginePauses.engage("opencode", usage(nil))

      assert {:note, _} = EnginePauses.mark(pause, agent.id, channel.id, "fallback")
      assert {:noted, _} = EnginePauses.mark(pause, agent.id, channel.id, "fallback")
      assert {:note, _} = EnginePauses.mark(pause, agent.id, other_channel.id, "fallback")
      assert %{on_fallback: 1, waiting: 0} = EnginePauses.get("opencode")

      assert {:note, _} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
      assert %{on_fallback: 1, waiting: 1} = EnginePauses.get("opencode")
    end

    test "a fallback turn's limit flips the agent's rows to waiting, in every channel, with nudges" do
      %{channel: channel, agent: agent} = scenario()
      other_channel = channel_fixture(%{owner_agent_id: agent.id})
      {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))
      EnginePauses.mark(pause, agent.id, channel.id, "fallback")
      EnginePauses.mark(pause, agent.id, other_channel.id, "fallback")

      :ok = EnginePauses.flip_to_waiting("opencode", agent.id)
      assert %{on_fallback: 0, waiting: 1} = EnginePauses.get("opencode")

      rows = Repo.all(PauseAgent)

      assert Enum.all?(
               rows,
               &(&1.state == "waiting" and is_binary(&1.schedule_id) and not &1.noted)
             )
    end

    test "list/0: no reset first, then by reset" do
      {:ok, _} = EnginePauses.engage("claude_code", usage(in_hours(3)))
      {:ok, _} = EnginePauses.engage("codex", usage(in_hours(1)))

      {:ok, _} =
        EnginePauses.engage("opencode", %{kind: "billing", reason: "insufficient balance"})

      assert Enum.map(EnginePauses.list(), & &1.engine) == ["opencode", "codex", "claude_code"]
    end
  end

  describe "resume/2" do
    setup do
      stub_opencode(self())
      :ok
    end

    test "lifts, nudges each waiting agent once, writes one line per channel, ends the Auto nudges" do
      helper = agent_fixture()
      %{channel: channel, agent: agent, repository: repository} = scenario(members: [helper])
      Canopy.MCP.mark_registered(repository.id)
      other = channel_fixture(%{repository_id: repository.id, owner_agent_id: agent.id})
      Timeline.subscribe(channel.id)
      Timeline.subscribe(other.id)
      on_exit(fn -> Enum.each([channel.id, other.id], &Runtime.stop_channel/1) end)

      {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))
      {:note, waiting} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
      waiting = EnginePauses.ensure_nudge(pause, waiting)
      EnginePauses.mark(pause, helper.id, channel.id, "fallback")
      {:note, other_row} = EnginePauses.mark(pause, agent.id, other.id, "waiting")
      EnginePauses.ensure_nudge(pause, other_row)

      :ok = EnginePauses.resume("opencode", "reset")
      # a second resume (the Auto schedule firing too) lifts nothing more
      :ok = EnginePauses.resume("opencode", "reset")

      refute EnginePauses.paused?("opencode")
      refute_enqueued(worker: LiftWorker)
      assert %{status: "done"} = Schedules.get!(waiting.schedule_id)
      refute_enqueued(worker: Canopy.Schedules.Worker, args: %{schedule_id: waiting.schedule_id})

      cid = channel.id

      assert_receive {:timeline,
                      %{event_type: "engine_resumed", channel_id: ^cid, agent_id: nil, payload: p}}

      assert p["by"] == "reset"
      assert p["engine"] == "opencode"
      assert p["pause_id"] == pause.id
      assert p["nudged"] == [agent.id]
      assert [%{"agent_id" => helper_id}] = p["returned"]
      assert helper_id == helper.id

      oid = other.id
      assert_receive {:timeline, %{event_type: "engine_resumed", channel_id: ^oid}}
      assert_receive {:timeline, %{event_type: "schedule_fired", payload: %{"source" => "auto"}}}

      assert_receive {:prompted, _, body}, 2_000
      assert inspect(body) =~ "Your OpenCode usage limit has reset."
      assert_receive {:prompted, _, _}, 2_000
      refute_receive {:prompted, _, _}, 200
      refute_receive {:timeline, %{event_type: "engine_resumed"}}, 50
    end

    test "an archived channel's waiting agents aren't nudged; its Auto nudge still ends" do
      %{channel: channel, agent: agent, repository: repository} = scenario()
      Canopy.MCP.mark_registered(repository.id)
      Timeline.subscribe(channel.id)
      on_exit(fn -> Runtime.stop_channel(channel.id) end)

      {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))
      {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
      row = EnginePauses.ensure_nudge(pause, row)
      {:ok, _} = Canopy.Channels.archive(channel)

      :ok = EnginePauses.resume("opencode")

      assert %{status: "done"} = Schedules.get!(row.schedule_id)

      assert_receive {:timeline, %{event_type: "engine_resumed", payload: %{"nudged" => []}}}

      refute_receive {:timeline, %{event_type: "schedule_fired"}}, 50
      refute_receive {:prompted, _, _}, 300
    end

    test "the nudge text follows who resumed" do
      pause = %{engine: "claude_code", reason: "weekly usage limit"}

      assert EnginePauses.nudge_text(pause, "reset") ==
               "Your Claude Code weekly usage limit has reset. Check the channel and carry on with any open work."

      assert EnginePauses.nudge_text(pause, "user") ==
               "Claude Code has been resumed. Check the channel and carry on with any open work."
    end

    test "resuming an engine that isn't paused is :ok" do
      assert :ok = EnginePauses.resume("codex")
    end

    test "the lift job lifts the pause; a job for a lifted pause does nothing" do
      {:ok, pause} = EnginePauses.engage("claude_code", usage(in_hours(1)))
      assert :ok = perform_job(LiftWorker, %{pause_id: pause.id})
      assert EnginePauses.get_pause(pause.id).lifted_by == "reset"
      assert :ok = perform_job(LiftWorker, %{pause_id: pause.id})
    end

    test "an Auto schedule that comes due lifts its pause" do
      %{channel: channel, agent: agent, repository: repository} = scenario()
      Canopy.MCP.mark_registered(repository.id)
      on_exit(fn -> Runtime.stop_channel(channel.id) end)
      {:ok, pause} = EnginePauses.engage("opencode", usage(in_hours(1)))
      {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
      row = EnginePauses.ensure_nudge(pause, row)

      assert %Schedule{
               source: "auto",
               source_ref: pause_id,
               created_by_agent_id: nil,
               kind: "once"
             } =
               schedule = Schedules.get!(row.schedule_id)

      assert pause_id == pause.id
      assert schedule.instruction =~ "has reset"

      :ok = Schedules.fire(schedule.id)
      refute EnginePauses.paused?("opencode")
      assert %{status: "done"} = Schedules.get!(schedule.id)
      assert_receive {:prompted, _, _}, 2_000
      refute_receive {:prompted, _, _}, 200
    end
  end

  test "a waiting agent's schedule pauses when it comes due, and resumes with the lift" do
    stub_opencode(self())
    %{channel: channel, agent: agent, repository: repository} = scenario()
    Canopy.MCP.mark_registered(repository.id)
    on_exit(fn -> Runtime.stop_channel(channel.id) end)
    {:ok, _} = EnginePauses.engage("opencode", usage(nil))

    # made after the pause engaged, so engage didn't pause it
    {:ok, schedule} =
      Schedules.create(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "check",
        when: "2h"
      })

    :ok = Schedules.fire(schedule.id)

    assert %{status: "paused", status_reason: "paused: OpenCode usage limit"} =
             Schedules.get!(schedule.id)

    refute_receive {:prompted, _, _}, 100

    :ok = EnginePauses.resume("opencode")
    assert %{status: "active"} = Schedules.get!(schedule.id)
  end

  test "an Auto nudge skips the agent's schedule cap" do
    %{channel: channel, agent: agent} = scenario()

    for i <- 1..20 do
      {:ok, _} =
        Schedules.create(%{
          channel_id: channel.id,
          agent_id: agent.id,
          instruction: "s#{i}",
          when: "#{i}h"
        })
    end

    {:ok, pause} = EnginePauses.engage("claude_code", usage(in_hours(1)))
    {:note, row} = EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    assert is_binary(EnginePauses.ensure_nudge(pause, row).schedule_id)
  end

  test "after an environment clear, reschedule_all/0 re-enqueues the lift of a kept pause" do
    {:ok, pause} = EnginePauses.engage("claude_code", usage(in_hours(1)))
    # what Canopy.Environment.Clear does to the job table (it keeps engine_pauses)
    assert "engine_pauses" in Canopy.Environment.Clear.kept_tables()
    assert "engine_pause_agents" in Canopy.Environment.Clear.cleared_tables()
    Repo.delete_all(from j in Oban.Job, where: j.state != "executing")
    refute_enqueued(worker: LiftWorker)
    assert EnginePauses.paused?("claude_code")

    :ok = EnginePauses.reschedule_all()
    assert_enqueued(worker: LiftWorker, args: %{pause_id: pause.id})

    # a reset that passed meanwhile lifts a minute from now
    Repo.update_all(Canopy.EnginePauses.Pause,
      set: [resets_at: DateTime.add(DateTime.utc_now(), -600, :second)]
    )

    :ok = EnginePauses.reschedule_all()
    [job] = all_enqueued(worker: LiftWorker)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second) in 50..61
  end

  describe "limit_error?/1" do
    test "billing errors" do
      assert EnginePauses.limit_error?(
               "Insufficient balance. Manage your billing here: https://x"
             )

      assert EnginePauses.limit_error?("You have no credits remaining.")
      assert EnginePauses.limit_error?("insufficient_quota")
      assert EnginePauses.limit_error?("HTTP 402 Payment Required")
      refute EnginePauses.limit_error?("Model not found: anthropic/claude")
      refute EnginePauses.limit_error?(nil)
    end

    test "Claude Code's wording, including 2.1.283's session limit" do
      assert EnginePauses.limit_error?(
               "You've hit your session limit · resets 4:50am (America/Los_Angeles)"
             )

      assert EnginePauses.limit_error?("You've hit your weekly limit")
      assert EnginePauses.limit_error?("You've hit your opus limit")
      assert EnginePauses.limit_error?("Credit balance is too low")
      assert EnginePauses.limit_error?("Claude AI usage limit reached|1759683600")
      assert EnginePauses.limit_error?("You've hit your limit · resets 3pm")
      assert EnginePauses.limit_error?("You've hit your monthly spend limit.")
      assert EnginePauses.limit_error?("You have reached your weekly usage limit")
      assert EnginePauses.limit_error?("You're out of extra usage")
      refute EnginePauses.limit_error?("Budget limit reached ($0.52 of $0.50)")
      refute EnginePauses.limit_error?("You've hit your fast limit")
      refute EnginePauses.limit_error?("Context limit reached")
      refute EnginePauses.limit_error?("error_max_turns")
    end

    test "Codex's usage limits, not its rate limits or sign-in errors" do
      assert EnginePauses.limit_error?(%{"name" => "usageLimitExceeded"})

      assert EnginePauses.limit_error?(%{
               "name" => "insufficient_quota",
               "data" => %{"message" => "x"}
             })

      assert EnginePauses.limit_error?("You've hit your usage limit. Upgrade to Pro.")

      refute EnginePauses.limit_error?(%{
               "name" => "codex",
               "data" => %{"message" => "You've hit your usage limit"}
             })

      refute EnginePauses.limit_error?(%{"name" => "rateLimitExceeded"})
      refute EnginePauses.limit_error?(%{"name" => "serverOverloaded"})
      refute EnginePauses.limit_error?(%{"name" => "unauthorized"})
      refute EnginePauses.limit_error?(%{"name" => "httpConnectionFailed"})
      refute EnginePauses.limit_error?(%{})
    end

    test "generic_limit/1 is billing until Release" do
      assert %{
               kind: "billing",
               reason: "usage limit",
               resets_at: nil,
               detail: "Credit balance is too low"
             } =
               EnginePauses.generic_limit("Credit balance is too low")

      refute EnginePauses.generic_limit("stream closed")
    end
  end
end
