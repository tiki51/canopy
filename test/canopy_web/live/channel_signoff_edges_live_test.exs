defmodule CanopyWeb.ChannelSignoffEdgesLiveTest do
  @moduledoc "Sign-off card edge cases in the channel view (test plan §4, L12–L30)."
  use CanopyWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 2]
  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Fixtures, Repo, Signoffs, Timeline}
  alias Canopy.Playbooks.Runs

  setup :set_mox_global

  setup do
    designer = Fixtures.agent_fixture(%{name: "designer" <> Fixtures.unique_suffix()})
    ctx = Fixtures.scenario(members: [designer])
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    Timeline.subscribe(ctx.channel.id)

    playbook =
      playbook_fixture("ship-it", [
        {"plan", "Plan", "coordinator"},
        {"design", "Design approval", "coordinator", "approval: user"},
        {"build", "Build", "coordinator"}
      ])

    Map.merge(ctx, %{designer: designer, playbook: playbook})
  end

  @options [%{"label" => "Totals on top"}, %{"label" => "Banner"}, %{"label" => "Minimal"}]

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  defp ask!(ctx, attrs \\ %{}) do
    {:ok, signoff} =
      Signoffs.request(
        Map.merge(
          %{
            channel_id: ctx.channel.id,
            agent_id: ctx.designer.id,
            title: "Header design",
            question: "Is the header done?"
          },
          attrs
        )
      )

    signoff
  end

  defp hold!(ctx) do
    {:ok, run, false} =
      Runs.start(%{
        playbook: ctx.playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "A new header"
      })

    {:ok, run, _} = Runs.advance(run, {:agent, ctx.agent.id}, result: "planned")
    {:ok, run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "Done.")
    drain_prompts()
    {run, Signoffs.pending_for_run(run.id)}
  end

  defp press(view, signoff, verdict, note \\ "") do
    render_hook(view, "answer_signoff", %{
      "signoff_id" => signoff.id,
      "verdict" => verdict,
      "note" => note
    })
  end

  defp drain_prompts do
    receive do
      {:prompted, _, _} -> drain_prompts()
    after
      200 -> :ok
    end
  end

  defp open_panel(view), do: view |> element("#playbook-chip") |> render_click()

  defp answers(channel_id),
    do: channel_id |> Canopy.Messages.list() |> Enum.count(&(&1.body =~ "your sign-off"))

  test "two tabs pressing one freestanding card: one answer, no flash in either",
       %{conn: conn} = ctx do
    so = ask!(ctx)
    {:ok, a, _} = open(conn, ctx.channel)
    {:ok, b, _} = open(conn, ctx.channel)

    html_a = press(a, so, "accept")
    html_b = press(b, so, "accept", "late")

    refute html_a =~ "already answered"
    refute html_b =~ "already answered"
    assert answers(ctx.channel.id) == 1
    assert Repo.reload(so).note == nil
    refute has_element?(b, "#signoff-#{so.id}")
  end

  test "two tabs pressing one run card: the step is released once", %{conn: conn} = ctx do
    {run, so} = hold!(ctx)
    {:ok, a, _} = open(conn, ctx.channel)
    {:ok, b, _} = open(conn, ctx.channel)

    press(a, so, "accept")
    html_b = press(b, so, "reject", "no")

    refute html_b =~ "already answered"
    refute html_b =~ "changed meanwhile"
    assert Repo.reload(so).status == "accepted"
    assert_receive {:prompted, _, _}, 2_000
    refute_receive {:prompted, _, _}, 300
    assert Runs.get!(run.id).status != "awaiting_approval"
  end

  test "an id from another channel, or none in the view, answers nothing", %{conn: conn} = ctx do
    other = Fixtures.scenario(members: [ctx.designer])
    foreign = ask!(%{ctx | channel: other.channel})
    mine = ask!(ctx)
    {:ok, view, _} = open(conn, ctx.channel)

    press(view, foreign, "accept")
    press(view, %{id: "so_nope"}, "accept")

    assert Repo.reload(foreign).status == "pending"
    assert Repo.reload(mine).status == "pending"
    assert has_element?(view, "#signoff-#{mine.id}")
  end

  test "more malformed verdicts do nothing; accept with no pick on options flashes",
       %{conn: conn} = ctx do
    so = ask!(ctx, %{options: @options})
    plain = ask!(ctx, %{title: "Plain"})
    {:ok, view, _} = open(conn, ctx.channel)

    for v <- ["accept:1.5", "accept: 1", "accept:", "ACCEPT", "", "accept:3"],
        do: press(view, so, v)

    press(view, plain, "accept:0")
    assert Repo.reload(so).status == "pending"
    assert Repo.reload(plain).status == "pending"

    html = press(view, so, "accept")
    assert html =~ "Pick an option."
    assert Repo.reload(so).status == "pending"
  end

  test "a 2001-character note is refused with a flash; 2000 goes through", %{conn: conn} = ctx do
    so = ask!(ctx)
    {:ok, view, _} = open(conn, ctx.channel)

    html = press(view, so, "accept", String.duplicate("n", 2_001))
    assert html =~ "The note is too long."
    assert Repo.reload(so).status == "pending"
    assert has_element?(view, "#signoff-#{so.id}")

    press(view, so, "accept", String.duplicate("n", 2_000))
    assert Repo.reload(so).status == "accepted"
  end

  test "a blank press takes the card's saved note, but not one the user cleared or another card's",
       %{conn: conn} = ctx do
    saved = ask!(ctx, %{title: "Saved"})
    cleared = ask!(ctx, %{title: "Cleared"})
    {:ok, view, _} = open(conn, ctx.channel)

    render_hook(view, "signoff_note", %{"signoff_id" => saved.id, "note" => "from the blur"})
    render_hook(view, "signoff_note", %{"signoff_id" => cleared.id, "note" => "second thoughts"})
    render_hook(view, "signoff_note", %{"signoff_id" => cleared.id, "note" => ""})

    press(view, cleared, "accept")
    assert Repo.reload(cleared).note in [nil, ""]

    press(view, saved, "accept")
    assert Repo.reload(saved).note == "from the blur"
  end

  test "Enter can't submit either form: both start with a disabled, hidden default button",
       %{conn: conn} = ctx do
    {_run, so} = hold!(ctx)
    {:ok, view, _} = open(conn, ctx.channel)
    open_panel(view)

    for form <- ["#signoff-#{so.id}-form", "#playbook-signoff-form"] do
      assert has_element?(view, "#{form} > button[type=submit][disabled][hidden]:first-child")
    end

    assert has_element?(view, "#playbook-signoff-note[maxlength='2000']")
  end

  test "during an environment reset a press is refused and changes nothing",
       %{conn: conn} = ctx do
    so = ask!(ctx)
    {run, run_so} = hold!(ctx)
    {:ok, view, _} = open(conn, ctx.channel)
    Canopy.EnvironmentHelpers.raise_gate()

    for {card, verdict} <- [
          {so, "accept"},
          {so, "reject"},
          {run_so, "accept"},
          {run_so, "reject"}
        ] do
      html = press(view, card, verdict)
      assert html =~ "Canopy is resetting"
    end

    assert Repo.reload(so).status == "pending"
    assert Repo.reload(run_so).status == "pending"
    assert Runs.get!(run.id).status == "awaiting_approval"
    assert answers(ctx.channel.id) == 0
    refute_receive {:prompted, _, _}, 200

    # a draft can still be typed
    render_hook(view, "signoff_note", %{"signoff_id" => so.id, "note" => "later"})
    assert "answer_signoff" in CanopyWeb.ChannelLive.runtime_events()
    refute "approve_playbook_step" in CanopyWeb.ChannelLive.runtime_events()
  end

  test "an archived channel's freestanding Reject clears the card and shows the row",
       %{conn: conn} = ctx do
    so = ask!(ctx)
    {:ok, _} = Canopy.Channels.archive(ctx.channel)
    {:ok, view, _} = open(conn, ctx.channel)

    press(view, so, "reject", "not now")
    assert Repo.reload(so).status == "rejected"
    refute has_element?(view, "#signoff-#{so.id}")
    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000
    assert has_element?(view, "#signoff-resolved-#{so.id}:not([hidden])", "You rejected")
    assert answers(ctx.channel.id) == 0
  end

  test "a deleted asker: 'An agent' asks, and the answer's row shows without 'for @'",
       %{conn: conn} = ctx do
    gone = Fixtures.agent_fixture()
    so = ask!(ctx, %{agent_id: gone.id})
    Repo.delete!(Canopy.Agents.get(gone.id))
    {:ok, view, _} = open(conn, ctx.channel)

    assert has_element?(view, "#signoff-#{so.id}-title", "An agent wants your sign-off")
    assert has_element?(view, "#awaiting-bar", "An agent wants your sign-off")

    press(view, so, "accept", "fine")
    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000
    row = view |> element("#signoff-resolved-#{so.id}") |> render()
    assert row =~ "You accepted"
    refute row =~ "for @"
    refute row =~ "hidden"
  end

  test "reassign, then accept from the run panel: the new coordinator is woken",
       %{conn: conn} = ctx do
    {run, so} = hold!(ctx)
    {:ok, _run, _} = Runs.reassign(Runs.get!(run.id), ctx.designer, "user")
    drain_prompts()
    {:ok, view, _} = open(conn, ctx.channel)
    open_panel(view)

    assert has_element?(view, "#signoff-#{so.id}-title", "@#{ctx.agent.name}")
    view |> element("#playbook-signoff-form") |> render_submit(%{"verdict" => "accept"})

    assert_receive {:prompted, sid, _}, 2_000
    assert %{agent_id: agent_id} = Canopy.AgentSessions.get_by_engine_id("opencode", sid)
    assert agent_id == ctx.designer.id
  end

  test "cancelling the run while the card is open withdraws it quietly", %{conn: conn} = ctx do
    {run, so} = hold!(ctx)
    {:ok, view, _} = open(conn, ctx.channel)
    open_panel(view)

    {:ok, _, _} = Runs.cancel(Runs.get!(run.id), :user, "changed my mind")
    assert_receive {:timeline, %{event_type: "signoff_withdrawn"}}, 2_000

    refute has_element?(view, "#signoff-#{so.id}")
    refute has_element?(view, "#playbook-signoff")
    assert render(view) =~ "was withdrawn"
    refute render(view) =~ "already answered"
  end

  test "card text is escaped", %{conn: conn} = ctx do
    so =
      ask!(ctx, %{
        title: "<img src=x onerror=alert(1)>",
        question: "<script>alert(2)</script>",
        options: [%{"label" => "<b>A</b>"}, %{"label" => "B"}]
      })

    {:ok, view, html} = open(conn, ctx.channel)
    refute html =~ "<img src=x"
    refute html =~ "<script>alert(2)"
    refute html =~ "<b>A</b>"

    press(view, so, "accept:0", "<img src=y onerror=alert(3)>")
    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000
    refute render(view) =~ "<img src=y"
  end

  test "two pending cards: answering one leaves the other", %{conn: conn} = ctx do
    a = ask!(ctx)
    b = ask!(ctx, %{agent_id: ctx.agent.id, title: "Colours"})
    {:ok, view, _} = open(conn, ctx.channel)

    assert has_element?(view, "#awaiting-show-signoff-#{a.id}")
    assert has_element?(view, "#awaiting-show-signoff-#{b.id}")

    press(view, a, "accept")
    refute has_element?(view, "#signoff-#{a.id}")
    assert has_element?(view, "#signoff-#{b.id}")
    assert has_element?(view, "#awaiting-show-signoff-#{b.id}")
  end

  test "mounting after an answer shows the row, not the card", %{conn: conn} = ctx do
    {_run, so} = hold!(ctx)
    {:ok, _} = Signoffs.accept(so, nil, "ok")
    {:ok, view, _} = open(conn, ctx.channel)

    refute has_element?(view, "#signoff-#{so.id}")
    assert has_element?(view, "#signoff-resolved-#{so.id}", "You accepted")
  end

  test "a backfilled run card with no agent and no coordinator still releases",
       %{conn: conn} = ctx do
    {run, so} = hold!(ctx)
    {1, _} = Repo.update_all(where(Signoffs.SignoffRequest, id: ^so.id), set: [agent_id: nil])

    {1, _} =
      Repo.update_all(where(Canopy.Playbooks.Run, id: ^run.id), set: [coordinator_agent_id: nil])

    {:ok, view, _} = open(conn, ctx.channel)
    assert has_element?(view, "#signoff-#{so.id}-title", "ship-it wants your sign-off")

    press(view, so, "accept")
    assert Repo.reload(so).status == "accepted"
    refute_receive {:prompted, _, _}, 300
  end
end
