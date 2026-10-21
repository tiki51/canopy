defmodule CanopyWeb.EnginePauseBannerCopyTest do
  # the banner's wording at its edges: counts, and a reset days away
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{EnginePauses, Fixtures}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  setup do
    stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    :ok
  end

  defp usage(seconds),
    do: %{
      kind: "usage",
      reason: "weekly usage limit",
      detail: "You've hit your weekly limit",
      resets_at: DateTime.add(DateTime.utc_now(), seconds)
    }

  test "counts are plural, a zero part is left out, and none at all says nothing", %{conn: conn} do
    %{channel: channel} = Fixtures.scenario()
    {:ok, pause} = EnginePauses.engage("claude_code", usage(3600))

    {:ok, view, _} = live(conn, ~p"/costs")
    row = "#engine-pause-claude_code"
    refute render(element(view, row)) =~ "waiting"
    refute render(element(view, row)) =~ "on a fallback"

    for _ <- 1..2 do
      agent = Fixtures.agent_fixture()
      EnginePauses.mark(pause, agent.id, channel.id, "fallback")
    end

    {:ok, view, _} = live(conn, ~p"/costs")
    assert has_element?(view, row, "2 agents on a fallback.")
    refute render(element(view, row)) =~ "waiting"

    for _ <- 1..3 do
      agent = Fixtures.agent_fixture()
      EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    end

    {:ok, view, _} = live(conn, ~p"/costs")
    assert has_element?(view, row, "3 agents waiting, 2 on a fallback.")
  end

  test "a reset days away gives its day and date, and the countdown counts days", %{conn: conn} do
    {:ok, pause} = EnginePauses.engage("claude_code", usage(2 * 86_400 + 3 * 3600 + 30))

    {:ok, view, _} = live(conn, ~p"/costs")
    row = "#engine-pause-claude_code"

    assert has_element?(view, row, "Claude Code is paused: weekly usage limit.")
    assert has_element?(view, row <> " [phx-hook$=Countdown]", "in 2d 3h")
    assert has_element?(view, row <> " time[datetime='#{DateTime.to_iso8601(pause.resets_at)}']")
    # not today's time alone: the day is named
    assert has_element?(view, row <> " time", Canopy.Schedules.local_text(pause.resets_at))
  end
end
