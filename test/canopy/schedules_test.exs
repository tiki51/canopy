defmodule Canopy.SchedulesTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Canopy.Fixtures
  import Mox

  alias Canopy.{Agents, Channels, Runtime, Schedules, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Schedules.Worker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ctx = scenario()
    Timeline.subscribe(ctx.channel.id)
    Schedules.subscribe()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

    on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
    ctx
  end

  # runs due and scheduled jobs inline, as Oban would
  defp drain, do: Oban.drain_queue(queue: :schedules, with_scheduled: true)

  defp attrs(ctx, extra) do
    Map.merge(
      %{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        created_by_agent_id: ctx.agent.id,
        instruction: "Check whether the deploy went out."
      },
      extra
    )
  end

  test "create/1 stores a one-off with its job, records the event, and notifies", ctx do
    now = DateTime.utc_now()
    assert {:ok, schedule} = Schedules.create(attrs(ctx, %{when: "2h", now: now}))

    assert schedule.kind == "once"
    assert schedule.status == "active"
    assert DateTime.diff(schedule.next_run_at, now, :second) in 7199..7201

    assert_enqueued(
      worker: Worker,
      args: %{schedule_id: schedule.id},
      scheduled_at: {schedule.next_run_at, delta: 1}
    )

    assert_receive {:timeline, %{event_type: "schedule_created", ref_id: id}}
    assert id == schedule.id
    assert_receive {:schedules, :changed, cid}
    assert cid == ctx.channel.id
    assert [%{id: ^id}] = Schedules.list_for_channel(ctx.channel.id)
    assert [%{id: ^id}] = Schedules.list_for_agent(ctx.agent.id)
    assert Schedules.active_counts_by_agent() == %{ctx.agent.id => 1}
  end

  test "create/1 rejects bad times and enforces the per-agent cap", ctx do
    assert {:error, "that time is in the past"} =
             Schedules.create(attrs(ctx, %{when: "2020-01-01T00:00:00Z"}))

    assert {:error, %Ecto.Changeset{}} =
             Schedules.create(attrs(ctx, %{when: "1h", instruction: "   "}))

    for _ <- 1..20, do: {:ok, _} = Schedules.create(attrs(ctx, %{when: "1h"}))
    assert {:error, reason} = Schedules.create(attrs(ctx, %{when: "1h"}))
    assert reason =~ "already has 20 active schedules"
  end

  test "cancel/2 drops the job and records the event", ctx do
    {:ok, schedule} = Schedules.create(attrs(ctx, %{when: "1h"}))

    assert {:ok, %{status: "cancelled", status_reason: "no longer needed"}} =
             Schedules.cancel(schedule, "no longer needed")

    refute_enqueued(worker: Worker, args: %{schedule_id: schedule.id})

    assert_receive {:timeline,
                    %{
                      event_type: "schedule_cancelled",
                      payload: %{"reason" => "no longer needed"}
                    }}

    assert Schedules.list_for_channel(ctx.channel.id) == []
  end

  test "firing a one-off wakes the agent with the instruction and marks it done", ctx do
    test_pid = self()

    expect(OC, :prompt_async, fn _dir, sid, body, _opts ->
      send(test_pid, {:prompted, sid, body})
      {:ok, ""}
    end)

    {:ok, schedule} = Schedules.create(attrs(ctx, %{when: "1s"}))
    assert %{success: 1} = drain()

    sid = ctx.session.opencode_session_id
    assert_receive {:prompted, ^sid, %{parts: [%{text: text}]}}, 2_000
    assert text =~ "Schedule ID: #{schedule.id}"
    assert text =~ "Check whether the deploy went out."
    refute text =~ "This repeats"

    assert_receive {:timeline, %{event_type: "schedule_fired"}}, 1_000
    assert %{status: "done", run_count: 1, last_run_at: %DateTime{}} = Schedules.get!(schedule.id)
    refute_enqueued(worker: Worker, args: %{schedule_id: schedule.id})
  end

  test "a recurring schedule re-enqueues its next run after firing", ctx do
    test_pid = self()

    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts ->
      send(test_pid, :prompted)
      {:ok, ""}
    end)

    {:ok, schedule} = Schedules.create(attrs(ctx, %{when: "*/30 * * * *"}))
    first = schedule.next_run_at
    assert %{success: 1} = drain()
    assert_receive :prompted, 2_000

    after_run = Schedules.get!(schedule.id)
    assert after_run.status == "active"
    assert after_run.run_count == 1
    assert DateTime.compare(after_run.next_run_at, first) == :gt

    assert_enqueued(
      worker: Worker,
      args: %{schedule_id: schedule.id},
      scheduled_at: {after_run.next_run_at, delta: 1}
    )
  end

  test "an overdue recurring run is skipped, not fired", ctx do
    {:ok, schedule} = Schedules.create(attrs(ctx, %{when: "0 9 * * *"}))
    stale = DateTime.add(DateTime.utc_now(), -8 * 3600, :second)
    Repo.update!(Ecto.Changeset.change(schedule, next_run_at: stale))

    assert %{success: 1} = drain()

    assert_receive {:timeline, %{event_type: "schedule_skipped", payload: %{"reason" => reason}}},
                   1_000

    assert reason =~ "overdue"
    assert %{status: "active", run_count: 0} = Schedules.get!(schedule.id)
    assert_enqueued(worker: Worker, args: %{schedule_id: schedule.id})
  end

  test "archiving pauses, reopening resumes; deactivating an agent pauses", ctx do
    {:ok, once} = Schedules.create(attrs(ctx, %{when: "3h"}))
    {:ok, cron} = Schedules.create(attrs(ctx, %{when: "0 9 * * *"}))

    {:ok, channel} = Channels.archive(ctx.channel)

    assert %{status: "paused", status_reason: "the channel was archived"} =
             Schedules.get!(once.id)

    assert %{status: "paused"} = Schedules.get!(cron.id)
    refute_enqueued(worker: Worker, args: %{schedule_id: once.id})
    assert_receive {:timeline, %{event_type: "schedule_paused"}}

    # a paused schedule that fires anyway does nothing
    assert :ok = perform_job(Worker, %{schedule_id: once.id})
    refute_receive {:timeline, %{event_type: "schedule_fired"}}, 200

    {:ok, _} = Channels.reopen(channel)
    assert %{status: "active"} = Schedules.get!(once.id)
    assert %{status: "active"} = Schedules.get!(cron.id)
    assert_enqueued(worker: Worker, args: %{schedule_id: once.id})
    assert_receive {:timeline, %{event_type: "schedule_resumed"}}

    {:ok, _} = Agents.deactivate(ctx.agent)
    assert %{status: "paused", status_reason: reason} = Schedules.get!(cron.id)
    assert reason =~ "deactivated"
  end

  test "describe_cron/1 and relative/2 read well" do
    assert Schedules.describe_cron("0 9 * * 1-5") == "every weekday at 09:00"
    assert Schedules.describe_cron("30 7 * * *") == "every day at 07:30"
    assert Schedules.describe_cron("0 18 * * 5") == "every Friday at 18:00"
    assert Schedules.describe_cron("*/15 * * * *") == "every 15 minutes"
    assert Schedules.describe_cron("5 4 1 * *") == "on `5 4 1 * *`"

    now = ~U[2026-09-10 12:00:00Z]
    assert Schedules.relative(~U[2026-09-10 14:00:00Z], now) == "in 2h"
    assert Schedules.relative(~U[2026-09-10 12:00:20Z], now) == "now"
    assert Schedules.relative(~U[2026-09-13 12:00:00Z], now) == "in 3d"
    assert Schedules.relative(~U[2026-09-10 11:15:00Z], now) == "45m ago"
  end
end
