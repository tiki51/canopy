defmodule Canopy.Playbooks.RunsTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Channels, Delegations, Handoffs, Repo, Teams, Timeline}
  alias Canopy.Playbooks.{Run, Runs}
  alias Canopy.Signoffs
  alias Canopy.Signoffs.SignoffRequest

  setup :set_mox_global

  setup do
    ctx = scenario()
    # after the repository fixture's own on_exit, so channel servers stop first
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    Timeline.subscribe(ctx.channel.id)
    Runs.subscribe()
    ctx
  end

  @steps [
    {"plan", "Plan", "coordinator"},
    {"build", "Build", "dev"},
    {"check", "Check", "qa", "optional: true"},
    {"ship", "Ship", "dev"}
  ]

  defp roles_playbook(name \\ "flow"),
    do: playbook_fixture(name, @steps, "roles:\n  dev: #{dev().name}\n  qa: #{qa().name}\n")

  defp dev, do: Canopy.Agents.get_by_name("dev-agent") || agent_fixture(name: "dev-agent")
  defp qa, do: Canopy.Agents.get_by_name("qa-agent") || agent_fixture(name: "qa-agent")

  defp start!(ctx, playbook, attrs \\ %{}) do
    {:ok, run, new?} =
      Runs.start(
        Map.merge(
          %{
            playbook: playbook,
            channel: ctx.channel,
            coordinator: ctx.agent,
            started_by_agent_id: ctx.agent.id,
            brief: "the brief"
          },
          attrs
        )
      )

    {run, new?}
  end

  describe "starting" do
    test "a run in the channel: roster from roles, members added, first step active, events",
         ctx do
      playbook = roles_playbook()
      {run, false} = start!(ctx, playbook, %{started_by_agent_id: ctx.agent.id})

      assert run.status == "active"
      assert run.current_step == "plan"
      assert run.roster == %{"dev" => dev().id, "qa" => qa().id}
      assert run.stall_after_minutes == 30
      assert run.definition == playbook.body
      assert [plan, build, check, ship] = run.steps
      assert %{status: "active", round: 1, owner_ids: []} = plan
      assert %{status: "pending", round: 0, owner_ids: [dev_id]} = build
      assert dev_id == dev().id
      assert check.optional
      assert ship.owner_ids == [dev().id]

      assert Channels.member?(ctx.channel, dev())
      assert Channels.member?(ctx.channel, qa())

      assert_receive {:timeline, %{event_type: "playbook_started", payload: %{"steps" => 4}}}

      assert_receive {:timeline,
                      %{event_type: "playbook_step_started", payload: %{"step" => "plan"}}}

      channel_id = ctx.channel.id
      assert_receive {:playbook_runs, :changed, ^channel_id}
    end

    test "roster precedence: assign, then team role label, then team member name, then roles",
         ctx do
      labelled = agent_fixture(name: "labelled-" <> unique_suffix())
      named = agent_fixture(name: "fixer")
      default = agent_fixture(name: "default-" <> unique_suffix())
      override = agent_fixture(name: "override-" <> unique_suffix())
      team = team_fixture([labelled, named], %{name: "crew-" <> unique_suffix()})

      Repo.update_all(
        from(m in Teams.TeamMember, where: m.team_id == ^team.id and m.agent_id == ^labelled.id),
        set: [role: "tester"]
      )

      playbook =
        playbook_fixture(
          "crewed",
          [
            {"test", "Test", "tester"},
            {"fix", "Fix", "fixer"},
            {"docs", "Docs", "writer"},
            {"extra", "Extra", "tester"}
          ],
          "team: #{team.name}\nroles:\n  writer: #{default.name}\n  tester: #{default.name}\n"
        )

      {run, false} = start!(ctx, playbook)
      assert run.roster == %{"tester" => labelled.id, "fixer" => named.id, "writer" => default.id}

      # the team joined in one line
      assert_receive {:timeline,
                      %{event_type: "team_added", payload: %{"team_name" => team_name}}}

      assert team_name == team.name
      assert Channels.member?(ctx.channel, default)

      {:ok, _, :cancelled} = Runs.cancel(run, :user, "again")
      {run, false} = start!(ctx, playbook, %{assign: "tester=@#{override.name}"})
      assert run.roster["tester"] == override.id
    end

    test "an inactive agent or an unfilled role fails the start with a reason", ctx do
      playbook = roles_playbook()
      {:ok, _} = Canopy.Agents.deactivate(qa())

      assert {:error, reason} =
               Runs.start(%{
                 playbook: playbook,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 brief: "x"
               })

      assert reason =~ "role qa"
      assert reason =~ "deactivated"

      lonely = playbook_fixture("lonely", [{"a", "A", "ghost"}], "roles:\n  ghost: nobody-here\n")

      assert {:error, reason} =
               Runs.start(%{
                 playbook: lonely,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 brief: "x"
               })

      assert reason =~ "no agent @nobody-here for role ghost"

      assert {:error, reason} =
               Runs.start(%{
                 playbook: playbook,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 brief: "x",
                 assign: "nope=@x"
               })

      assert reason =~ "has no role nope"
    end

    test "disabled playbooks and over-long briefs are refused", ctx do
      playbook = roles_playbook()
      {:ok, disabled} = Canopy.Playbooks.set_enabled(playbook, false)

      assert {:error, reason} =
               Runs.start(%{
                 playbook: disabled,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 brief: "x"
               })

      assert reason =~ "disabled"

      assert {:error, "the brief is too long" <> _} =
               Runs.start(%{
                 playbook: playbook,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 brief: String.duplicate("x", 8_001)
               })
    end

    test "the brief is optional: missing, empty and blank are all stored as \"\"", ctx do
      playbook = roles_playbook()

      for brief <- [nil, "", "   \n "] do
        {run, false} = start!(ctx, playbook, %{brief: brief})
        assert run.status == "active"
        assert run.brief == ""
        assert Repo.reload!(run).brief == ""
        {:ok, _, :cancelled} = Runs.cancel(run, :user, "again")
      end

      {run, false} = start!(ctx, playbook, %{brief: "  padded  "})
      assert run.brief == "padded"
    end

    test "the Run changeset stores a blank brief as \"\", never nil", ctx do
      for brief <- ["", "   ", nil] do
        changeset =
          Run.changeset(%Run{}, %{
            playbook_name: "flow",
            definition: "x",
            channel_id: ctx.channel.id,
            status: "completed",
            brief: brief
          })

        assert changeset.valid?, inspect(brief)
        assert {:ok, run} = Repo.insert(changeset)
        assert Repo.reload!(run).brief == ""
      end

      refute Run.changeset(%Run{}, %{
               playbook_name: "flow",
               definition: "x",
               channel_id: ctx.channel.id,
               status: "completed",
               brief: String.duplicate("x", 8_001)
             }).valid?
    end

    test "one run in progress per channel: of two concurrent starts exactly one wins", ctx do
      playbook = roles_playbook()
      _ = {dev(), qa()}

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Runs.start(%{
              playbook: playbook,
              channel: ctx.channel,
              coordinator: ctx.agent,
              started_by_agent_id: ctx.agent.id,
              brief: "race"
            })
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert [{:ok, %Run{}, false}] = Enum.filter(results, &match?({:ok, _, _}, &1))
      assert [{:error, reason}] = Enum.filter(results, &match?({:error, _}, &1))
      assert reason =~ "already has a playbook run in progress"
      assert Repo.aggregate(from(r in Run, where: r.channel_id == ^ctx.channel.id), :count) == 1
    end

    test "a busy channel's refusal ends with the starter's own way to a new channel", ctx do
      playbook = playbook_fixture("busy", [{"a", "A", "coordinator"}])

      start =
        &Runs.start(
          Map.merge(
            %{
              playbook: playbook,
              channel: ctx.channel,
              coordinator: ctx.agent,
              started_by_agent_id: nil,
              brief: "x"
            },
            &1
          )
        )

      {:ok, _run, false} = start.(%{})

      for {via, ending} <- [
            {nil, "or start in a new channel with channel_name"},
            {"by choosing New channel", "or start in a new channel by choosing New channel"},
            {"from the Playbooks page", "or start in a new channel from the Playbooks page"}
          ] do
        assert {:error, reason} = start.(%{new_channel_via: via})
        assert String.ends_with?(reason, ending)
      end
    end

    test "a run the user starts here wakes the coordinator with the first step", ctx do
      stub_engine(self(), ctx.repository)
      {run, false} = start!(ctx, roles_playbook(), %{started_by_agent_id: nil})
      assert run.started_by_agent_id == nil

      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)

      assert text =~
               "You are coordinating the flow playbook in ##{ctx.channel.name} (run #{run.id}). The user started it here."

      assert text =~ "Step 1: Plan (plan), owners you."
    end

    test "a channel_name creates a channel owned by the coordinator and wakes it there", ctx do
      stub_engine(self(), ctx.repository)

      playbook =
        playbook_fixture("fresh", @steps, "roles:\n  dev: #{dev().name}\n  qa: #{qa().name}\n")

      brief = "Login button broken on Safari"
      name = Runs.channel_name(ctx.repository.id, nil, "fresh", brief)
      {run, true} = start!(ctx, playbook, %{brief: brief, channel_name: name})
      assert run.channel_id != ctx.channel.id
      channel = Channels.get!(run.channel_id)
      assert channel.name == "fresh-login-button-broken-on"
      assert channel.owner_agent_id == ctx.agent.id
      assert channel.task.title == "Login button broken on Safari"
      assert Channels.member?(channel, dev()) and Channels.member?(channel, qa())

      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)

      assert text =~
               "You are coordinating the fresh playbook in ##{channel.name} (run #{run.id}). This channel was started for it by @#{ctx.agent.name}."

      assert text =~ "Brief:\nLogin button broken on Safari"
      assert text =~ "Ground rules for the run:\nGround rules for fresh."
      assert text =~ "Instructions for this step:\nDo Plan."
      # the note on every coordinator prompt rides along too
      assert text =~ "Playbook in progress here: fresh (run #{run.id}), step 1 of 4 \"Plan\""

      # a second run of it gets the next free name
      name = Runs.channel_name(ctx.repository.id, nil, "fresh", brief)
      {run2, true} = start!(ctx, playbook, %{brief: brief, channel_name: name})
      assert Channels.get!(run2.channel_id).name == "fresh-login-button-broken-on-2"
      assert_receive {:prompted, _sid, _body}, 2_000
    end

    test "an old channel: new playbook runs where it's started unless given a channel_name",
         ctx do
      playbook = playbook_fixture("legacy", [{"a", "A", "coordinator"}], "channel: new\n")
      {run, false} = start!(ctx, playbook)
      assert run.channel_id == ctx.channel.id
      assert {:ok, _} = Canopy.Playbooks.definition(run)

      {:ok, run, :completed} = Runs.advance(run, {:agent, ctx.agent.id}, result: "done")
      assert run.status == "completed"

      {run, true} = start!(ctx, playbook, %{channel_name: "legacy-elsewhere"})
      assert Channels.get!(run.channel_id).name == "legacy-elsewhere"
    end

    test "no brief: the new channel is named and described from the playbook, and the coordinator is told",
         ctx do
      stub_engine(self(), ctx.repository)
      playbook = playbook_fixture("quiet", [{"a", "A", "coordinator"}])

      name = Runs.channel_name(ctx.repository.id, nil, "quiet", "")
      assert name == "quiet"
      {run, true} = start!(ctx, playbook, %{brief: "", channel_name: name})

      channel = Channels.get!(run.channel_id)
      assert channel.name == "quiet"
      assert channel.topic == "quiet: The quiet process."
      assert channel.task.title == "quiet: The quiet process."

      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)
      refute text =~ "Brief:"
      assert text =~ "No brief was given: the playbook is the context. Start on step 1"

      # taken now: the next one gets -2
      assert Runs.channel_name(ctx.repository.id, nil, "quiet", nil) == "quiet-2"

      # a typed name that cleans to nothing counts as none
      for typed <- ["#", "-", " --- ", "", " # ", "#--", nil],
          do: assert(Runs.channel_name(ctx.repository.id, typed, "quiet", nil) == "quiet-2")
    end

    test "a stand-in channel with no name is no channel at all", ctx do
      playbook = playbook_fixture("stand-in", [{"a", "A", "coordinator"}])

      for name <- [nil, ""] do
        assert {:error, "pick a channel"} =
                 Runs.start(%{
                   playbook: playbook,
                   channel: %Channels.Channel{repository_id: ctx.repository.id},
                   channel_name: name,
                   coordinator: ctx.agent,
                   started_by_agent_id: nil,
                   brief: ""
                 })
      end
    end
  end

  describe "advancing" do
    setup ctx do
      {run, false} = start!(ctx, roles_playbook())
      Map.put(ctx, :run, run)
    end

    test "advance moves to the following step; next jumps; re-entering bumps the round", ctx do
      me = {:agent, ctx.agent.id}
      assert {:ok, run, {:step, "build"}} = Runs.advance(ctx.run, me, result: "planned")
      assert %{status: "done", result: "planned"} = step(run, "plan")
      assert %{status: "active", round: 1} = step(run, "build")

      assert_receive {:timeline,
                      %{
                        event_type: "playbook_step_completed",
                        payload: %{"step" => "plan", "next" => "build"}
                      }}

      assert {:ok, run, {:step, "ship"}} = Runs.advance(run, me, result: "built", next: "ship")
      assert step(run, "check").status == "pending"

      assert {:ok, run, {:step, "build"}} =
               Runs.advance(run, me, result: "broke it", next: "build")

      assert %{status: "active", round: 2} = step(run, "build")
      assert step(run, "ship").status == "done"

      # advancing to the step already current enters it again
      assert {:ok, run, {:step, "build"}} = Runs.advance(run, me, result: "retry", next: "build")
      assert %{status: "active", round: 3, result: "retry"} = step(run, "build")

      assert {:error, reason} = Runs.advance(run, me, result: "x", next: "deploy")
      assert reason =~ "no step deploy"
    end

    test "skipping: optional steps freely, others only with a reason", ctx do
      me = {:agent, ctx.agent.id}
      {:ok, run, _} = Runs.advance(ctx.run, me, result: "planned")

      assert {:error, reason} = Runs.advance(run, me, skip: true)
      assert reason =~ "not optional"

      {:ok, run, {:step, "check"}} =
        Runs.advance(run, me, result: "frontend only, no build", skip: true)

      assert step(run, "build").status == "skipped"
      assert_receive {:timeline, %{event_type: "playbook_step_skipped"}}

      {:ok, run, {:step, "ship"}} = Runs.advance(run, me, skip: true)
      assert step(run, "check").status == "skipped"
    end

    test "completing the last step completes the run", ctx do
      me = {:agent, ctx.agent.id}
      {:ok, run, _} = Runs.advance(ctx.run, me, result: "a", next: "ship")
      assert {:ok, run, :completed} = Runs.advance(run, me, result: "shipped v1")
      assert run.status == "completed"
      assert run.outcome == "shipped v1"
      assert run.finished_at
      assert Runs.active_for_channel(ctx.channel.id) == nil
      assert_receive {:timeline, %{event_type: "playbook_completed"}}
      assert {:error, reason} = Runs.advance(run, me, result: "more")
      assert reason =~ "is completed"
    end

    test "only the coordinator (or the user) advances", ctx do
      assert {:error, reason} = Runs.advance(ctx.run, {:agent, dev().id}, result: "mine now")
      assert reason =~ "only @#{ctx.agent.name} can advance"
      assert {:ok, _run, {:step, "build"}} = Runs.advance(ctx.run, :user, result: "user did it")
    end

    test "cancel: the coordinator, the channel owner, or the user; nobody else", ctx do
      assert {:error, reason} = Runs.cancel(ctx.run, {:agent, dev().id}, "no")
      assert reason =~ "only the coordinator or the channel owner"

      {:ok, run, _} = Runs.reassign(ctx.run, dev(), "user")
      assert run.coordinator_agent_id == dev().id
      assert_receive {:prompted, _sid, _}, 2_000
      # ctx.agent still owns the channel
      assert {:ok, run, :cancelled} = Runs.cancel(run, {:agent, ctx.agent.id}, "not needed")
      assert run.status == "cancelled"
      assert run.outcome == "not needed"

      assert_receive {:timeline,
                      %{event_type: "playbook_cancelled", payload: %{"reason" => "not needed"}}}
    end
  end

  describe "approval gates" do
    setup ctx do
      stub_engine(self(), ctx.repository)

      playbook =
        playbook_fixture(
          "gated",
          [
            {"fix", "Fix", "dev"},
            {"sign-off", "Sign-off", "coordinator", "approval: user"},
            {"wrap", "Wrap up", "coordinator"}
          ],
          "roles:\n  dev: #{dev().name}\n"
        )

      {run, false} = start!(ctx, playbook)
      {:ok, run, {:step, "sign-off"}} = Runs.advance(run, {:agent, ctx.agent.id}, result: "fixed")
      Map.put(ctx, :run, run)
    end

    test "advancing past an approval step holds it for the user", ctx do
      assert {:ok, run, :awaiting_approval} =
               Runs.advance(ctx.run, {:agent, ctx.agent.id}, result: "summary posted")

      assert run.status == "awaiting_approval"
      assert %{status: "awaiting_approval", result: "summary posted"} = step(run, "sign-off")
      assert_receive {:timeline, %{event_type: "playbook_approval_requested"}}

      assert {:error, reason} = Runs.advance(run, {:agent, ctx.agent.id}, result: "again")
      assert reason =~ "waiting for the user's approval"
    end

    test "Approve completes the step, moves on, and wakes the coordinator", ctx do
      {:ok, run, :awaiting_approval} =
        Runs.advance(ctx.run, {:agent, ctx.agent.id}, result: "ok?")

      assert {:ok, run, {:step, "wrap"}} = Runs.approve(run, "looks good")
      assert run.status == "active"
      assert %{status: "done", approved_at: %DateTime{}} = step(run, "sign-off")

      assert_receive {:timeline,
                      %{
                        event_type: "playbook_approval_resolved",
                        payload: %{"approved" => true, "note" => "looks good"}
                      }}

      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)
      assert text =~ "The user approved \"Sign-off\" (sign-off) of gated"
      assert text =~ "Their note: looks good"
      assert text =~ "moved on to step wrap"
    end

    test "Request changes reopens the step and wakes the coordinator with the note", ctx do
      {:ok, run, :awaiting_approval} =
        Runs.advance(ctx.run, {:agent, ctx.agent.id}, result: "ok?")

      assert {:ok, run, :changes_requested} =
               Runs.request_changes(run, "the button is still blue")

      assert run.status == "active"
      assert step(run, "sign-off").status == "active"

      assert_receive {:prompted, _sid, body}, 2_000
      assert prompt_text(body) =~ "Their note: the button is still blue"

      # going back from the gate leaves it pending, never done without approval
      {:ok, run, {:step, "fix"}} =
        Runs.advance(run, {:agent, ctx.agent.id}, result: "back to fix", next: "fix")

      assert step(run, "sign-off").status == "pending"
      assert %{status: "active", round: 2} = step(run, "fix")
    end

    test "approving the last step completes the run", ctx do
      # the user may waive a gate; an agent may not
      {:ok, run, {:step, "wrap"}} = Runs.advance(ctx.run, :user, result: "waived", skip: true)

      {:ok, run, :completed} = Runs.advance(run, {:agent, ctx.agent.id}, result: "wrapped")
      assert run.status == "completed"

      playbook =
        playbook_fixture("gate-last", [{"sign", "Sign", "coordinator", "approval: user"}])

      {run, false} = start!(ctx, playbook)
      {:ok, run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "ok?")
      assert {:ok, run, :completed} = Runs.approve(run)
      assert run.status == "completed"
      assert run.outcome == "ok?"
      assert_receive {:prompted, _sid, body}, 2_000
      assert prompt_text(body) =~ "That was the last step: the run is complete."
    end

    test "approve is only for a run that waits", ctx do
      assert {:error, reason} = Runs.approve(ctx.run)
      assert reason =~ "not waiting for approval"
    end
  end

  describe "sign-off cards" do
    setup ctx do
      stub_engine(self(), ctx.repository)

      playbook =
        playbook_fixture(
          "carded",
          [
            {"fix", "Fix", "dev"},
            {"design", "Design approval", "coordinator", "approval: user\non_reject: fix"},
            {"wrap", "Wrap up", "coordinator"}
          ],
          "roles:\n  dev: #{dev().name}\n"
        )

      {run, false} = start!(ctx, playbook)
      {:ok, run, {:step, "design"}} = Runs.advance(run, {:agent, ctx.agent.id}, result: "fixed")
      Map.put(ctx, :run, run)
    end

    @options [
      %{label: "Totals on top"},
      %{label: "Totals below", description: "Sum last", recommended: true},
      %{label: "Minimal"}
    ]

    defp hold!(ctx, signoff \\ nil) do
      {:ok, run, :awaiting_approval} =
        Runs.advance(ctx.run, {:agent, ctx.agent.id}, result: "three headers", signoff: signoff)

      {run, Signoffs.pending_for_run(run.id)}
    end

    test "holding a step puts up one card with the result, options and docs", ctx do
      {:ok, doc} =
        Canopy.Documents.create(%{
          filename: "mock.md",
          source: {:binary, "x"},
          agent_id: ctx.agent.id
        })

      {run, card} =
        hold!(ctx, %{question: "Which header?", options: @options, document_ids: [doc.id]})

      assert %{
               status: "pending",
               title: "Design approval",
               question: "Which header?",
               summary: "three headers",
               step_id: "design",
               agent_id: agent_id
             } = card

      assert agent_id == ctx.agent.id
      assert card.run_id == run.id
      assert card.playbook_step_id == step(run, "design").id
      assert Enum.map(card.options, & &1["label"]) == ["Totals on top", "Totals below", "Minimal"]
      assert Enum.map(card.documents, & &1.id) == [doc.id]
      assert Signoffs.badge(card) == "carded · step 2 of 3"

      assert_receive {:timeline,
                      %{event_type: "signoff_requested", payload: %{"playbook" => "carded"}}}

      assert_receive {:timeline,
                      %{event_type: "playbook_approval_requested", payload: %{"signoff_id" => id}}}

      assert id == card.id
    end

    test "the default question names the step", ctx do
      {_run, card} = hold!(ctx)
      assert card.question == ~s(Is "Design approval" done?)
      assert card.options == []
    end

    test "invalid options fail the advance and leave the run as it was", ctx do
      assert {:error, reason} =
               Runs.advance(ctx.run, {:agent, ctx.agent.id},
                 result: "x",
                 signoff: %{options: [%{label: "one"}]}
               )

      assert reason =~ "give 2–6 options"
      run = Runs.get!(ctx.run.id)
      assert run.status == "active"
      assert step(run, "design").status == "active"
      assert Signoffs.pending_for_run(run.id) == nil
    end

    test "a long step title is cut to fit the card; the hold never fails on it", ctx do
      long = String.duplicate("very long title ", 10)

      Repo.update_all(
        from(s in Canopy.Playbooks.Step, where: s.id == ^step(ctx.run, "design").id),
        set: [title: long]
      )

      {:ok, _run, :awaiting_approval} =
        Runs.advance(Runs.get!(ctx.run.id), {:agent, ctx.agent.id}, result: "r")

      card = Signoffs.pending_for_run(ctx.run.id)
      assert String.length(card.title) == 80
      assert String.ends_with?(card.title, "…")
      assert String.length(card.question) <= 300
    end

    test "accepting an option: the step is done, the run moves on, the coordinator hears the pick",
         ctx do
      {_run, card} = hold!(ctx, %{options: @options})

      assert {:ok, %{status: "accepted", choice: "Totals below", choice_index: 1}} =
               Signoffs.accept(card, 1, "ship it")

      run = Runs.get!(ctx.run.id)
      assert run.status == "active"
      assert run.current_step == "wrap"
      design = step(run, "design")
      assert %{status: "done", approved_at: %DateTime{}} = design
      assert design.result == "three headers\n\nChosen: Totals below\nSign-off note: ship it"

      assert_receive {:timeline,
                      %{
                        event_type: "signoff_resolved",
                        payload: %{
                          "status" => "accepted",
                          "choice" => "Totals below",
                          "choice_index" => 1,
                          "playbook" => "carded",
                          "step" => "design"
                        }
                      }}

      assert_receive {:timeline,
                      %{
                        event_type: "playbook_approval_resolved",
                        payload: %{"signoff_id" => id, "choice" => "Totals below"}
                      }}

      assert id == card.id

      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)
      assert text =~ ~s(They chose: "Totals below" — Sum last.)
      assert text =~ "Their note: ship it"
    end

    test "approving directly resolves the card; with no card the approval goes ahead", ctx do
      {run, card} = hold!(ctx)
      assert {:ok, run, {:step, "wrap"}} = Runs.approve(run)
      assert %{status: "accepted", resolved_by: "user"} = Signoffs.get(card.id)

      # a held step whose card is gone (none was ever made) still approves
      playbook = playbook_fixture("bare", [{"sign", "Sign", "coordinator", "approval: user"}])
      {:ok, _, :cancelled} = Runs.cancel(run, :user, "next")
      {run2, false} = start!(ctx, playbook)
      {:ok, run2, :awaiting_approval} = Runs.advance(run2, {:agent, ctx.agent.id}, result: "ok")
      Repo.delete_all(from s in SignoffRequest, where: s.run_id == ^run2.id)
      assert {:ok, _run, :completed} = Runs.approve(run2)
    end

    test "a card that is not the step's pending card is refused", ctx do
      {run, card} = hold!(ctx)
      other = %{card | id: "so_00000000000000000000000000"}
      assert {:error, "already answered"} = Runs.approve(run, nil, signoff: other)
      assert {:error, "already answered"} = Runs.request_changes(run, nil, signoff: other)

      assert {:ok, _, _} = Runs.approve(run, nil, signoff: card)
      assert {:error, _} = Runs.approve(Runs.get!(run.id), nil, signoff: card)
    end

    test "a second press on a run card is refused, and the run does not move twice", ctx do
      {_run, card} = hold!(ctx)
      assert {:ok, _} = Signoffs.accept(card.id, nil, nil)
      assert {:error, "already answered"} = Signoffs.accept(card.id, nil, nil)
      assert {:error, "already answered"} = Signoffs.reject(card, "late")
      assert Runs.get!(ctx.run.id).current_step == "wrap"
    end

    test "a stale run leaves the card pending, with a user-facing reason", ctx do
      {_run, card} = hold!(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), inc: [lock_version: 1])
      # the card the context reads is fresh, but a stale run read beforehand loses
      stale_run = Runs.get!(ctx.run.id)
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), inc: [lock_version: 1])

      assert {:error, reason} = Runs.approve(stale_run, nil, signoff: card)
      assert reason =~ "changed meanwhile"
      assert %{status: "pending"} = Signoffs.get(card.id)
    end

    test "rejecting with no note reopens the step and asks the coordinator to find out what changes",
         ctx do
      {_run, card} = hold!(ctx, %{options: @options})
      assert {:ok, %{status: "rejected", note: nil}} = Signoffs.reject(card, nil)

      run = Runs.get!(ctx.run.id)
      assert run.status == "active"
      assert step(run, "design").status == "active"

      assert_receive {:timeline,
                      %{
                        event_type: "playbook_approval_resolved",
                        payload: %{"approved" => false, "rejected_all" => true}
                      }}

      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)
      assert text =~ ~s(The user rejected all options on "Design approval")
      assert text =~ "They gave no note"
      assert text =~ "The playbook sends this step back to fix."
    end

    test "with the reset gate up, a run card's accept commits and returns without a wake", ctx do
      {_run, card} = hold!(ctx)
      stop_channels()
      Canopy.EnvironmentHelpers.raise_gate()

      assert {:ok, %{status: "accepted"}} = Signoffs.accept(card, nil, nil)
      assert Runs.get!(ctx.run.id).current_step == "wrap"
      refute_receive {:prompted, _, _}, 300
    end

    test "accepting the last step completes the run with the signed result as its outcome",
         ctx do
      playbook = playbook_fixture("last", [{"sign", "Sign", "coordinator", "approval: user"}])
      {:ok, _, :cancelled} = Runs.cancel(ctx.run, :user, "next")
      {run, false} = start!(ctx, playbook)

      {:ok, _run, :awaiting_approval} =
        Runs.advance(run, {:agent, ctx.agent.id},
          result: "signed",
          signoff: %{options: [%{label: "A"}, %{label: "B"}]}
        )

      {:ok, _} = Signoffs.accept(Signoffs.pending_for_run(run.id), 0, "fine")

      run = Runs.get!(run.id)
      assert run.status == "completed"
      assert run.outcome == "signed\n\nChosen: A\nSign-off note: fine"
      assert run.outcome == step(run, "sign").result
    end

    test "re-holding after a reject puts up a fresh card", ctx do
      {_run, first} = hold!(ctx)
      {:ok, _} = Signoffs.reject(first, "redo")

      {:ok, run, :awaiting_approval} =
        Runs.advance(Runs.get!(ctx.run.id), {:agent, ctx.agent.id}, result: "again")

      second = Signoffs.pending_for_run(run.id)
      assert second.id != first.id
      assert %{status: "rejected"} = Signoffs.get(first.id)
    end

    test "cancelling the run withdraws its card", ctx do
      {run, card} = hold!(ctx)
      {:ok, _run, :cancelled} = Runs.cancel(run, :user, "not now")

      assert %{status: "withdrawn", resolved_by: "system"} = Signoffs.get(card.id)

      assert_receive {:timeline,
                      %{
                        event_type: "signoff_withdrawn",
                        payload: %{"reason" => "run cancelled", "agent" => name}
                      }}

      assert name == ctx.agent.name
    end

    test "after a reassignment, accepting wakes the new coordinator", ctx do
      {run, card} = hold!(ctx)
      new = agent_fixture(name: "new-coord-" <> unique_suffix())
      new_session = session_fixture(%{channel: ctx.channel, agent_id: new.id})
      {:ok, _run, :reassigned} = Runs.reassign(run, new, "user")

      assert {:ok, _} = Signoffs.accept(card, nil, nil)
      assert_receive {:prompted, sid, body}, 2_000
      assert prompt_text(body) =~ "The user approved"
      assert sid == new_session.engine_session_id
    end

    test "in an archived channel a held run can still be released", ctx do
      {_run, card} = hold!(ctx)
      {:ok, _} = Channels.archive(ctx.channel)
      assert {:ok, %{status: "accepted"}} = Signoffs.accept(card, nil, nil)
      assert Runs.get!(ctx.run.id).current_step == "wrap"
    end
  end

  describe "the coordinator" do
    setup ctx do
      {run, false} = start!(ctx, roles_playbook())
      Map.put(ctx, :run, run)
    end

    test "follows an accepted handoff from the coordinator", ctx do
      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: ctx.channel.id,
          task_id: ctx.task.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: dev().id,
          summary: "yours",
          reason: "yours",
          packet: %{}
        })

      {:ok, _} = Handoffs.accept(handoff)
      run = Runs.get!(ctx.run.id)
      assert run.coordinator_agent_id == dev().id

      assert_receive {:timeline,
                      %{event_type: "playbook_coordinator_changed", payload: %{"by" => "handoff"}}}
    end

    test "a handoff from someone else leaves the coordinator alone", ctx do
      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: ctx.channel.id,
          from_agent_id: dev().id,
          to_agent_id: qa().id,
          summary: "x",
          reason: "x",
          packet: %{}
        })

      {:ok, _} = Handoffs.accept(handoff)
      assert Runs.get!(ctx.run.id).coordinator_agent_id == ctx.agent.id
    end

    test "the prompt note goes to the coordinator only", ctx do
      assert Runs.prompt_note(ctx.channel.id, dev().id) == nil
      note = Runs.prompt_note(ctx.channel.id, ctx.agent.id)
      assert note =~ "Playbook in progress here: flow (run #{ctx.run.id}), step 1 of 4 \"Plan\""
      assert note =~ "you coordinate it"
      assert note =~ "canopy_playbook_advance moves it on"
    end

    test "delegations for the step are counted in the note and touch the run", ctx do
      {:ok, run, _} = Runs.advance(ctx.run, {:agent, ctx.agent.id}, result: "planned")
      build = step(run, "build")

      {:ok, delegation} =
        Delegations.create(%{
          channel_id: ctx.channel.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: dev().id,
          description: "build it",
          playbook_step_id: build.id
        })

      assert Runs.prompt_note(ctx.channel.id, ctx.agent.id) =~
               "Delegations for this step: 0 of 1 done."

      {:ok, _} = Delegations.complete(delegation, "built")

      assert Runs.prompt_note(ctx.channel.id, ctx.agent.id) =~
               "All delegations for this step are done."

      assert [%{id: id}] = Delegations.list_for_step(build.id)
      assert id == delegation.id
    end
  end

  describe "review fixes" do
    defp gated!(ctx, extra_steps \\ []) do
      playbook =
        playbook_fixture(
          "gate-" <> unique_suffix(),
          [
            {"fix", "Fix", "dev"},
            {"sign-off", "Sign-off", "coordinator", "approval: user"},
            {"merge", "Merge", "coordinator"}
          ] ++ extra_steps,
          "roles:\n  dev: #{dev().name}\n"
        )

      {run, false} = start!(ctx, playbook)
      run
    end

    # 1
    test "an agent can neither skip an approval step nor jump past one", ctx do
      me = {:agent, ctx.agent.id}
      run = gated!(ctx)

      # jumping over the gate from before it
      assert {:error, reason} = Runs.advance(run, me, result: "x", next: "merge")
      assert reason =~ "step sign-off (\"Sign-off\") needs the user's approval"

      {:ok, run, {:step, "sign-off"}} = Runs.advance(run, me, result: "fixed")
      assert {:error, reason} = Runs.advance(run, me, result: "no", skip: true)
      assert reason =~ "cannot be skipped"

      # back to fix, then over the gate: refused, the gate is still pending
      {:ok, run, {:step, "fix"}} = Runs.advance(run, me, result: "back", next: "fix")
      assert step(run, "sign-off").status == "pending"
      assert {:error, _} = Runs.advance(run, me, result: "x", next: "merge")

      # the user may
      assert {:ok, _run, {:step, "merge"}} = Runs.advance(run, :user, result: "ok", next: "merge")
    end

    # 1 (going back before an approved gate makes it need approval again)
    test "going back before an approved gate reopens it", ctx do
      me = {:agent, ctx.agent.id}
      run = gated!(ctx)
      {:ok, run, _} = Runs.advance(run, me, result: "fixed")
      {:ok, run, :awaiting_approval} = Runs.advance(run, me, result: "summary")
      {:ok, run, {:step, "merge"}} = Runs.approve(run)
      assert step(run, "sign-off").approved_at
      assert_receive {:prompted, _sid, _}, 2_000

      {:ok, run, {:step, "fix"}} = Runs.advance(run, me, result: "regression", next: "fix")
      assert %{status: "pending", approved_at: nil} = step(run, "sign-off")
      assert {:error, _} = Runs.advance(run, me, result: "x", next: "merge")
    end

    # 2
    test "a next asked for at an approval step is where approval leads", ctx do
      me = {:agent, ctx.agent.id}
      run = gated!(ctx, [{"notes", "Release notes", "coordinator"}])
      {:ok, run, {:step, "sign-off"}} = Runs.advance(run, me, result: "fixed")

      {:ok, run, :awaiting_approval} =
        Runs.advance(run, me, result: "summary", next: "notes")

      assert step(run, "sign-off").approval_next == "notes"
      assert {:ok, run, {:step, "notes"}} = Runs.approve(run)
      assert_receive {:prompted, _sid, _}, 2_000
      assert step(run, "merge").status == "pending"
      assert step(run, "sign-off").approval_next == nil
    end

    # 3
    test "a transition based on a run that changed meanwhile fails, and says so", ctx do
      me = {:agent, ctx.agent.id}
      run = gated!(ctx)

      # two advances from the same read: the second is refused
      assert {:ok, _moved, {:step, "sign-off"}} = Runs.advance(run, me, result: "first")
      assert {:error, reason} = Runs.advance(run, me, result: "second", next: "fix")
      assert reason =~ "changed meanwhile"
      assert Runs.get!(run.id).current_step == "sign-off"

      # a reassignment in between is not ignored
      fresh = Runs.get!(run.id)
      {:ok, _, :reassigned} = Runs.reassign(fresh, dev(), "user")
      assert_receive {:prompted, _sid, _}, 2_000
      assert {:error, reason} = Runs.advance(fresh, me, result: "stale")
      assert reason =~ "coordinated by @#{dev().name}"
      assert {:error, _} = Runs.cancel(fresh, :user, "stale")
      assert Runs.get!(run.id).status == "active"
    end

    # 4
    test "a failed start in a new channel leaves no channel behind", ctx do
      playbook =
        playbook_fixture("orphan", [{"a", "A", "coordinator"}])

      channels = length(Channels.list())

      assert {:error, reason} =
               Runs.start(%{
                 playbook: playbook,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 started_by_agent_id: ctx.agent.id,
                 brief: String.duplicate("x", 8_001),
                 channel_name: "orphan"
               })

      assert reason =~ "too long"

      # the run insert itself fails (an invalid channel name): the channel goes too
      assert {:error, _} =
               Runs.start(%{
                 playbook: playbook,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 started_by_agent_id: ctx.agent.id,
                 brief: "ok",
                 channel_name: "Not A Valid Name!"
               })

      assert length(Channels.list()) == channels
    end

    # 4 (delete versus start)
    test "a start re-checks the playbook inside its transaction", ctx do
      playbook = playbook_fixture("vanishing", [{"a", "A", "coordinator"}])
      {:ok, _} = Canopy.Playbooks.delete(playbook)

      assert {:error, reason} =
               Runs.start(%{
                 playbook: playbook,
                 channel: ctx.channel,
                 coordinator: ctx.agent,
                 started_by_agent_id: ctx.agent.id,
                 brief: "go"
               })

      assert reason =~ "no longer exists"
      assert Runs.active_for_channel(ctx.channel.id) == nil
    end

    # 6
    test "the prompt note survives no run and a coordinator that changed", ctx do
      assert Runs.prompt_note(ctx.channel.id, ctx.agent.id) == nil
      run = gated!(ctx)
      assert Runs.prompt_note(ctx.channel.id, ctx.agent.id) =~ "you coordinate it"
      {:ok, _, :reassigned} = Runs.reassign(run, dev(), "user")
      assert_receive {:prompted, _sid, _}, 2_000
      assert Runs.prompt_note(ctx.channel.id, ctx.agent.id) == nil
      assert Runs.prompt_note(ctx.channel.id, dev().id) =~ "you coordinate it"
    end

    # 7
    test "a handoff to an agent that cannot coordinate keeps the run and says so", ctx do
      run = gated!(ctx)

      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: ctx.channel.id,
          from_agent_id: ctx.agent.id,
          to_agent_id: qa().id,
          summary: "x",
          reason: "x",
          packet: %{}
        })

      {:ok, _} = Canopy.Agents.deactivate(qa())
      {:ok, _} = Handoffs.accept(Handoffs.get!(handoff.id))

      assert Runs.get!(run.id).coordinator_agent_id == ctx.agent.id
      assert_receive {:timeline, %{event_type: "playbook_coordinator_kept", payload: payload}}
      assert payload["reason"] =~ "deactivated"
    end

    # 8
    test "a user's reassignment wakes the new coordinator with the current step", ctx do
      run = gated!(ctx)
      {:ok, _, :reassigned} = Runs.reassign(run, dev(), "user")
      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)
      assert text =~ "The user made you the coordinator of the #{run.playbook_name} playbook"
      assert text =~ "step 1 of 3: Fix (fix), owners @#{dev().name}"
      assert text =~ "Instructions for this step:\nDo Fix."
    end

    test "a reassigned coordinator of a run with no brief is told the playbook is the context",
         ctx do
      run = gated!(ctx)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [brief: ""])
      {:ok, _, :reassigned} = Runs.reassign(Runs.get!(run.id), dev(), "user")
      assert_receive {:prompted, _sid, body}, 2_000
      text = prompt_text(body)
      refute text =~ "Brief:"
      assert text =~ "No brief was given: the playbook is the context."
    end

    # 9
    test "a DM never gains a coordinator or roster member", ctx do
      outsider = agent_fixture(name: "outsider-" <> unique_suffix())
      {:ok, dm} = Channels.ensure_dm(ctx.repository.id, [ctx.agent])
      playbook = playbook_fixture("solo", [{"a", "A", "coordinator"}])

      assert {:error, reason} =
               Runs.start(%{
                 playbook: playbook,
                 channel: dm,
                 coordinator: outsider,
                 started_by_agent_id: outsider.id,
                 brief: "x"
               })

      # an agent opens a new channel with channel_name
      assert reason ==
               "a DM keeps its agents and this run needs others (the coordinator or the roster); " <>
                 "start it in a channel, or in a new one with channel_name"

      refute Channels.member?(dm, outsider)

      {:ok, run, false} =
        Runs.start(%{
          playbook: playbook,
          channel: dm,
          coordinator: ctx.agent,
          started_by_agent_id: ctx.agent.id,
          brief: "x"
        })

      assert {:error, reason} = Runs.reassign(run, outsider, "user")
      assert reason =~ "a DM keeps its agents"
      refute Channels.member?(dm, outsider)
    end

    # 10
    test "a watch-started run does not reset the chatter budget", ctx do
      {:ok, _} = Canopy.Settings.update(%{chatter_limit: 1})
      {:ok, _pid} = Canopy.Runtime.ensure_channel(ctx.channel.id, start_stream: false)
      {:ok, _} = Canopy.Runtime.post_user_message(ctx.channel.id, "hello")
      assert_receive {:prompted, sid, _}, 2_000

      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        Canopy.OpenCode.EventStream.session_topic(sid),
        {:engine_event,
         %Canopy.Engine.Event{type: :agent_completed, session_id: sid, data: %{}, raw_type: "t"}}
      )

      assert_receive {:timeline, %{event_type: "agent_turn_completed"}}, 2_000
      playbook = playbook_fixture("watched", [{"a", "A", "coordinator"}])

      {:ok, _run, false} =
        Runs.start(%{
          playbook: playbook,
          channel: ctx.channel,
          coordinator: ctx.agent,
          brief: "from a watch",
          trigger: %{"schedule_id" => "sch_x", "key" => "pr:1"}
        })

      _ = :sys.get_state(Canopy.Runtime.Supervisor.whereis(ctx.channel.id))
      refute_receive {:prompted, _, _}, 200
      assert Canopy.Runtime.paused?(ctx.channel.id)
    end

    # 11
    test "the default coordinator is never a deactivated agent", ctx do
      gone = agent_fixture(name: "gone-" <> unique_suffix())
      {:ok, _} = Canopy.Agents.deactivate(gone)

      playbook =
        playbook_fixture("named", [{"a", "A", "coordinator"}], "coordinator: #{gone.name}\n")

      assert Runs.default_coordinator(playbook, ctx.channel).id == ctx.agent.id

      {:ok, {:playbook, run}} =
        Canopy.Runtime.post_user_message(ctx.channel.id, "/playbook named go")

      assert run.coordinator_agent_id == ctx.agent.id
    end

    # 24
    test "a nudge is claimed once; one for a run that moved on is not sent", ctx do
      run = gated!(ctx)
      old = DateTime.add(DateTime.utc_now(), -3600, :second)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [last_activity_at: old])
      stalled = Runs.get!(run.id)

      # two checks of the same quiet run: one nudge
      assert {:nudged, _} = Runs.check_stall(stalled)
      assert :skip = Runs.check_stall(stalled)
      assert_receive {:prompted, _sid, _}, 2_000
      refute_receive {:prompted, _, _}, 200

      events = Canopy.Timeline.list(ctx.channel.id, types: ["playbook_stalled"])
      assert length(events) == 1

      # a stale check (the run moved on after it was read) claims nothing
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [nudged_at: nil])
      stale = Runs.get!(run.id)
      {:ok, _, _} = Runs.advance(stale, {:agent, ctx.agent.id}, result: "moved")
      assert :skip = Runs.check_stall(%{stale | last_activity_at: old})

      # a waiting nudge for a step the run left is dropped
      refute Runs.nudge_current?({run.id, "fix", 1})
      assert Runs.nudge_current?({run.id, "sign-off", 1})
    end
  end

  describe "what the start page shows comes from here" do
    test "roster_preview/1 fills each role the way a start does", ctx do
      labelled = agent_fixture(name: "labelled-" <> unique_suffix())
      named = agent_fixture(name: "fixer")
      default = agent_fixture(name: "default-" <> unique_suffix())
      team = team_fixture([labelled, named], %{name: "crew-" <> unique_suffix()})

      Repo.update_all(
        from(m in Teams.TeamMember, where: m.team_id == ^team.id and m.agent_id == ^labelled.id),
        set: [role: "tester"]
      )

      playbook =
        playbook_fixture(
          "previewed",
          [{"test", "Test", "tester"}, {"fix", "Fix", "fixer"}, {"docs", "Docs", "writer"}],
          "team: #{team.name}\nroles:\n  writer: #{default.name}\n  tester: #{default.name}\n"
        )

      {:ok, definition} = Canopy.Playbooks.definition(playbook)
      preview = Runs.roster_preview(definition)

      assert [
               %{role: "tester", source: "from @" <> _},
               %{role: "fixer", source: "from @" <> _},
               %{role: "writer", source: "playbook default"}
             ] = preview

      {run, false} = start!(ctx, playbook)
      assert run.roster == Map.new(preview, &{&1.role, &1.agent.id})
    end

    test "roster_preview/1 says who isn't available and what nobody fills" do
      gone = agent_fixture(name: "gone-" <> unique_suffix())
      {:ok, _} = Canopy.Agents.deactivate(gone)

      playbook =
        playbook_fixture(
          "unfillable",
          [{"a", "A", "dev"}, {"b", "B", "ops"}],
          "roles:\n  dev: #{gone.name}\n  ops: nobody-here\n"
        )

      {:ok, definition} = Canopy.Playbooks.definition(playbook)

      assert [
               %{role: "dev", agent: nil, source: "@" <> dev_source},
               %{role: "ops", agent: nil, source: "@nobody-here isn't available"}
             ] = Runs.roster_preview(definition)

      assert dev_source == "#{gone.name} isn't available"
      assert {:error, _} = Runs.resolve_roster(definition, nil)
    end

    test "channel_name/4 is the name a new run's channel gets", ctx do
      playbook = playbook_fixture("named-run", [{"a", "A", "coordinator"}])
      repo_id = ctx.repository.id

      assert Runs.channel_name(nil, nil, "named-run", "Fix the Login, page now!") ==
               "named-run-fix-the-login-page"

      assert Runs.channel_name(repo_id, " #Launch-Day ", "named-run", "x") == "launch-day"

      expected = Runs.channel_name(repo_id, nil, playbook.name, "Fix the login")
      assert expected == "named-run-fix-the-login"
      {run, true} = start!(ctx, playbook, %{brief: "Fix the login", channel_name: expected})
      assert Channels.get!(run.channel_id).name == expected

      # taken now: the next one gets -2
      assert Runs.channel_name(repo_id, nil, playbook.name, "Fix the login") == expected <> "-2"

      # no brief: the playbook's name alone
      assert Runs.channel_name(nil, nil, "named-run", "") == "named-run"
      assert Runs.channel_name(nil, nil, "named-run", nil) == "named-run"
    end
  end

  defp step(run, id), do: Enum.find(run.steps, &(&1.step_id == id))
end
