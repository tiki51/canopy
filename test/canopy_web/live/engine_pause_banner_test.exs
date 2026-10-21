defmodule CanopyWeb.EnginePauseBannerTest do
  # the banner every page shows for paused engines (CanopyWeb.Layouts, CanopyWeb.Nav)
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{EnginePauses, Fixtures, PlaybookHelpers}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  setup do
    stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    :ok
  end

  defp usage(minutes),
    do: %{
      kind: "usage",
      reason: "usage limit",
      detail: "You've hit your limit",
      resets_at: DateTime.add(DateTime.utc_now(), minutes * 60 + 30)
    }

  @billing %{kind: "billing", reason: "insufficient balance", detail: "Credit balance is too low"}

  test "a usage pause shows its reset, countdown and counts, on any page", %{conn: conn} do
    %{channel: channel, agent: agent} = Fixtures.scenario()
    other = Fixtures.agent_fixture()
    {:ok, pause} = EnginePauses.engage("claude_code", usage(134))
    EnginePauses.mark(pause, agent.id, channel.id, "waiting")
    EnginePauses.mark(pause, other.id, channel.id, "fallback")

    for path <- [~p"/costs", ~p"/channels/#{channel.id}", ~p"/settings"] do
      {:ok, view, _html} = live(conn, path)
      row = "#engine-pause-claude_code[data-tone=warning]"

      assert has_element?(view, row, "Claude Code is paused: usage limit.")
      assert has_element?(view, row, "Resets at")
      assert has_element?(view, row <> " [phx-hook$=Countdown]", "in 2h 14m")
      # no stray space inside the brackets
      assert has_element?(view, row, "(in 2h 14m).")
      assert has_element?(view, row, "1 agent waiting, 1 on a fallback.")
      assert has_element?(view, row <> " span[title='You\\'ve hit your limit']")
      assert has_element?(view, "#resume-engine-claude_code", "Resume now")
    end
  end

  test "a pause with no reset time is red with Release, and comes first", %{conn: conn} do
    {:ok, _} = EnginePauses.engage("claude_code", usage(30))
    {:ok, _} = EnginePauses.engage("opencode", @billing)

    {:ok, view, html} = live(conn, ~p"/costs")

    assert has_element?(
             view,
             "#engine-pause-opencode[data-tone=error]",
             "OpenCode is paused: insufficient balance. Agents on OpenCode wait until you release it."
           )

    assert has_element?(view, "#resume-engine-opencode", "Release")
    # no agents yet: no counts sentence
    refute has_element?(view, "#engine-pause-opencode", "waiting")

    [opencode, claude] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#engine-pauses > [id^=engine-pause-]")
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

    assert {opencode, claude} == {"engine-pause-opencode", "engine-pause-claude_code"}
  end

  test "Resume now lifts the pause; the flash says who was nudged", %{conn: conn} do
    %{channel: channel, agent: agent, repository: repository} = Fixtures.scenario()
    PlaybookHelpers.stub_engine(self(), repository)
    {:ok, pause} = EnginePauses.engage("opencode", usage(60))
    EnginePauses.mark(pause, agent.id, channel.id, "waiting")

    {:ok, view, _html} = live(conn, ~p"/costs")
    view |> element("#resume-engine-opencode") |> render_click()

    refute has_element?(view, "#engine-pauses")
    assert render(view) =~ "OpenCode resumed. Agents that waited were nudged."
    refute EnginePauses.paused?("opencode")

    # the agent that waited was nudged
    assert_receive {:prompted, _session, _body}, 2_000
    PlaybookHelpers.stop_channels()
  end

  test "Release with nobody waiting says only that it resumed", %{conn: conn} do
    {:ok, _} = EnginePauses.engage("claude_code", @billing)

    {:ok, view, _html} = live(conn, ~p"/costs")
    view |> element("#resume-engine-claude_code") |> render_click()

    html = render(view)
    assert html =~ "Claude Code resumed."
    refute html =~ "Agents that waited"
  end

  test "the palette's resume_engine with no engine resumes them all", %{conn: conn} do
    {:ok, _} = EnginePauses.engage("claude_code", @billing)
    {:ok, _} = EnginePauses.engage("codex", usage(60))

    {:ok, view, _html} = live(conn, ~p"/costs")
    render_hook(view, "resume_engine", %{})

    refute has_element?(view, "#engine-pauses")
    assert render(view) =~ "Claude Code and Codex resumed."
  end

  test "pauses from elsewhere show and go without a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/costs")
    refute has_element?(view, "#engine-pauses")

    {:ok, _} = EnginePauses.engage("codex", @billing)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#engine-pause-codex")

    :ok = EnginePauses.resume("codex", "reset")
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#engine-pauses")
  end

  test "the reset modal keeps engine pauses", %{conn: conn} do
    {:ok, _} = EnginePauses.engage("claude_code", @billing)
    {:ok, view, _html} = live(conn, ~p"/settings")
    view |> element("#open-reset") |> render_click()
    assert has_element?(view, "#reset-kept li", "Engine pauses (on)")
  end
end
