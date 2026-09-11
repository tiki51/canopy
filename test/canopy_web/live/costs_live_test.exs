defmodule CanopyWeb.CostsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Timeline}

  test "shows totals and breakdowns, switches periods, and follows new turns", %{conn: conn} do
    %{channel: channel, agent: agent} = Fixtures.scenario()

    {:ok, _} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        payload: %{
          "outcome" => "ok",
          "cost" => 0.42,
          "tools" => 2,
          "duration_ms" => 900,
          "model" => "opencode/big-pickle"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/costs")
    assert has_element?(view, "#cost-today", "$0.42")
    assert has_element?(view, "#cost-all", "1 turns")
    assert has_element?(view, "#by-agent-#{agent.id}", "@#{agent.name}")

    assert has_element?(
             view,
             "#by-channel-#{channel.id} a[href='/channels/#{channel.id}']",
             "##{channel.name}"
           )

    assert has_element?(view, "#by-model-opencode\\/big-pickle", "$0.42")
    assert has_element?(view, "#day-#{NaiveDateTime.to_date(NaiveDateTime.local_now())}")

    view |> element("#period-today") |> render_click()
    assert_patch(view, ~p"/costs?period=today")
    assert has_element?(view, "#period-today.btn-active")

    {:ok, _} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        payload: %{"outcome" => "ok", "cost" => 0.58, "tools" => 1, "duration_ms" => 100}
      })

    assert has_element?(view, "#cost-today", "$1.00")
    assert has_element?(view, "#by-model-unknown")
  end

  test "shows efficiency, triggers, the costliest turns, and channel budgets", %{conn: conn} do
    %{channel: channel, agent: agent} = Fixtures.scenario()
    {:ok, _} = Canopy.Channels.set_spend_limit(channel, 1.0)

    {:ok, big} =
      Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        payload: %{
          "outcome" => "ok",
          "cost" => 1.5,
          "tools" => 4,
          "duration_ms" => 65_000,
          "trigger" => "scheduled",
          "steps" => 3,
          "context" => 25_000,
          "tokens" => %{"input" => 5_000, "cache_read" => 20_000, "output" => 300}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/costs")
    assert has_element?(view, "#eff-steps", "3")
    assert has_element?(view, "#eff-context", "25.0k")
    assert has_element?(view, "#eff-cache", "80%")
    assert has_element?(view, "#eff-prompt", "25.0k")
    assert has_element?(view, "#by-trigger-scheduled", "scheduled tasks")

    assert has_element?(
             view,
             "#turn-#{big.id} a[href='/channels/#{channel.id}']",
             "##{channel.name}"
           )

    assert has_element?(view, "#turn-#{big.id}", "1m")
    assert has_element?(view, "#budget-#{channel.id}", "$1.50 / $1.00")
    assert has_element?(view, "#budget-#{channel.id} .text-error")
  end

  test "picking an auditor and asking for an audit opens a DM with it", %{conn: conn} do
    Mox.set_mox_global()
    %{agent: agent, repository: repository} = Fixtures.scenario()
    alias Canopy.OpenCode.ClientMock, as: OC

    Mox.stub(OC, :mcp_status, fn _dir, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    Mox.stub(OC, :add_mcp, fn _dir, _n, _c, _o ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    Mox.stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
    Mox.stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)

    Mox.stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    on_exit(fn -> Enum.each(Canopy.Channels.list(), &Canopy.Runtime.stop_channel(&1.id)) end)

    {:ok, view, _html} = live(conn, ~p"/costs")
    assert has_element?(view, "#request-audit[disabled]", "Pick an auditor")

    view |> form("#auditor-form", agent_id: agent.id) |> render_change()
    assert has_element?(view, "#request-audit", "Ask @#{agent.name} to audit")
    assert Canopy.Costs.Auditor.agent().id == agent.id

    view |> form("#audit-form", focus: "scheduled tasks") |> render_submit()
    [dm] = Canopy.Channels.list_dms(repository.id)
    assert_redirect(view, ~p"/channels/#{dm.id}")
    [message] = Canopy.Messages.list(dm.id)
    assert message.body =~ "Focus on: scheduled tasks"
  end

  test "the hold banner shows on any page and Release lifts it", %{conn: conn} do
    :ok = Canopy.Hold.engage("Insufficient balance")
    {:ok, view, _html} = live(conn, ~p"/costs")
    assert has_element?(view, "#hold-banner", "Insufficient balance")

    view |> element("#release-hold") |> render_click()
    refute has_element?(view, "#hold-banner")
    refute Canopy.Hold.active?()
  end

  test "breakdowns show six rows with a toggle for the rest", %{conn: conn} do
    %{channel: channel} = Fixtures.scenario()

    for i <- 1..13 do
      agent =
        Fixtures.agent_fixture(%{
          name: "spender-#{String.pad_leading(Integer.to_string(i), 2, "0")}"
        })

      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{"outcome" => "ok", "cost" => i / 100, "tools" => 1, "duration_ms" => 10}
        })
    end

    {:ok, view, _html} = live(conn, ~p"/costs")
    assert row_count(view, "#by-agent li") == 6
    assert has_element?(view, "#by-agent-toggle", "Show 7 more")
    refute has_element?(view, "#by-model-toggle")

    view |> element("#by-agent-toggle") |> render_click()
    assert row_count(view, "#by-agent li") == 13
    assert has_element?(view, "#by-agent-toggle", "Show fewer")
  end

  defp row_count(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
end
