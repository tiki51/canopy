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

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)

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

    test "a finished turn is a reopenable card with its activity, or a plain line without", ctx do
      %{channel: channel, agent: agent} = ctx

      {:ok, with_activity} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{
            "tools" => 2,
            "files" => ["lib/a.ex"],
            "cost" => 0.01,
            "duration_ms" => 4_200,
            "outcome" => "ok",
            "activity" => [
              %{
                "key" => "c1",
                "kind" => "tool",
                "status" => "ok",
                "label" => "Read lib/a.ex",
                "detail" => "lib/a.ex"
              },
              %{
                "key" => "file-lib/a.ex",
                "kind" => "file",
                "status" => "ok",
                "label" => "a.ex",
                "detail" => "lib/a.ex"
              }
            ]
          }
        })

      {:ok, without} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{
            "tools" => 0,
            "files" => [],
            "cost" => 0,
            "duration_ms" => 10,
            "outcome" => "ok"
          }
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)

      assert has_element?(view, "details#turn-#{with_activity.id}:not([open])")
      assert has_element?(view, "#turn-toggle-#{with_activity.id}", "@#{agent.name} finished")
      assert has_element?(view, "#turn-toggle-#{with_activity.id}", "2 tools")
      assert has_element?(view, "#turn-#{with_activity.id}-c1", "Read lib/a.ex")
      assert has_element?(view, "#turn-#{with_activity.id}-file-lib-a-ex", "a.ex")

      refute has_element?(view, "#turn-#{without.id}")
      assert has_element?(view, "#line-#{without.id}", "@#{agent.name} finished")

      {:ok, recap} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{
            "tools" => 1,
            "outcome" => "ok",
            "final_text" => "Posted the fix. **Summary**: done."
          }
        })

      assert has_element?(view, "details#turn-#{recap.id}:not([open])")
      assert has_element?(view, "#turn-#{recap.id}-note", "Closing note")
      assert has_element?(view, "#turn-#{recap.id}-note strong", "Summary")
    end

    test "shows an empty state when there are no events", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, "#timeline", "Nothing here yet")
    end
  end

  describe "unread marks" do
    test "other channels show a dot for unread and a count for mentions; opening clears them",
         ctx do
      %{channel: channel, agent: agent, user: user, repository: repository} = ctx
      other = Fixtures.channel_fixture(%{repository_id: repository.id, owner_agent_id: agent.id})

      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#unread-#{other.id}")

      {:ok, _} = Messages.post_agent_message(other.id, agent.id, "a quiet finding")
      assert has_element?(view, "#unread-#{other.id}[data-unread='1'][data-mentions='0']")
      assert has_element?(view, "#sidebar-channel-#{other.id} .font-semibold")

      {:ok, _} =
        Messages.post_agent_message(other.id, agent.id, "@#{user.display_name} please look")

      assert has_element?(view, "#unread-#{other.id}[data-unread='2'][data-mentions='1']", "1")

      # messages in the open channel never mark it, and never show on its own row
      {:ok, _} = Messages.post_agent_message(channel.id, agent.id, "@#{user.display_name} here")
      refute has_element?(view, "#unread-#{channel.id}")

      # opening the other channel reads it
      {:ok, view, _html} = open(conn_of(ctx), other)
      refute has_element?(view, "#unread-#{other.id}")
      refute has_element?(view, "#unread-#{channel.id}")
    end
  end

  describe "direct messages" do
    test "a DM shows the agent as its title, marks the sidebar row, and hides itself from channels",
         ctx do
      %{channel: channel, agent: agent, repository: repository} = ctx
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)

      {:ok, view, html} = open(conn_of(ctx), dm)
      assert page_title(view) =~ "@" <> agent.name
      assert has_element?(view, "#channel-name", "@" <> agent.name)
      assert has_element?(view, "#channel-name", "dm")
      refute has_element?(view, "#channel-topic")
      assert has_element?(view, "#owner-badge", "@" <> agent.name)

      # The DM row is the one marked; the agent row goes to the Agents page.
      assert has_element?(view, "#sidebar-dm-#{dm.id}[data-active]")
      refute has_element?(view, "#sidebar-agent-#{agent.id}[data-active]")
      assert html =~ ~s(href="/agents/#{agent.id}")
      refute has_element?(view, "#sidebar-channel-#{dm.id}")
      assert has_element?(view, "#sidebar-channel-#{channel.id}")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#sidebar-dm-#{dm.id}[data-active]")
      assert has_element?(view, "#sidebar-agent-#{agent.id}[href='/agents/#{agent.id}']")
    end

    test "the sidebar lists DMs, including ones agents open while you watch", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer, repository: repository} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#sidebar-dms", "Click an agent below to start one")

      {:ok, group} = Canopy.Channels.ensure_dm(repository.id, [agent, reviewer])
      label = "@#{agent.name}, @#{reviewer.name}"
      assert has_element?(view, "#sidebar-dm-#{group.id}", label)
      refute has_element?(view, "#sidebar-channel-#{group.id}")

      {:ok, view, _html} = open(conn_of(ctx), group)
      assert has_element?(view, "#channel-name", label)
      assert has_element?(view, "#sidebar-dm-#{group.id}[data-active]")
      refute has_element?(view, "#sidebar-agent-#{agent.id}[data-active]")
      assert page_title(view) =~ label
    end
  end

  describe "attachments" do
    @png File.read!(Path.expand("../../support/files/red.png", __DIR__))

    test "an uploaded image is attached to the message and rendered inline", ctx do
      %{channel: channel} = ctx
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      upload =
        file_input(view, "#upload-form", :files, [
          %{name: "shot.png", content: @png, type: "image/png"}
        ])

      assert render_upload(upload, "shot.png") =~ "shot.png"
      assert has_element?(view, "#composer-files [id^=upload-]", "shot.png")

      view |> form("#composer-form", message: %{body: ""}) |> render_submit()

      assert_receive {:timeline, %{event_type: "message", message: %{id: id, documents: [doc]}}},
                     2_000

      assert doc.filename == "shot.png"
      assert doc.kind == "image"
      assert doc.origin_channel_id == channel.id

      assert has_element?(
               view,
               "#attachment-#{id}-#{doc.id}[data-kind=image] img[alt='shot.png']"
             )

      refute has_element?(view, "#composer-files")
      assert_push_event(view, "composer:clear", %{})
    end

    test "other files render as download cards and can be removed before sending", ctx do
      %{channel: channel} = ctx
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      upload =
        file_input(view, "#upload-form", :files, [
          %{name: "report.md", content: "# hi", type: "text/markdown"},
          %{name: "junk.md", content: "x", type: "text/markdown"}
        ])

      render_upload(upload, "report.md")
      render_upload(upload, "junk.md")
      [_, junk_ref] = Enum.map(upload.entries, & &1["ref"])
      view |> element("#upload-#{junk_ref} button") |> render_click()
      refute has_element?(view, "#upload-#{junk_ref}")

      view |> form("#composer-form", message: %{body: "the analysis"}) |> render_submit()

      assert_receive {:timeline, %{event_type: "message", message: %{id: id, documents: [doc]}}},
                     2_000

      assert doc.filename == "report.md"
      assert has_element?(view, "#attachment-#{id}-#{doc.id}[data-kind=text]", "report.md")
      assert has_element?(view, "#message-#{id}", "the analysis")
    end

    test "a file over the limit shows an error and blocks sending", ctx do
      Application.put_env(:canopy, :max_upload_bytes, 8)
      on_exit(fn -> Application.delete_env(:canopy, :max_upload_bytes) end)
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      upload =
        file_input(view, "#upload-form", :files, [
          %{name: "big.txt", content: "more than eight bytes", type: "text/plain"}
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(upload, "big.txt")
      assert render(view) =~ "Too large; the limit is 8 B."

      view |> form("#composer-form", message: %{body: "with a big file"}) |> render_submit()
      assert has_element?(view, "#flash-error", "still uploading, or failed")
      refute_push_event(view, "composer:clear", %{})
    end

    test "attachments on a slash command are refused and the files are dropped", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      upload =
        file_input(view, "#upload-form", :files, [
          %{name: "shot.png", content: @png, type: "image/png"}
        ])

      render_upload(upload, "shot.png")
      view |> form("#composer-form", message: %{body: "/handoff @nobody x"}) |> render_submit()
      assert has_element?(view, "#flash-error", "commands cannot carry attachments")
      assert Canopy.Documents.count() == 0
    end
  end

  describe "library" do
    test "a shared document can be picked from the library and sent again", ctx do
      %{channel: channel, user: user} = ctx

      {:ok, doc} =
        Canopy.Documents.create(%{
          filename: "earlier.md",
          source: {:binary, "old"},
          user_id: user.id
        })

      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view |> element("#composer-library") |> render_click()
      assert has_element?(view, "#library-#{doc.id}", "earlier.md")
      view |> element("#library-dialog form") |> render_change(%{q: "zzz"})
      refute has_element?(view, "#library-#{doc.id}")
      view |> element("#library-dialog form") |> render_change(%{q: "earl"})
      view |> element("#library-#{doc.id}") |> render_click()

      refute has_element?(view, "#library-picker")
      assert has_element?(view, "#picked-#{doc.id}", "earlier.md")

      view |> form("#composer-form", message: %{body: "again"}) |> render_submit()

      assert_receive {:timeline,
                      %{event_type: "message", message: %{id: id, documents: [%{id: doc_id}]}}},
                     2_000

      assert doc_id == doc.id
      assert has_element?(view, "#attachment-#{id}-#{doc.id}")
      refute has_element?(view, "#picked-#{doc.id}")
    end

    test "?attach= pre-picks a document and a deleted document leaves the message", ctx do
      %{channel: channel, user: user} = ctx

      {:ok, doc} =
        Canopy.Documents.create(%{filename: "pre.md", source: {:binary, "x"}, user_id: user.id})

      {:ok, message} =
        Messages.post_user_message(channel.id, user.id, "with file", attachments: [doc.id])

      {:ok, view, _html} = live(conn_of(ctx), ~p"/channels/#{channel.id}?attach=#{doc.id}")
      assert has_element?(view, "#picked-#{doc.id}", "pre.md")
      assert has_element?(view, "#attachment-#{message.id}-#{doc.id}")

      view |> element("#picked-#{doc.id} button") |> render_click()
      refute has_element?(view, "#picked-#{doc.id}")

      {:ok, _} = Canopy.Documents.delete(doc)
      refute has_element?(view, "#attachment-#{message.id}-#{doc.id}")
      assert has_element?(view, "#message-#{message.id}", "with file")

      {:ok, view, _html} = live(conn_of(ctx), ~p"/channels/#{channel.id}?attach=doc_gone")
      assert has_element?(view, "#flash-error", "no longer exists")
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
      # the browser keeps the draft (LiveView never patches the textarea); the
      # server must not tell it to clear
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

      assert has_element?(view, "#telemetry-#{agent.id}", "@#{agent.name} is researching")
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

      # closed by default (a <details> without `open`), with a pulsing dot in the header
      assert has_element?(view, "details#telemetry-#{agent.id}:not([open])")
      assert has_element?(view, "#telemetry-toggle-#{agent.id} [data-status=busy] .animate-ping")

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

  describe "chatter budget" do
    test "a pause shows the bar and Continue clears it", ctx do
      %{channel: channel} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#paused-bar")

      Phoenix.PubSub.broadcast(Canopy.PubSub, Timeline.topic(channel.id), {:chatter, :paused})
      assert has_element?(view, "#paused-bar", "Paused after")

      view |> element("#continue-chatter") |> render_click()
      refute has_element?(view, "#paused-bar")
      refute Runtime.paused?(channel.id)
    end
  end

  describe "schedules" do
    test "the Scheduled panel lists the channel's schedules with a count, cancels, and follows changes",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#schedule-count")

      {:ok, once} =
        Canopy.Schedules.create(%{
          channel_id: channel.id,
          agent_id: agent.id,
          created_by_agent_id: agent.id,
          instruction: "Check the deploy went out.",
          when: "2h"
        })

      assert has_element?(view, "#schedule-count", "1")
      assert render(view) =~ "@#{agent.name} scheduled: once · Check the deploy went out."

      view |> element("#edit-schedules") |> render_click()
      assert has_element?(view, "#channel-schedules-#{once.id}", "Check the deploy went out.")
      assert has_element?(view, "#channel-schedules-#{once.id}", "in 2h")
      assert has_element?(view, "#channel-schedules-#{once.id}", "@#{agent.name}")

      view |> element("#cancel-schedule-#{once.id}") |> render_click()
      refute has_element?(view, "#channel-schedules-#{once.id}")
      refute has_element?(view, "#schedule-count")
      assert %{status: "cancelled"} = Canopy.Schedules.get!(once.id)
      assert render(view) =~ "cancelled a schedule for @#{agent.name}"
    end
  end

  describe "compact timeline" do
    test "routine activity is marked and hidden by default; the toggle and the browser preference flip it",
         ctx do
      %{channel: channel, agent: agent} = ctx

      {:ok, started} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_started"
        })

      {:ok, clean} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{"outcome" => "ok", "tools" => 1}
        })

      {:ok, passed_note} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{"outcome" => "ok", "passed" => true, "note" => "still 0-0, nothing new"}
        })

      {:ok, errored} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_error",
          payload: %{"reason" => "boom"}
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#timeline.timeline-compact")
      assert has_element?(view, "#evt-#{started.id}[data-activity=routine]")
      assert has_element?(view, "#evt-#{clean.id}[data-activity=routine]")
      refute has_element?(view, "#evt-#{passed_note.id}[data-activity]")
      refute has_element?(view, "#evt-#{errored.id}[data-activity]")

      view |> element("#toggle-activity") |> render_click()
      refute has_element?(view, "#timeline.timeline-compact")
      assert has_element?(view, "#toggle-activity.btn-active")

      render_hook(view, "pref", %{"key" => "timeline-activity", "value" => "compact"})
      assert has_element?(view, "#timeline.timeline-compact")
    end
  end

  describe "session reset" do
    test "the header button resets an idle member's session and says so on the timeline", ctx do
      %{channel: channel, agent: agent, session: session} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view |> element("#reset-session-#{agent.id}") |> render_click()
      assert render(view) =~ "reset @#{agent.name}&#39;s session"
      assert Canopy.AgentSessions.get_root(channel.id, agent.id) == nil
      refute Canopy.Repo.get(Canopy.AgentSessions.AgentSession, session.id)
    end
  end

  describe "members and archiving" do
    test "agents can be added and removed from the members panel; the owner cannot", ctx do
      %{channel: channel, agent: owner, reviewer: reviewer} = ctx
      newcomer = Fixtures.agent_fixture(%{name: "newcomer#{Fixtures.unique_suffix()}"})

      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#members-panel")

      view |> element("#edit-members") |> render_click()
      assert has_element?(view, "#member-row-#{owner.id}", "owner")
      refute has_element?(view, "#remove-member-#{owner.id}")
      assert has_element?(view, "#remove-member-#{reviewer.id}")
      assert has_element?(view, "#add-member-select option[value='#{newcomer.id}']")

      view |> form("#add-member-form", agent_id: newcomer.id) |> render_submit()
      assert has_element?(view, "#member-row-#{newcomer.id}", "@#{newcomer.name}")
      assert has_element?(view, "#member-#{newcomer.id}", "@#{newcomer.name}")
      refute has_element?(view, "#add-member-select option[value='#{newcomer.id}']")
      assert render(view) =~ "@#{newcomer.name} joined the channel"

      view |> element("#remove-member-#{reviewer.id}") |> render_click()
      refute has_element?(view, "#member-row-#{reviewer.id}")
      refute has_element?(view, "#member-#{reviewer.id}")
      assert render(view) =~ "@#{reviewer.name} was removed from the channel"
      assert has_element?(view, "#add-member-select option[value='#{reviewer.id}']")

      # the composer's mention list follows the membership
      assert has_element?(view, "#composer-form[data-members*='#{newcomer.name}']")
      refute has_element?(view, "#composer-form[data-members*='#{reviewer.name}']")
    end

    test "the budget panel sets and clears the spend limit; reaching it shows a bar", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#edit-budget", "$0.00")
      refute has_element?(view, "#budget-panel")

      view |> element("#edit-budget") |> render_click()
      assert has_element?(view, "#budget-spent", "no limit")
      refute has_element?(view, "#clear-spend-limit")

      view |> form("#budget-form", spend_limit: "abc") |> render_submit()
      assert render(view) =~ "must be a positive amount"

      view |> form("#budget-form", spend_limit: "2.50") |> render_submit()
      refute has_element?(view, "#budget-panel")
      assert has_element?(view, "#edit-budget", "$0.00 / $2.50")
      assert render(view) =~ "set this channel&#39;s spend limit to $2.50"
      refute has_element?(view, "#limit-bar")

      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{"outcome" => "ok", "cost" => 3.0, "tools" => 1, "duration_ms" => 10}
        })

      assert has_element?(view, "#edit-budget", "$3.00 / $2.50")
      assert has_element?(view, "#limit-bar", "Spend limit reached: $3.00 of $2.50")

      view |> element("#raise-limit") |> render_click()
      assert has_element?(view, "#budget-spent", "Spent $3.00 of a $2.50 limit")
      view |> element("#clear-spend-limit") |> render_click()
      refute has_element?(view, "#limit-bar")
      assert has_element?(view, "#edit-budget", "$3.00")
      refute has_element?(view, "#edit-budget", "/")
      assert render(view) =~ "removed this channel&#39;s spend limit"
    end

    test "archiving hides the composer, marks the sidebar, and reopening restores it", ctx do
      %{channel: channel} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view |> element("#archive-channel") |> render_click()
      assert has_element?(view, "#archived-badge")
      assert has_element?(view, "#archived-bar", "This channel is archived")
      refute has_element?(view, "#composer-form")
      refute has_element?(view, "#archive-channel")
      assert has_element?(view, "#sidebar-channel-#{channel.id} .hero-archive-box-mini")
      assert render(view) =~ "archived this channel"
      assert Canopy.Channels.get!(channel.id).status == "archived"

      view |> element("#reopen-channel") |> render_click()
      assert has_element?(view, "#composer-form")
      refute has_element?(view, "#archived-bar")
      assert has_element?(view, "#archive-channel")
      assert render(view) =~ "reopened this channel"
    end

    test "a DM's header switches its repository and the timeline says so", ctx do
      %{agent: agent, repository: repository} = ctx
      other = Fixtures.repository_fixture(%{name: "calc"})
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)
      {:ok, view, _html} = open(conn_of(ctx), dm)

      assert has_element?(view, "#dm-repository option[value='#{repository.id}'][selected]")
      view |> form("#dm-repository-form", %{"repository_id" => other.id}) |> render_change()
      assert Canopy.Channels.get!(dm.id).repository_id == other.id
      assert has_element?(view, "#dm-repository option[value='#{other.id}'][selected]")
      assert render(view) =~ "moved this conversation to calc"
      assert has_element?(view, "#sidebar-dm-#{dm.id}[title*=calc]")
    end

    test "a DM has no members button", ctx do
      %{agent: agent, repository: repository} = ctx
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)
      {:ok, view, _html} = open(conn_of(ctx), dm)
      refute has_element?(view, "#edit-members")
      assert has_element?(view, "#archive-channel")
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
