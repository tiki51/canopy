defmodule CanopyWeb.ChannelSignoffLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 2]
  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers

  alias Canopy.{Documents, Fixtures, Repo, Signoffs, Timeline}
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

  @options [
    %{"label" => "Totals on top", "description" => "Logo left, amount top-right."},
    %{"label" => "Banner", "recommended" => true},
    %{"label" => "Minimal", "description" => "Text only."}
  ]

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

  # A run held at its approval step, with a sign-off card (`card` attrs).
  defp hold!(ctx, card \\ %{}) do
    {:ok, run, false} =
      Runs.start(%{
        playbook: ctx.playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "A new header"
      })

    {:ok, run, _} = Runs.advance(run, {:agent, ctx.agent.id}, result: "planned")

    {:ok, run, :awaiting_approval} =
      Runs.advance(run, {:agent, ctx.agent.id},
        result: "Three designs written up.",
        signoff: card
      )

    {run, Signoffs.pending_for_run(run.id)}
  end

  defp submit(view, form, signoff, verdict, note \\ "") do
    view
    |> element(form)
    |> render_submit(%{"signoff_id" => signoff.id, "verdict" => verdict, "note" => note})
  end

  defp open_panel(view), do: view |> element("#playbook-chip") |> render_click()

  defp doc!(filename) do
    {:ok, doc} =
      Documents.create(%{
        filename: filename,
        source: {:binary, "# Designs\n"},
        user_id: Fixtures.user_fixture().id
      })

    doc
  end

  defp drain_prompts do
    receive do
      {:prompted, _, _} -> drain_prompts()
    after
      0 -> :ok
    end
  end

  test "a freestanding card: Accept with a note posts the answer as the user's message, and the row stays hidden",
       %{conn: conn} = ctx do
    doc = doc!("header-designs.md")
    so = ask!(ctx, %{summary: "Three **designs** are written up.", document_ids: [doc.id]})
    {:ok, view, _html} = open(conn, ctx.channel)

    assert has_element?(view, "#signoff-#{so.id}-title", "@#{ctx.designer.name}")
    assert has_element?(view, "#signoff-#{so.id}-title", "wants your sign-off")
    assert has_element?(view, "#signoff-#{so.id}-title", "Header design")
    assert has_element?(view, "#signoff-#{so.id}", "Is the header done?")
    assert has_element?(view, "#signoff-#{so.id}-summary strong", "designs")
    refute has_element?(view, "#signoff-#{so.id}-badge")
    # the file opens in the viewer, in the card's own strip
    assert has_element?(
             view,
             ~s(#signoff-#{so.id} a[href*="file=#{doc.id}"][href*="in=#{so.id}"])
           )

    # Enter in the note can't press Reject: the form's default button is disabled
    assert has_element?(
             view,
             "#signoff-#{so.id}-form > button[type=submit][disabled]:first-child"
           )

    assert has_element?(view, "#signoff-#{so.id}-note[maxlength='2000']")

    submit(view, "#signoff-#{so.id}-form", so, "accept", "keep the badge grey")
    assert_push_event(view, "composer:focus", %{id: "composer-input"})

    assert Repo.reload(so).status == "accepted"
    assert Repo.reload(so).note == "keep the badge grey"
    refute has_element?(view, "#signoff-#{so.id}")
    refute has_element?(view, "#awaiting-show-signoff-#{so.id}")

    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000
    assert render(view) =~ "Accepted your sign-off"
    assert has_element?(view, "#timeline", "keep the badge grey")
    assert has_element?(view, "#signoff-resolved-#{so.id}[hidden]")

    # the posted message wakes the designer
    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "Accepted your sign-off"
  end

  test "a held run with three options: the recommended one is solid, and its Accept records the pick",
       %{conn: conn} = ctx do
    {_run, so} = hold!(ctx, %{question: "Which header should we build?", options: @options})
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)

    assert has_element?(view, "#signoff-#{so.id}[data-options='3']")
    assert has_element?(view, "#signoff-#{so.id}-badge", "ship-it · step 2 of 3")
    assert has_element?(view, "#signoff-#{so.id}-option-1", "recommended")
    assert has_element?(view, "#signoff-#{so.id}-accept-1:not(.btn-outline)")
    assert has_element?(view, "#signoff-#{so.id}-accept-0.btn-outline")
    assert has_element?(view, "#signoff-#{so.id}-accept-2.btn-outline")

    assert has_element?(
             view,
             ~s{#signoff-#{so.id}-accept-1[aria-label="Accept B: Banner (recommended)"]}
           )

    submit(view, "#signoff-#{so.id}-form", so, "accept:2")

    assert Repo.reload(so).choice_index == 2
    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000

    assert has_element?(
             view,
             "#signoff-resolved-#{so.id}[data-status='accepted']",
             "You accepted C · Minimal for @#{ctx.agent.name}'s Design approval"
           )

    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "Minimal"
  end

  test "Reject all with no note: the row says so, with no quote", %{conn: conn} = ctx do
    {_run, so} = hold!(ctx, %{question: "Which header?", options: @options})
    {:ok, view, _html} = open(conn, ctx.channel)

    submit(view, "#signoff-#{so.id}-form", so, "reject")
    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000

    assert has_element?(
             view,
             "#signoff-resolved-#{so.id}[data-status='rejected']",
             "You rejected all options for"
           )

    refute render(element(view, "#signoff-resolved-#{so.id}")) =~ "“"
  end

  test "Accept on the timeline card releases the held step and wakes the coordinator",
       %{conn: conn} = ctx do
    {run, so} = hold!(ctx)
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)
    open_panel(view)

    assert has_element?(view, "#signoff-#{so.id}")
    assert has_element?(view, "#playbook-signoff[data-signoff='#{so.id}']")
    assert has_element?(view, "#playbook-signoff-show[href='#signoff-#{so.id}']")
    refute has_element?(view, "#approve-playbook-step")

    submit(view, "#signoff-#{so.id}-form", so, "accept")

    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "Design approval"

    assert Runs.get!(run.id)
           |> Map.get(:steps)
           |> Enum.find(&(&1.step_id == "design"))
           |> Map.get(:status) == "done"

    refute has_element?(view, "#signoff-#{so.id}")
    refute has_element?(view, "#playbook-signoff")
    assert has_element?(view, "#playbook-step-design[data-status='done']")

    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000
    assert has_element?(view, "#signoff-resolved-#{so.id}", "You accepted")
    # the run's own approval line is hidden: one line, not two
    refute render(view) =~ "approved Design approval of"
  end

  test "Reject from the run panel with no note puts the step back to work",
       %{conn: conn} = ctx do
    {_run, so} = hold!(ctx)
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)
    open_panel(view)

    submit(view, "#playbook-signoff-form", so, "reject")

    assert_receive {:prompted, _sid, _body}, 2_000
    assert has_element?(view, "#playbook-step-design[data-status='active']")
    refute has_element?(view, "#signoff-#{so.id}")
    assert Repo.reload(so).status == "rejected"
  end

  test "a run card answered in another tab: this one drops both cards with no flash, and a stale press says nothing",
       %{conn: conn} = ctx do
    {_run, so} = hold!(ctx)
    {:ok, view, _html} = open(conn, ctx.channel)
    open_panel(view)

    {:ok, _} = Signoffs.accept(so.id, nil, nil)
    assert_receive {:timeline, %{event_type: "signoff_resolved"}}, 2_000

    refute has_element?(view, "#signoff-#{so.id}")
    refute has_element?(view, "#playbook-signoff")
    assert has_element?(view, "#signoff-resolved-#{so.id}", "You accepted")

    # a press the page sent before it heard
    html = render_hook(view, "answer_signoff", %{"signoff_id" => so.id, "verdict" => "accept"})
    refute html =~ "already answered"
  end

  test "a note typed in the timeline card goes with a press in the run panel",
       %{conn: conn} = ctx do
    {_run, so} = hold!(ctx)
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)
    open_panel(view)

    view
    |> element("#signoff-#{so.id}-form")
    |> render_change(%{"signoff_id" => so.id, "note" => "make it bold"})

    assert has_element?(view, "#playbook-signoff-note[value='make it bold']")

    view
    |> element("#playbook-signoff-form")
    |> render_submit(%{"verdict" => "accept"})

    assert Repo.reload(so).note == "make it bold"
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "in an archived channel a freestanding Accept is refused; a held run still releases",
       %{conn: conn} = ctx do
    so = ask!(ctx)
    {run, run_so} = hold!(ctx)
    drain_prompts()
    {:ok, _} = Canopy.Channels.archive(ctx.channel)
    {:ok, view, _html} = open(conn, ctx.channel)

    html = submit(view, "#signoff-#{so.id}-form", so, "accept")
    assert html =~ "Unarchive (Reopen) the channel to answer"
    assert Repo.reload(so).status == "pending"
    assert has_element?(view, "#signoff-#{so.id}")

    submit(view, "#signoff-#{run_so.id}-form", run_so, "accept")
    assert Repo.reload(run_so).status == "accepted"
    assert Runs.get!(run.id).status != "awaiting_approval"
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "the awaiting bar lists the sign-off and points at its card", %{conn: conn} = ctx do
    so = ask!(ctx)
    {:ok, view, _html} = open(conn, ctx.channel)

    assert has_element?(view, "#awaiting-bar", "@#{ctx.designer.name} wants your sign-off")
    assert has_element?(view, "#awaiting-show-signoff-#{so.id}[href='#signoff-#{so.id}']")
  end

  test "a run's approval events carrying a signoff_id are hidden; older ones still show",
       %{conn: conn} = ctx do
    {run, _so} = hold!(ctx)

    {:ok, _old} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        event_type: "playbook_approval_requested",
        ref_id: run.id,
        payload: %{"playbook" => "old-run", "title" => "Legacy gate"}
      })

    {:ok, view, _html} = open(conn, ctx.channel)
    html = render(view)

    assert html =~ "old-run is waiting for your sign-off on Legacy gate"
    refute html =~ "ship-it is waiting for your sign-off on Design approval"
    assert html =~ "asked for your sign-off on Design approval"
  end

  test "pressing the same card twice answers once and says nothing the second time",
       %{conn: conn} = ctx do
    so = ask!(ctx, %{options: @options})
    {:ok, view, _html} = open(conn, ctx.channel)

    submit(view, "#signoff-#{so.id}-form", so, "accept:1")
    html = render_hook(view, "answer_signoff", %{"signoff_id" => so.id, "verdict" => "accept:1"})
    refute html =~ "already answered"

    assert_receive {:prompted, _sid, _body}, 2_000
    refute_receive {:prompted, _sid, _body}, 300

    answers =
      Canopy.Messages.list(ctx.channel.id)
      |> Enum.count(&(&1.body =~ "Accepted your sign-off"))

    assert answers == 1
  end

  test "a malformed verdict does nothing", %{conn: conn} = ctx do
    so = ask!(ctx, %{options: @options})
    {:ok, view, _html} = open(conn, ctx.channel)

    for verdict <- ["accept:9", "accept:-1", "accept:x", "accept:1x", "approve", nil] do
      render_hook(view, "answer_signoff", %{"signoff_id" => so.id, "verdict" => verdict})
    end

    assert Repo.reload(so).status == "pending"
    assert has_element?(view, "#signoff-#{so.id}")
  end

  test "a run card with no agent is named for its playbook, and still releases the step",
       %{conn: conn} = ctx do
    {run, so} = hold!(ctx)
    {1, _} = Repo.update_all(where(Signoffs.SignoffRequest, id: ^so.id), set: [agent_id: nil])
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)

    assert has_element?(view, "#signoff-#{so.id}-title", "ship-it wants your sign-off")
    assert has_element?(view, "#awaiting-bar", "ship-it wants your sign-off")
    assert has_element?(view, "label[for='signoff-#{so.id}-note']", "Note (optional)")

    submit(view, "#signoff-#{so.id}-form", so, "accept")
    assert_receive {:prompted, _sid, _body}, 2_000
    assert Runs.get!(run.id).status != "awaiting_approval"
  end

  test "every answer button carries the spinner it shows while pressed", %{conn: conn} = ctx do
    so = ask!(ctx)
    {_run, run_so} = hold!(ctx)
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)
    open_panel(view)

    for id <- ["#signoff-#{so.id}-accept", "#signoff-#{so.id}-reject", "#playbook-signoff-accept"],
        do: assert(has_element?(view, "#{id}.signoff-verdict .signoff-spinner"))

    for card <- ["#signoff-#{so.id}", "#signoff-#{run_so.id}", "#playbook-signoff"] do
      refute has_element?(view, "#{card} button[name=verdict]:not(.signoff-verdict)")
      # disable-with would restore the label as text, dropping the icon
      refute has_element?(view, "#{card} [phx-disable-with]")
    end
  end

  test "an answer or a note with its fields missing does nothing", %{conn: conn} = ctx do
    so = ask!(ctx)
    {:ok, view, _html} = open(conn, ctx.channel)

    render_hook(view, "answer_signoff", %{"verdict" => "accept"})
    render_hook(view, "signoff_note", %{"signoff_id" => so.id})
    render_hook(view, "signoff_note", %{"note" => "orphan"})

    assert Repo.reload(so).status == "pending"
    assert has_element?(view, "#signoff-#{so.id}")
  end

  test "a press with a blank note sends the note reported on blur", %{conn: conn} = ctx do
    so = ask!(ctx)
    {:ok, view, _html} = open(conn, ctx.channel)

    render_hook(view, "signoff_note", %{"signoff_id" => so.id, "note" => "ship it"})
    submit(view, "#signoff-#{so.id}-form", so, "accept", "")

    assert Repo.reload(so).note == "ship it"
    assert_receive {:prompted, _sid, _body}, 2_000
  end

  test "Show card below lg closes Details before scrolling to the card; from lg up Details stays",
       %{conn: conn} = ctx do
    {_run, so} = hold!(ctx)
    drain_prompts()
    {:ok, view, _html} = open(conn, ctx.channel)

    render_hook(view, "pref", %{"key" => "channel-details", "value" => "open", "media" => false})
    open_panel(view)
    assert has_element?(view, "#details-panel #playbook-signoff-show")

    view |> element("#playbook-signoff-show") |> render_click()
    assert_push_event(view, "signoff:show", %{id: "signoff-" <> _})
    refute has_element?(view, "#details-panel")
    assert has_element?(view, "#signoff-#{so.id}")

    render_hook(view, "pref", %{"key" => "channel-details", "value" => "open", "media" => true})
    open_panel(view)
    view |> element("#playbook-signoff-show") |> render_click()
    assert_push_event(view, "signoff:show", %{id: id})
    assert id == "signoff-#{so.id}"
    assert has_element?(view, "#details-panel #playbook-signoff")
  end
end
