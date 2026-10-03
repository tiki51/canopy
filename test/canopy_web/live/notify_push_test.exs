defmodule CanopyWeb.NotifyPushTest do
  @moduledoc """
  Desktop notification notes reach every page: `CanopyWeb.Nav` pushes
  `"canopy:notify"` for cards, mentions and quiet channels, whatever page is
  open, and the browser decides whether to show them (assets/js/notify.js,
  covered by e2e/tests/notifications.spec.ts).
  """

  use CanopyWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Channels, Fixtures, Messages, QuestionRequests, Reactions, Runtime, Tasks}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :agents, fn _dir, _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    scenario = Fixtures.scenario()
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    scenario
  end

  defp record_question(ctx) do
    {:ok, request} =
      QuestionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.session.id,
        opencode_question_id: "que_" <> Fixtures.unique_suffix(),
        questions: [%{"header" => "Retry key", "question" => "Which key?", "options" => []}],
        status: "pending"
      })

    request
  end

  test "a question card anywhere is pushed to a page that shows no channel, and the badge follows",
       ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings")
    request = record_question(ctx)

    assert_push_event(view, "canopy:notify", %{
      kind: "needs_you",
      tag: "card:" <> rid,
      channel_id: channel_id,
      body: "Retry key",
      url: url
    })

    assert rid == request.id
    assert channel_id == ctx.channel.id
    assert url == "/channels/#{ctx.channel.id}#question-#{request.id}"
    assert has_element?(view, "#attention-#{ctx.channel.id}[data-attention='1']")
    assert has_element?(view, "#canopy-notifier[data-attention='1']")

    {:ok, _} = QuestionRequests.resolve(request, :rejected)
    refute_push_event(view, "canopy:notify", %{})
    refute has_element?(view, "#attention-#{ctx.channel.id}")
    assert has_element?(view, "#canopy-notifier[data-attention='0']")
  end

  test "a view on another channel gets the note too; the browser decides", ctx do
    other =
      Fixtures.channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: ctx.agent.id})

    {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{other.id}")
    assert has_element?(view, "#canopy-notifier[data-channel-id='#{other.id}']")

    record_question(ctx)
    assert_push_event(view, "canopy:notify", %{kind: "needs_you", channel_id: channel_id})
    assert channel_id == ctx.channel.id
  end

  test "an agent mentioning the user is pushed with a link to the message; their own message is not",
       ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings")

    {:ok, message} =
      Messages.post_agent_message(
        ctx.channel.id,
        ctx.agent.id,
        "@#{ctx.user.display_name}, the **build** is green"
      )

    assert_push_event(view, "canopy:notify", %{kind: "mention", body: body, url: url, tag: tag})
    assert body == "@#{ctx.user.display_name}, the build is green"
    assert url == "/channels/#{ctx.channel.id}?msg=#{message.id}"
    assert tag == "mention:#{ctx.channel.id}"

    {:ok, _} =
      Messages.post_user_message(ctx.channel.id, ctx.user.id, "@#{ctx.user.display_name} note")

    {:ok, _} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "no mention here")
    refute_push_event(view, "canopy:notify", %{})
  end

  test "a reaction never notifies", ctx do
    {:ok, message} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "ship it?")
    {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

    {:ok, :added} = Reactions.add(message.id, {:agent, ctx.agent.id}, "check")
    refute_push_event(view, "canopy:notify", %{})
  end

  test "a channel going quiet is pushed as work finished, with the agents' names", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/agents")

    Runtime.broadcast_activity(
      {:channel_quiet, ctx.channel.id,
       %{
         run_id: "run_1",
         agent_ids: [ctx.agent.id],
         turns: 2,
         errors: 0,
         duration_ms: 75_000,
         paused?: false,
         trigger: "user"
       }}
    )

    assert_push_event(view, "canopy:notify", %{kind: "work", title: title, body: body})
    assert title == "##{ctx.channel.name} is done"
    assert body == "@#{ctx.agent.name} · 2 turns · 1 m"

    # agents talking among themselves: not news
    Runtime.broadcast_activity(
      {:channel_quiet, ctx.channel.id,
       %{
         run_id: "run_2",
         agent_ids: [ctx.agent.id],
         turns: 1,
         errors: 0,
         duration_ms: 1_000,
         paused?: false,
         trigger: "agent"
       }}
    )

    refute_push_event(view, "canopy:notify", %{})
  end

  test "a task completed is pushed as work finished", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings")
    {:ok, _} = Tasks.update(ctx.task, %{status: "completed"})
    assert_push_event(view, "canopy:notify", %{kind: "work", body: "Task completed: " <> _})
  end

  test "nothing is pushed for an archived channel", ctx do
    {:ok, _} = Channels.archive(ctx.channel)
    {:ok, view, _html} = live(ctx.conn, ~p"/settings")
    record_question(ctx)
    refute_push_event(view, "canopy:notify", %{})
  end

  test "a page that connects hears of the cards still waiting from the last half hour", ctx do
    waiting = record_question(ctx)
    answered = record_question(ctx)
    {:ok, _} = QuestionRequests.resolve(answered, :rejected)
    old = record_question(ctx)

    Canopy.Repo.update_all(
      from(e in Canopy.Timeline.Event, where: e.ref_id == ^old.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :minute)]
    )

    {:ok, view, _html} = live(ctx.conn, ~p"/agents")
    assert_push_event(view, "canopy:pending", %{notes: notes})
    assert Enum.map(notes, & &1.id) == ["card:" <> waiting.id]
    assert [%{kind: "needs_you", url: "/channels/" <> _}] = notes
  end

  test "nothing to catch up on: no push", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/agents")
    refute_push_event(view, "canopy:pending", %{})
  end

  test "Settings → Notifications: one master switch, the kinds below it disabled until on",
       ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings")

    assert has_element?(view, "#notifications-panel #notify-prefs[phx-update='ignore']")
    assert has_element?(view, "#notify-enabled[role='switch']")
    assert has_element?(view, "#notify-kinds[disabled]")

    for pref <- ~w(needs_you mention work sound),
        do: assert(has_element?(view, "#notify-kinds input[data-notify-pref='#{pref}']"))

    assert has_element?(view, "#notify-test[disabled]")
  end

  test "flipping the switch from the command palette is confirmed with a flash", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/agents")

    view |> element("#cmdk") |> render_hook("cmdk:notify", %{"on" => false})
    assert render(view) =~ "Desktop notifications are off in this browser."

    view |> element("#cmdk") |> render_hook("cmdk:notify", %{"on" => true})
    assert render(view) =~ "Desktop notifications are on in this browser."
  end
end
