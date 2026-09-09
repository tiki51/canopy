defmodule CanopyWeb.ChannelLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import CanopyWeb.LiveHelpers

  alias Canopy.{Fixtures, Handoffs, Messages, PermissionRequests, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "database#{Fixtures.unique_suffix()}"})
    scenario = Fixtures.scenario(members: [reviewer])

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    Map.merge(scenario, %{reviewer: reviewer})
  end

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  describe "mount" do
    test "renders the header, members, and the existing timeline", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer, user: user} = ctx

      {:ok, post} = Messages.post_user_message(channel.id, user.id, "hello @#{agent.name}")

      {:ok, reply} =
        Messages.post_agent_reply(channel.id, agent.id, "On it.\n\n```elixir\nIO.puts(1)\n```")

      {:ok, thread_reply} = Messages.thread_reply(post.id, {:agent, agent.id}, "in the thread")

      {:ok, note} =
        Messages.post_user_note(
          channel.id,
          user.id,
          "Handing this task to @#{reviewer.name}: db work"
        )

      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: channel.id,
          task_id: ctx.task.id,
          from_agent_id: nil,
          to_agent_id: reviewer.id,
          summary: "db work",
          reason: "db work"
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)

      assert has_element?(view, "#channel-name", channel.name)
      assert has_element?(view, "#owner-badge", "@#{agent.name}")
      assert has_element?(view, "#task-status", "open")
      assert has_element?(view, "#branch", "main")
      assert has_element?(view, "#member-#{agent.id}", "@#{agent.name}")
      assert has_element?(view, "#member-#{reviewer.id}", "@#{reviewer.name}")

      # user post with a highlighted mention, agent reply with a code block
      assert has_element?(view, "#timeline #message-#{post.id}[data-kind=post]", "hello")
      assert has_element?(view, "#message-#{post.id} span", "@#{agent.name}")

      assert has_element?(
               view,
               "#timeline #message-#{reply.id}[data-kind=reply] pre code",
               "IO.puts(1)"
             )

      # the thread reply is nested under its root, not inline
      assert has_element?(view, "#thread-#{post.id} #message-#{thread_reply.id}", "in the thread")
      assert has_element?(view, "#thread-toggle-#{post.id}", "1 reply")
      refute has_element?(view, "#timeline > div > article#message-#{thread_reply.id}")

      # the slash-command note is a subtle line carrying the user's name
      assert has_element?(view, "#message-#{note.id}", user.display_name)
      assert has_element?(view, "#message-#{note.id}", "Handing this task to")

      # the user-initiated handoff line names the user, and the banner offers Accept/Reject
      [event] = Timeline.list(channel.id, types: ["handoff_requested"])

      assert has_element?(
               view,
               "#evt-#{event.id}",
               "#{user.display_name} handed this task to @#{reviewer.name}"
             )

      assert has_element?(view, "#handoff-#{handoff.id}-accept")
      assert has_element?(view, "#composer-form #composer-input")
    end

    test "shows an empty state when there are no events", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, "#timeline", "Nothing here yet")
    end
  end

  describe "composer" do
    test "posting text calls the runtime and the message appears via broadcast", ctx do
      %{channel: channel, agent: agent} = ctx
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view
      |> form("#composer-form", message: %{body: "please look at retries"})
      |> render_submit()

      assert_receive {:timeline, %{event_type: "message", message: %{id: message_id}}}, 2_000
      assert_push_event(view, "composer:clear", %{})

      assert has_element?(
               view,
               "#message-#{message_id}[data-kind=post]",
               "please look at retries"
             )

      # the owner was woken: the runtime records agent_started and marks it busy
      assert_receive {:agent_status, agent_id, :busy}, 2_000
      assert agent_id == agent.id
      assert has_element?(view, "#member-#{agent.id} #abort-#{agent.id}")
    end

    test "a malformed slash command shows a flash and keeps the text", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      view
      |> form("#composer-form", message: %{body: "/handoff"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "usage: /handoff")
      assert has_element?(view, "#composer-input", "/handoff")
      refute_push_event(view, "composer:clear", %{})
    end

    test "/handoff from the user creates a pending handoff banner", ctx do
      %{channel: channel, reviewer: reviewer} = ctx
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view
      |> form("#composer-form", message: %{body: "/handoff @#{reviewer.name} needs schema work"})
      |> render_submit()

      [handoff] = Handoffs.pending_for_channel(channel.id)
      assert has_element?(view, "#handoff-#{handoff.id}", "@#{reviewer.name}")
      assert has_element?(view, "#handoff-#{handoff.id}", "needs schema work")

      # the runtime wakes the target before the test ends
      assert_receive {:agent_status, reviewer_id, :busy}, 2_000
      assert reviewer_id == reviewer.id
    end
  end

  describe "telemetry" do
    test "a telemetry broadcast renders the working card and idle clears it", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#telemetry-#{agent.id}")

      broadcast_telemetry(channel.id, agent.id, :tool_started, %{
        call_id: "c1",
        tool: "read",
        status: :running,
        input: %{"filePath" => "lib/a.ex"},
        title: nil,
        message_id: "m",
        part_id: "p1"
      })

      assert has_element?(view, "#telemetry-#{agent.id}", "@#{agent.name} is working")
      assert has_element?(view, "#telemetry-#{agent.id}-c1", "read")
      assert has_element?(view, "#telemetry-#{agent.id}-c1", "lib/a.ex")
      assert has_element?(view, "#member-#{agent.id} #abort-#{agent.id}")

      broadcast_telemetry(channel.id, agent.id, :tool_completed, %{
        call_id: "c1",
        tool: "read",
        status: :ok,
        input: %{},
        title: "Read lib/a.ex",
        output: "",
        error: nil,
        metadata: %{},
        time: %{},
        message_id: "m",
        part_id: "p1"
      })

      broadcast_telemetry(channel.id, agent.id, :file_changed, %{path: "lib/a.ex"})

      broadcast_telemetry(channel.id, agent.id, :text_delta, %{
        message_id: "m",
        part_id: "p2",
        delta: "Looking "
      })

      broadcast_telemetry(channel.id, agent.id, :text_delta, %{
        message_id: "m",
        part_id: "p2",
        delta: "closer."
      })

      assert has_element?(view, "#telemetry-#{agent.id}-c1", "Read lib/a.ex")
      assert has_element?(view, "#telemetry-#{agent.id}", "1 tools")
      assert has_element?(view, "#telemetry-#{agent.id}", "Looking closer.")

      broadcast_telemetry(channel.id, agent.id, :text_done, %{
        message_id: "m",
        part_id: "p2",
        text: "Done looking."
      })

      assert has_element?(view, "#telemetry-#{agent.id}", "Done looking.")
      refute has_element?(view, "#telemetry-#{agent.id}", "Looking closer.")

      # collapsing keeps the header and hides the entries
      view |> element("#telemetry-toggle-#{agent.id}") |> render_click()
      assert has_element?(view, "#telemetry-#{agent.id}[data-collapsed=true]")
      refute has_element?(view, "#telemetry-#{agent.id}-c1")

      broadcast_status(channel.id, agent.id, :idle)
      refute has_element?(view, "#telemetry-#{agent.id}")
      refute has_element?(view, "#abort-#{agent.id}")
    end
  end

  describe "permissions" do
    test "a pending permission renders a card and Once answers it", ctx do
      %{channel: channel, session: session} = ctx

      {:ok, request} =
        PermissionRequests.record(%{
          channel_id: channel.id,
          agent_session_id: session.id,
          opencode_permission_id: "per_live_1",
          permission: "edit",
          patterns: ["lib/a.ex"],
          metadata: %{"diff" => "+added line"},
          status: "pending"
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#permission-#{request.id}", "edit")
      assert has_element?(view, "#permission-#{request.id} code", "lib/a.ex")
      assert has_element?(view, "#permission-#{request.id} pre", "+added line")

      expect(OC, :reply_permission, fn _dir, "per_live_1", :once, _opts -> {:ok, true} end)
      view |> element("#permission-#{request.id}-once") |> render_click()

      refute has_element?(view, "#permission-#{request.id}")
      assert PermissionRequests.get!(request.id).status == "once"
    end

    test "a permission_resolved event removes the card", ctx do
      %{channel: channel, session: session} = ctx

      {:ok, request} =
        PermissionRequests.record(%{
          channel_id: channel.id,
          agent_session_id: session.id,
          opencode_permission_id: "per_live_2",
          permission: "bash",
          status: "pending"
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#permission-#{request.id}")

      {:ok, _} = PermissionRequests.resolve(request, :reject)
      refute has_element?(view, "#permission-#{request.id}")
    end
  end

  describe "handoffs and task" do
    test "accepting a pending handoff changes the owner badge", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer} = ctx

      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: channel.id,
          task_id: ctx.task.id,
          from_agent_id: agent.id,
          to_agent_id: reviewer.id,
          summary: "schema is next",
          reason: "db work"
        })

      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#owner-badge", "@#{agent.name}")
      assert has_element?(view, "#handoff-#{handoff.id}", "@#{reviewer.name}")

      view |> element("#handoff-#{handoff.id}-accept") |> render_click()

      assert has_element?(view, "#owner-badge", "@#{reviewer.name}")
      refute has_element?(view, "#handoff-#{handoff.id}")
      assert Handoffs.get!(handoff.id).status == "accepted"

      # acceptance wakes the previous owner; wait so the runtime finishes inside the test
      assert_receive {:agent_status, previous_owner, :busy}, 2_000
      assert previous_owner == agent.id
    end

    test "rejecting a pending handoff records the reason", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer} = ctx

      {:ok, handoff} =
        Handoffs.request(%{
          channel_id: channel.id,
          from_agent_id: agent.id,
          to_agent_id: reviewer.id,
          summary: "try it"
        })

      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view
      |> form("#handoff-#{handoff.id}-reject-form", %{reason: "not now"})
      |> render_submit()

      refute has_element?(view, "#handoff-#{handoff.id}")
      assert %{status: "rejected", rejection_reason: "not now"} = Handoffs.get!(handoff.id)
      assert has_element?(view, "#owner-badge", "@#{agent.name}")
      assert_receive {:agent_status, _previous_owner, :busy}, 2_000
    end

    test "the task form updates the task and the header pill", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      refute has_element?(view, "#task-form")

      view |> element("#edit-task") |> render_click()

      view
      |> form("#task-form", task: %{title: "Ship retries", status: "working"})
      |> render_submit()

      assert has_element?(view, "#task-status", "working")
      assert has_element?(view, "#task-title", "Ship retries")
      refute has_element?(view, "#task-form")
    end
  end

  describe "changes modal" do
    test "lists changed files and shows a diff", ctx do
      %{channel: channel, repository: repository} = ctx
      File.write!(Path.join(repository.path, "notes.txt"), "hello\n")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#changes-modal")

      view |> element("#open-changes") |> render_click()
      assert has_element?(view, "#changed-files", "notes.txt")

      view |> element("#changed-files button", "notes.txt") |> render_click()
      assert has_element?(view, "#file-diff", "+hello")

      view |> element("#close-changes") |> render_click()
      refute has_element?(view, "#changes-modal")
    end
  end

  defp conn_of(%{conn: conn}), do: conn
end
