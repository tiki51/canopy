defmodule CanopyWeb.ChannelLocksLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Locks, QuestionRequests, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    fullstack = Fixtures.agent_fixture(%{name: "fullstack" <> Fixtures.unique_suffix()})
    scenario = Fixtures.scenario(members: [fullstack])

    fullstack_session =
      Fixtures.session_fixture(%{channel: scenario.channel, agent_id: fullstack.id})

    # a second channel on the same repository, where the owner also works
    other =
      Fixtures.channel_fixture(%{
        repository_id: scenario.repository.id,
        owner_agent_id: scenario.agent.id
      })

    other_session = Fixtures.session_fixture(%{channel: other, agent_id: scenario.agent.id})

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    on_exit(fn ->
      Runtime.stop_channel(scenario.channel.id)
      Runtime.stop_channel(other.id)
    end)

    Map.merge(scenario, %{
      fullstack: fullstack,
      fullstack_session: fullstack_session,
      other: other,
      other_session: other_session
    })
  end

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  # the grant wake a release sends is handled before the test's stubs go
  defp settle(channel), do: :sys.get_state(Runtime.Supervisor.whereis(channel.id))

  test "with no locks the header offers the Locks panel, which says so", ctx do
    {:ok, view, _html} = open(ctx.conn, ctx.channel)

    refute has_element?(view, "[id^='lock-chip-']")
    view |> element("#edit-locks") |> render_click()
    assert has_element?(view, "#locks-panel #locks-empty")
  end

  test "a lock taken in another channel on the repository shows up live as a chip", ctx do
    {:ok, view, _html} = open(ctx.conn, ctx.channel)

    {:granted, _} =
      Locks.acquire(ctx.other_session, ctx.repository.id, "tests", "site-shots re-shoot")

    {:queued, _, 1, _} =
      Locks.acquire(ctx.fullstack_session, ctx.repository.id, "tests", "precommit")

    chip = element(view, "#lock-chip-tests")
    assert render(chip) =~ "@#{ctx.agent.name}"
    assert render(chip) =~ "next: @#{ctx.fullstack.name}"
    refute has_element?(view, "#edit-locks")

    # the agent chips: a lock on the holder, a queued mark on the waiter
    assert has_element?(view, "#member-#{ctx.agent.id}-lock")
    assert has_element?(view, "#member-#{ctx.fullstack.id}-lock-queued")

    render_click(chip)
    holder = view |> element("#lock-tests-holder") |> render()
    assert holder =~ "@#{ctx.agent.name}"
    assert holder =~ "in ##{ctx.other.name}"
    assert view |> element("#lock-tests") |> render() =~ "site-shots re-shoot"
    assert view |> element("#lock-tests-queue") |> render() =~ "precommit"
  end

  test "a holder blocked on a card is marked as waiting on the user", ctx do
    {:granted, _} = Locks.acquire(ctx.session, ctx.repository.id, "tests", nil)
    {:ok, view, _html} = open(ctx.conn, ctx.channel)
    refute has_element?(view, "#lock-chip-tests-awaiting")

    {:ok, _} =
      QuestionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.session.id,
        opencode_question_id: "que_" <> Fixtures.unique_suffix(),
        questions: [%{"question" => "Which port?", "options" => []}],
        status: "pending"
      })

    # what the channel server does when the turn starts waiting on the card
    Locks.touch(ctx.repository.id, ctx.session.id)

    assert has_element?(view, "#lock-chip-tests-awaiting")
    view |> element("#lock-chip-tests") |> render_click()
    assert has_element?(view, "#lock-tests-awaiting", "waiting on you")
  end

  test "Force release passes the lock to the next in line, then frees it", ctx do
    {:granted, _} = Locks.acquire(ctx.session, ctx.repository.id, "tests", nil)
    {:queued, _, 1, _} = Locks.acquire(ctx.fullstack_session, ctx.repository.id, "tests", nil)
    {:ok, view, _html} = open(ctx.conn, ctx.channel)

    view |> element("#lock-chip-tests") |> render_click()
    html = view |> element("#force-release-tests") |> render_click()
    assert html =~ "@#{ctx.fullstack.name} has it now"
    assert Locks.get(ctx.repository.id, "tests").holder.session_id == ctx.fullstack_session.id
    assert view |> element("#lock-tests-holder") |> render() =~ "@#{ctx.fullstack.name}"

    html = view |> element("#force-release-tests") |> render_click()
    assert html =~ "nobody was waiting"
    assert Locks.list(ctx.repository.id) == []
    assert has_element?(view, "#locks-empty")
    assert has_element?(view, "#edit-locks")
    settle(ctx.channel)
  end

  test "the user takes a lock by hand and releases it", ctx do
    {:ok, view, _html} = open(ctx.conn, ctx.channel)
    view |> element("#edit-locks") |> render_click()

    html =
      view
      |> form("#take-lock-form", lock: %{name: "tests", reason: "testing by hand"})
      |> render_submit()

    assert html =~ "You hold `tests`"
    assert render(element(view, "#lock-chip-tests")) =~ ctx.user.display_name

    # an agent asking now waits behind the user
    assert {:queued, _, 1, holder} = Locks.acquire(ctx.session, ctx.repository.id, "tests", nil)
    assert holder.user_id == ctx.user.id

    # taken already: says who has it
    html = view |> form("#take-lock-form", lock: %{name: "tests"}) |> render_submit()
    assert html =~ "You already hold `tests`"

    view |> element("#force-release-tests", "Release") |> render_click()
    assert Locks.get(ctx.repository.id, "tests").holder.session_id == ctx.session.id
    settle(ctx.channel)
  end

  test "taking a lock someone holds says who, and a bad name is refused", ctx do
    {:granted, _} = Locks.acquire(ctx.session, ctx.repository.id, "tests", nil)
    {:ok, view, _html} = open(ctx.conn, ctx.channel)
    view |> element("#lock-chip-tests") |> render_click()

    html = view |> form("#take-lock-form", lock: %{name: "tests"}) |> render_submit()
    assert html =~ "is held by @#{ctx.agent.name}"

    html = view |> form("#take-lock-form", lock: %{name: "two words"}) |> render_submit()
    assert html =~ "lock name"
  end

  test "lock events appear in the feed", ctx do
    {:ok, view, _html} = open(ctx.conn, ctx.channel)
    {:granted, _} = Locks.acquire(ctx.session, ctx.repository.id, "tests", nil)

    {:queued, _, 1, _} =
      Locks.acquire(ctx.fullstack_session, ctx.repository.id, "tests", "precommit")

    assert render(view) =~
             "@#{ctx.fullstack.name} is waiting for the `tests` lock held by @#{ctx.agent.name}"
  end
end
