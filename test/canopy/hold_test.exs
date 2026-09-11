defmodule Canopy.HoldTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Canopy.Fixtures

  alias Canopy.{Hold, Schedules}

  test "engage pauses schedules and release resumes exactly those" do
    %{channel: channel, agent: agent} = scenario()
    Hold.subscribe()

    {:ok, active} =
      Schedules.create(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "check",
        when: "0 9 * * *"
      })

    {:ok, already} =
      Schedules.create(%{
        channel_id: channel.id,
        agent_id: agent.id,
        instruction: "old",
        when: "2h"
      })

    {:ok, already} = Schedules.cancel(already, "not needed")

    refute Hold.active?()
    assert :ok = Hold.engage("Insufficient balance")
    assert Hold.active?()
    assert Hold.reason() == "Insufficient balance"
    assert %DateTime{} = Hold.since()
    assert_receive {:hold, :engaged}

    assert %{status: "paused", status_reason: "on hold: Insufficient balance"} =
             Schedules.get!(active.id)

    assert %{status: "cancelled"} = Schedules.get!(already.id)

    # engaging again is a no-op
    assert :ok = Hold.engage("something else")
    assert Hold.reason() == "Insufficient balance"

    # held schedules do not fire even if their job runs
    assert :ok = Schedules.fire(active.id)

    assert :ok = Hold.release()
    refute Hold.active?()
    assert_receive {:hold, :released}
    assert %{status: "active"} = Schedules.get!(active.id)
    assert %{status: "cancelled"} = Schedules.get!(already.id)
  end

  test "recognises billing errors" do
    assert Hold.billing_error?("Insufficient balance. Manage your billing here: https://x")
    assert Hold.billing_error?("You have no credits remaining.")
    assert Hold.billing_error?("insufficient_quota")
    assert Hold.billing_error?("HTTP 402 Payment Required")
    refute Hold.billing_error?("Model not found: anthropic/claude")
    refute Hold.billing_error?(nil)
  end
end
