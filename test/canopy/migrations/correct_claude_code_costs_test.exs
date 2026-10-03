defmodule Canopy.Migrations.CorrectClaudeCodeCostsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Canopy.{AgentSessions, Costs, Repo, Timeline}
  alias Canopy.AgentSessions.AgentSession

  @migration Canopy.Repo.Migrations.CorrectClaudeCodeCosts
  @path "priv/repo/migrations/20261003224805_correct_claude_code_costs.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    scenario()
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp backfill, do: apply(@migration, :backfill, [Repo])

  # A turn summary as an older version recorded it, `n` seconds into the day.
  defp turn(ctx, ref, n, payload) do
    {:ok, event} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "agent_turn_completed",
        ref_id: ref,
        payload: Map.merge(%{"outcome" => "ok", "model" => "opus"}, payload)
      })

    at = DateTime.add(~U[2026-09-29 08:00:00.000000Z], n, :second)

    {1, _} =
      Repo.update_all(from(e in Timeline.Event, where: e.id == ^event.id), set: [inserted_at: at])

    event.id
  end

  defp payload(id), do: Repo.get!(Timeline.Event, id).payload
  defp cost(id), do: payload(id)["cost"]

  test "Claude Code turns get their own cost back from the running totals", ctx do
    claude =
      session_fixture(%{
        channel: ctx.channel,
        agent_id: agent_fixture().id,
        engine: "claude_code",
        engine_session_id: Ecto.UUID.generate()
      })

    # the installed app's sequence around a compaction that restored a stale
    # total, with a failed turn (no result) in between
    a = turn(ctx, claude.id, 1, %{"cost" => 1.6551})
    b = turn(ctx, claude.id, 2, %{"cost" => 1.7083})
    failed = turn(ctx, claude.id, 3, %{"cost" => 0.0, "outcome" => "error"})
    c = turn(ctx, claude.id, 4, %{"cost" => 3.1587})
    stale = turn(ctx, claude.id, 5, %{"cost" => 1.7083, "trigger" => "compact"})
    d = turn(ctx, claude.id, 6, %{"cost" => 3.8228})
    # recorded by this version: already the turn's own cost
    fresh = turn(ctx, claude.id, 7, %{"cost" => 0.07, "cost_scope" => "turn"})

    # a session that was reset (its row is gone; the reset line names the engine)
    reset_ref = "as_reset_" <> unique_suffix()

    {:ok, _} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "session_reset",
        ref_id: reset_ref,
        payload: %{"engine" => "claude_code", "engine_session_id" => Ecto.UUID.generate()}
      })

    r1 = turn(ctx, reset_ref, 10, %{"cost" => 0.02})
    r2 = turn(ctx, reset_ref, 11, %{"cost" => 0.05})

    # OpenCode reports each turn's own cost: untouched
    o1 = turn(ctx, ctx.session.id, 20, %{"cost" => 0.1, "model" => "opencode/big"})
    o2 = turn(ctx, ctx.session.id, 21, %{"cost" => 0.2, "model" => "opencode/big"})

    assert_in_delta Costs.channel_total(ctx.channel.id), 12.4932, 1.0e-6

    backfill()

    assert_in_delta cost(a), 1.6551, 1.0e-9
    assert_in_delta cost(b), 0.0532, 1.0e-9
    assert cost(failed) == 0.0
    assert_in_delta cost(c), 1.4504, 1.0e-9
    assert cost(stale) == 0.0
    # counted from the larger of the last totals it is above
    assert_in_delta cost(d), 0.6641, 1.0e-9
    assert cost(fresh) == 0.07
    assert_in_delta cost(r1), 0.02, 1.0e-9
    assert_in_delta cost(r2), 0.03, 1.0e-9
    assert cost(o1) == 0.1
    assert cost(o2) == 0.2

    assert %{"cost_reported" => 3.8228, "cost_corrected" => true, "cost_scope" => "turn"} =
             payload(d)

    refute Map.has_key?(payload(fresh), "cost_corrected")
    refute Map.has_key?(payload(o1), "cost_corrected")

    # the session's last total, for its next turn to count from
    assert Repo.get!(AgentSession, claude.id).cost_total == 3.8228
    assert Repo.get!(AgentSession, ctx.session.id).cost_total == nil

    # the Costs page and spend limits read the corrected amounts
    total = 1.6551 + 0.0532 + 1.4504 + 0.6641 + 0.07 + 0.02 + 0.03 + 0.1 + 0.2
    assert_in_delta Costs.channel_total(ctx.channel.id), total, 1.0e-6

    # safe to run again
    backfill()
    assert_in_delta cost(d), 0.6641, 1.0e-9
    assert_in_delta cost(b), 0.0532, 1.0e-9
    assert payload(d)["cost_reported"] == 3.8228
    assert_in_delta Costs.channel_total(ctx.channel.id), total, 1.0e-6
  end

  test "a session's saved total is not overwritten once the app keeps it", ctx do
    claude =
      session_fixture(%{
        channel: ctx.channel,
        agent_id: agent_fixture().id,
        engine: "claude_code",
        engine_session_id: Ecto.UUID.generate()
      })

    turn(ctx, claude.id, 1, %{"cost" => 0.5})
    :ok = AgentSessions.put_cost_total(claude.id, 0.9)
    backfill()
    assert Repo.get!(AgentSession, claude.id).cost_total == 0.9
  end

  test "with no engine on record, the model label decides", ctx do
    claude = turn(ctx, "as_gone_" <> unique_suffix(), 1, %{"cost" => 0.4, "model" => "sonnet"})
    ref = "as_gone_" <> unique_suffix()
    o1 = turn(ctx, ref, 1, %{"cost" => 0.4, "model" => "opencode/big"})
    o2 = turn(ctx, ref, 2, %{"cost" => 0.5, "model" => "opencode default"})

    backfill()

    assert payload(claude)["cost_corrected"] == true
    assert cost(o1) == 0.4
    assert cost(o2) == 0.5
  end
end
