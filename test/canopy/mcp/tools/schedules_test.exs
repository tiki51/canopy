defmodule Canopy.MCP.Tools.SchedulesTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Canopy.Fixtures
  import Canopy.MCPHelpers

  alias Canopy.Schedules
  alias Canopy.MCP.Tools.{ScheduleCancel, ScheduleCreate, SchedulesList}

  setup do
    reviewer = agent_fixture(name: "reviewer-" <> unique_suffix())
    outsider = agent_fixture(name: "outsider-" <> unique_suffix())
    ctx = scenario(members: [reviewer])
    reviewer_session = session_fixture(%{channel: ctx.channel, agent_id: reviewer.id})
    Map.merge(ctx, %{reviewer: reviewer, reviewer_session: reviewer_session, outsider: outsider})
  end

  test "an agent schedules for itself, once or recurring", ctx do
    assert {:ok, text} =
             call(ScheduleCreate, %{when: "2h", what: "Check the deploy went out."}, ctx)

    assert [_, id] =
             Regex.run(
               ~r/scheduled \[(sch_[^\]]+)\] for @#{ctx.agent.name} in ##{ctx.channel.name} at .* \(in 2h\)/,
               text
             )

    schedule = Schedules.get!(id)
    assert schedule.kind == "once"
    assert schedule.created_by_agent_id == ctx.agent.id
    assert_enqueued(worker: Schedules.Worker, args: %{schedule_id: id})

    assert {:ok, text} =
             call(ScheduleCreate, %{when: "0 9 * * 1-5", what: "Run the flaky suite."}, ctx)

    assert text =~ "every weekday at 09:00, next"
  end

  test "the owner may schedule for a member; a member may not schedule for others", ctx do
    assert {:ok, text} =
             call(
               ScheduleCreate,
               %{when: "1h", what: "Review the diff.", agent: "@" <> ctx.reviewer.name},
               ctx
             )

    assert text =~ "for @#{ctx.reviewer.name}"

    assert {:error, reason} =
             call(
               ScheduleCreate,
               %{when: "1h", what: "x", agent: "@" <> ctx.agent.name},
               ctx.reviewer_session
             )

    assert reason =~ "only the owner"

    assert {:error, reason} =
             call(ScheduleCreate, %{when: "1h", what: "x", agent: "@" <> ctx.outsider.name}, ctx)

    assert reason =~ "not a member"
  end

  test "bad input is explained", ctx do
    assert {:error, "that time is in the past"} =
             call(ScheduleCreate, %{when: "2020-01-01T00:00:00Z", what: "x"}, ctx)

    assert {:error, "what is empty"} = call(ScheduleCreate, %{when: "1h", what: "  "}, ctx)
    assert {:error, reason} = call(ScheduleCreate, %{when: "* * * * *", what: "x"}, ctx)
    assert reason =~ "at least 5 minutes"
  end

  test "listing by channel and by agent, and cancelling with permissions", ctx do
    {:ok, mine} = call(ScheduleCreate, %{when: "1h", what: "Mine."}, ctx)
    {:ok, theirs} = call(ScheduleCreate, %{when: "2h", what: "Theirs."}, ctx.reviewer_session)
    [_, mine_id] = Regex.run(~r/\[(sch_[^\]]+)\]/, mine)
    [_, theirs_id] = Regex.run(~r/\[(sch_[^\]]+)\]/, theirs)

    assert {:ok, text} = call(SchedulesList, %{}, ctx)

    assert text =~ "[#{mine_id}] @#{ctx.agent.name}" and
             text =~ "[#{theirs_id}] @#{ctx.reviewer.name}"

    assert text =~ "once, next"

    assert {:ok, text} = call(SchedulesList, %{agent: "@" <> ctx.reviewer.name}, ctx)
    assert text =~ theirs_id
    refute text =~ mine_id

    # the reviewer cannot cancel the owner's schedule; the owner can cancel anyone's
    assert {:error, reason} = call(ScheduleCancel, %{id: mine_id}, ctx.reviewer_session)
    assert reason =~ "only @#{ctx.agent.name} or the owner"
    assert {:ok, text} = call(ScheduleCancel, %{id: theirs_id, reason: "done another way"}, ctx)
    assert text =~ "cancelled [#{theirs_id}] for @#{ctx.reviewer.name}"
    assert %{status: "cancelled", status_reason: "done another way"} = Schedules.get!(theirs_id)

    assert {:ok, _} = call(ScheduleCancel, %{id: mine_id}, ctx)
    assert {:ok, "No active or paused schedules."} = call(SchedulesList, %{}, ctx)
    assert {:error, reason} = call(ScheduleCancel, %{id: "sch_nope"}, ctx)
    assert reason =~ "unknown schedule"
  end
end
