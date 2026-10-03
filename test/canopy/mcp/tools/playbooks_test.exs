defmodule Canopy.MCP.Tools.PlaybooksTest do
  use Canopy.DataCase, async: false
  use Oban.Testing, repo: Canopy.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  import Mox
  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Canopy.PlaybookHelpers

  alias Canopy.{Delegations, Playbooks}
  alias Canopy.MCP.Server
  alias Canopy.Playbooks.Runs

  alias Canopy.MCP.Tools.{
    DelegateTask,
    PlaybookAdvance,
    PlaybookCancel,
    PlaybookGet,
    PlaybookSave,
    PlaybookStart,
    PlaybooksList
  }

  setup :set_mox_global

  setup do
    dev = agent_fixture(name: "dev-" <> unique_suffix())
    ctx = scenario(members: [dev])
    # after the repository fixture's own on_exit, so channel servers stop first
    on_exit(&stop_channels/0)
    dev_session = session_fixture(%{channel: ctx.channel, agent_id: dev.id})

    playbook =
      playbook_fixture(
        "ship-it",
        [
          {"plan", "Plan", "coordinator"},
          {"build", "Build", "dev"},
          {"sign-off", "Sign-off", "coordinator", "approval: user"}
        ],
        "roles:\n  dev: #{dev.name}\ninputs: What to ship.\n"
      )

    Map.merge(ctx, %{dev: dev, dev_session: dev_session, playbook: playbook})
  end

  test "the tools are registered" do
    for name <-
          ~w(playbooks_list playbook_get playbook_start playbook_advance playbook_cancel playbook_save watch_create) do
      assert name in Server.tool_names()
    end
  end

  test "list and get by name", ctx do
    {:ok, disabled} =
      Playbooks.create(%{
        body: playbook_text("hidden-one", [{"a", "A", "coordinator"}]),
        enabled: false
      })

    assert {:ok, text} = call(PlaybooksList, %{}, ctx)
    assert text =~ "- ship-it — The ship-it process."
    assert text =~ "roles: dev"
    assert text =~ "steps: Plan → Build → Sign-off"
    refute text =~ disabled.name

    assert {:ok, text} = call(PlaybookGet, %{name: "ship-it"}, ctx)
    assert text =~ "Playbook ship-it:"
    assert text =~ "## build"

    assert {:ok, text} = call(PlaybookGet, %{name: "hidden-one"}, ctx)
    assert text =~ "disabled"

    assert {:error, reason} = call(PlaybookGet, %{}, ctx)
    assert reason =~ "no playbook run is in progress"
  end

  test "start: the caller (by its session) coordinates; the first step comes back", ctx do
    assert {:ok, text} = call(PlaybookStart, %{name: "ship-it", brief: "v2 of the thing"}, ctx)
    assert text =~ "started ship-it ["
    assert text =~ "you coordinate it"
    assert text =~ "step 1/3 plan \"Plan\""
    assert text =~ "Instructions for plan:\nDo Plan."

    run = Runs.active_for_channel(ctx.channel.id)
    assert run.coordinator_agent_id == ctx.agent.id
    assert run.started_by_agent_id == ctx.agent.id

    # get defaults to the run in progress here
    assert {:ok, text} = call(PlaybookGet, %{}, ctx)
    assert text =~ "ship-it run [#{run.id}] in ##{ctx.channel.name}: active"
    assert text =~ "Roster: dev=@#{ctx.dev.name}"
    assert text =~ "1. plan \"Plan\" — active"
    assert text =~ "3. sign-off \"Sign-off\" — pending [approval]"

    assert {:ok, list} = call(PlaybooksList, %{}, ctx)
    assert list =~ "In progress in ##{ctx.channel.name}: ship-it [#{run.id}]"

    assert {:error, reason} = call(PlaybookStart, %{name: "ship-it", brief: "again"}, ctx)
    assert reason =~ "already has a playbook run in progress"

    assert {:error, reason} = call(PlaybookStart, %{name: "nope", brief: "x"}, ctx)
    assert reason =~ "no playbook named"
  end

  test "advance: only the coordinator; the next step and its instructions come back", ctx do
    {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)

    assert {:error, reason} = call(PlaybookAdvance, %{result: "I did it"}, ctx.dev_session)
    assert reason =~ "only @#{ctx.agent.name} can advance"

    assert {:ok, text} = call(PlaybookAdvance, %{result: "planned: three files"}, ctx)
    assert text =~ "moved on. Now: step 2/3 build \"Build\", round 1, owners @#{ctx.dev.name}"
    assert text =~ "Instructions for build:\nDo Build."

    # a delegation now is made for the current step, and the delegate is told so
    assert {:ok, text} =
             call(DelegateTask, %{to: "@" <> ctx.dev.name, task: "build the three files"}, ctx)

    assert text =~ "requested for step `build`"
    run = Runs.active_for_channel(ctx.channel.id)
    build = Enum.find(run.steps, &(&1.step_id == "build"))
    assert [delegation] = Delegations.list_for_step(build.id)

    event = Canopy.Timeline.list(ctx.channel.id, types: ["delegation_created"]) |> List.last()

    assert event.payload["playbook"] == %{
             "step" => "build",
             "playbook" => "ship-it",
             "run_id" => run.id
           }

    assert Canopy.Runtime.Prompts.delegation(%{
             channel: "c",
             from: "@x",
             delegation_id: delegation.id,
             task: "t",
             playbook: event.payload["playbook"]
           }) =~ "This is step `build` of the ship-it playbook (run #{run.id})."

    # "none" makes a plain delegation
    assert {:ok, text} =
             call(DelegateTask, %{to: "@" <> ctx.dev.name, task: "unrelated", step: "none"}, ctx)

    refute text =~ "for step"

    assert {:ok, text} = call(PlaybookAdvance, %{result: "built"}, ctx)
    assert text =~ "step 3/3 sign-off"

    assert {:ok, text} = call(PlaybookAdvance, %{result: "summary posted"}, ctx)
    assert text =~ "is waiting for the user's approval"
    assert text =~ "end your turn"

    assert {:error, reason} = call(PlaybookAdvance, %{result: "again"}, ctx)
    assert reason =~ "waiting for the user's approval"
  end

  test "advance with next and skip", ctx do
    {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)

    assert {:ok, text} =
             call(PlaybookAdvance, %{result: "skip planning", skip: true, next: "build"}, ctx)

    assert text =~ "step 2/3 build"
    run = Runs.active_for_channel(ctx.channel.id)
    assert Enum.find(run.steps, &(&1.step_id == "plan")).status == "skipped"

    assert {:error, reason} = call(PlaybookAdvance, %{result: "x", next: "deploy"}, ctx)
    assert reason =~ "no step deploy"
  end

  test "cancel: the coordinator or the channel owner, not a step owner", ctx do
    {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)

    assert {:error, reason} = call(PlaybookCancel, %{reason: "mine"}, ctx.dev_session)
    assert reason =~ "only the coordinator or the channel owner"

    assert {:ok, text} = call(PlaybookCancel, %{reason: "not now"}, ctx)
    assert text =~ "cancelled ship-it"
    assert Runs.active_for_channel(ctx.channel.id) == nil
  end

  test "a run in a new channel wakes the coordinator there", ctx do
    stub_engine(self(), ctx.repository)

    assert {:ok, text} =
             call(PlaybookStart, %{name: "ship-it", brief: "v3", channel_name: "ship-v3"}, ctx)

    assert text =~ "in the new channel #ship-v3"
    assert_receive {:prompted, _sid, body}, 2_000
    assert prompt_text(body) =~ "You are coordinating the ship-it playbook in #ship-v3"
  end

  test "identity comes from the session: a Claude Code token works the same", ctx do
    assert {:ok, text} =
             call_as_session(PlaybookStart, %{"name" => "ship-it", "brief" => "v4"}, ctx.session)

    assert text =~ "you coordinate it"
    assert Runs.active_for_channel(ctx.channel.id).coordinator_agent_id == ctx.agent.id
  end

  test "save: an agent's draft is disabled until the user enables it", ctx do
    text = playbook_text("from-agent", [{"a", "A", "coordinator"}])
    assert {:ok, reply} = call(PlaybookSave, %{text: text}, ctx)
    assert reply =~ "saved from-agent as a disabled draft"
    draft = Playbooks.get_by_name("from-agent")
    refute draft.enabled
    assert draft.created_by_agent_id == ctx.agent.id

    assert {:error, reason} = call(PlaybookStart, %{name: "from-agent", brief: "x"}, ctx)
    assert reason =~ "disabled"

    assert {:error, reason} = call(PlaybookSave, %{text: "nonsense"}, ctx)
    assert reason =~ "does not parse"

    assert {:error, reason} =
             call(PlaybookSave, %{text: Playbooks.get_by_name("ship-it").body}, ctx)

    assert reason =~ "already exists"
  end

  # 5
  test "a run in a channel the caller is not in is unknown to it, by id too", ctx do
    {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)
    run = Runs.active_for_channel(ctx.channel.id)

    # an agent of the same repository, in another channel only
    stranger = agent_fixture(name: "stranger-" <> unique_suffix())

    elsewhere =
      channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: stranger.id})

    session = session_fixture(%{channel: elsewhere, agent_id: stranger.id})

    assert {:error, "unknown playbook run " <> _} = call(PlaybookGet, %{run: run.id}, session)

    assert {:error, "unknown playbook run " <> _} =
             call(PlaybookCancel, %{run: run.id, reason: "x"}, session)

    # a member reads it by id from anywhere
    assert {:ok, text} = call(PlaybookGet, %{run: run.id}, ctx.dev_session)
    assert text =~ run.id
  end
end
