defmodule CanopyWeb.ChannelLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import CanopyWeb.LiveHelpers

  alias Canopy.{
    Fixtures,
    Handoffs,
    Messages,
    PermissionRequests,
    QuestionRequests,
    Runtime,
    Timeline
  }

  alias Canopy.ClaudeCode.Prompts
  alias Canopy.OpenCode.ClientMock, as: OC
  alias CanopyWeb.ChannelLive

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
    # the transcript page reads a session's history
    stub(OC, :messages, fn _dir, _sid, _query, _opts -> {:ok, []} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    Map.merge(scenario, %{reviewer: reviewer})
  end

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  # the Details side panel, where the channel's own controls live
  defp details(view), do: view |> element("#toggle-details") |> render_click()

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
      assert has_element?(view, "#agents-button", "2 agents")
      assert has_element?(view, "#agents-button[title='2 agents, all idle']")
      refute has_element?(view, "#details-panel")
      details(view)
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

      # the thread stays in the thread: the feed shows the root's summary row
      assert has_element?(view, "#thread-summary-#{post.id}", "1 reply")
      refute has_element?(view, "#timeline #message-#{thread_reply.id}")

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

      # closed: only the header, the rows render once opened
      assert has_element?(view, "#turn-#{with_activity.id}[data-open=false]")
      assert has_element?(view, "#turn-toggle-#{with_activity.id}", "@#{agent.name} finished")
      assert has_element?(view, "#turn-toggle-#{with_activity.id}", "2 tools")
      refute has_element?(view, "#turn-#{with_activity.id}-c1")

      view |> element("#turn-toggle-#{with_activity.id}") |> render_click()
      assert has_element?(view, "#turn-toggle-#{with_activity.id}[aria-expanded=true]")
      assert has_element?(view, "#turn-#{with_activity.id}-c1", "Read lib/a.ex")
      assert has_element?(view, "#turn-#{with_activity.id}-file-lib-a-ex", "lib/a.ex")

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

      assert has_element?(view, "#turn-#{recap.id}[data-open=false]")
      view |> element("#turn-toggle-#{recap.id}") |> render_click()
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
      refute has_element?(view, "#agents-button")
      details(view)
      assert has_element?(view, "#owner-badge", "@" <> agent.name)
      assert has_element?(view, "#details-agents", "Agent")
      assert has_element?(view, "#member-#{agent.id}")
      refute has_element?(view, "#edit-members")

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

  describe "mentions and channel references" do
    test "mentioning an agent outside the channel hints at /i, which adds it", ctx do
      %{channel: channel} = ctx
      outsider = Fixtures.agent_fixture(%{name: "outsider#{Fixtures.unique_suffix()}"})
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)
      assert has_element?(view, "#composer-form[data-agents*='#{outsider.name}']")

      view
      |> form("#composer-form", message: %{body: "@#{outsider.name} can you look?"})
      |> render_submit()

      assert_receive {:timeline, %{event_type: "message"}}, 2_000
      assert has_element?(view, "#flash-info", "@#{outsider.name} is not in this channel")
      assert has_element?(view, "#flash-info", "/i @#{outsider.name}")
      refute has_element?(view, "#member-#{outsider.id}")
      # the owner wakes for an unaddressed user message; the outsider never does
      assert_receive {:agent_status, woken, :busy}, 2_000
      assert woken == ctx.agent.id

      view |> form("#composer-form", message: %{body: "/i @#{outsider.name}"}) |> render_submit()
      assert_receive {:timeline, %{event_type: "member_added", agent_id: agent_id}}, 2_000
      assert agent_id == outsider.id
      assert has_element?(view, "#member-#{outsider.id}")
      assert render(view) =~ "@#{outsider.name} joined the channel"
      assert_push_event(view, "composer:clear", %{})
    end

    test "a team mention of outsiders hints at /i @team; the composer offers team names", ctx do
      %{channel: channel} = ctx
      one = Fixtures.agent_fixture(%{name: "one#{Fixtures.unique_suffix()}"})
      two = Fixtures.agent_fixture(%{name: "two#{Fixtures.unique_suffix()}"})
      team = Fixtures.team_fixture([one, two], name: "crew#{Fixtures.unique_suffix()}")
      Timeline.subscribe(channel.id)

      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)
      assert has_element?(view, "#composer-form[data-teams*='#{team.name}']")

      view
      |> form("#composer-form", message: %{body: "@#{team.name} can you look?"})
      |> render_submit()

      assert_receive {:timeline, %{event_type: "message"}}, 2_000
      assert has_element?(view, "#flash-info", "not in this channel")
      assert has_element?(view, "#flash-info", "Invite with /i @#{team.name}.")

      view |> form("#composer-form", message: %{body: "/i @#{team.name}"}) |> render_submit()
      assert_receive {:timeline, %{event_type: "team_added"}}, 2_000
      assert has_element?(view, "#flash-info", "Invited @#{team.name}")
      assert has_element?(view, "#member-#{one.id}")
      assert has_element?(view, "#member-#{two.id}")
      assert render(view) =~ "@#{team.name} joined: @#{one.name}, @#{two.name}"
    end

    test "#channel in a message links to the channel, and the composer offers channel names",
         ctx do
      %{channel: channel, user: user} = ctx

      other =
        Fixtures.channel_fixture(%{repository_id: ctx.repository.id, name: "billing-retries"})

      {:ok, message} =
        Messages.post_user_message(channel.id, user.id, "see #billing-retries and #nope")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#composer-form[data-channels*='billing-retries']")

      assert has_element?(
               view,
               "#message-#{message.id} a[href='/channels/#{other.id}']",
               "#billing-retries"
             )

      refute has_element?(view, "#message-#{message.id} a", "#nope")
    end

    test "the composer form carries what the mention highlight needs", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer} = ctx
      outsider = Fixtures.agent_fixture(%{name: "outsider#{Fixtures.unique_suffix()}"})
      team = Fixtures.team_fixture([outsider, reviewer], name: "crew#{Fixtures.unique_suffix()}")

      archived =
        Fixtures.channel_fixture(%{repository_id: ctx.repository.id, name: "old-plans"})

      {:ok, _} = Canopy.Channels.archive(archived)
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      form = "#composer-form"
      assert has_element?(view, "#{form}[data-members*='#{reviewer.name}']")
      refute has_element?(view, "#{form}[data-members*='#{outsider.name}']")
      # the team's active members, so a team with nobody here reads as an outsider
      assert has_element?(view, ~s(#{form}[data-team-members*='"#{team.name}":']))
      assert has_element?(view, ~s(#{form}[data-team-members*='"#{outsider.name}"']))
      # every linkable channel is highlighted; only open ones are suggested
      assert has_element?(view, "#{form}[data-channel-refs*='old-plans']")
      refute has_element?(view, "#{form}[data-channels*='old-plans']")
      assert has_element?(view, "#{form}[data-commands*='invite']")
      assert has_element?(view, "#composer-input-wrap #composer-highlight[aria-hidden='true']")

      # the thread panel's composer carries the same sources, marked as a thread
      refute has_element?(view, "#{form}[data-thread]")
      view |> element("#reply-#{root.id}") |> render_click()
      thread_form = "#thread-composer-form"
      assert has_element?(view, "#{thread_form}[data-thread='true']")
      assert has_element?(view, "#{thread_form}[data-members*='#{reviewer.name}']")
      assert has_element?(view, ~s(#{thread_form}[data-team-members*='"#{team.name}":']))
      assert has_element?(view, "#{thread_form}[data-channel-refs*='old-plans']")
      assert has_element?(view, "#thread-composer-input-wrap #thread-composer-highlight")

      assert has_element?(
               view,
               "#thread-composer-input[phx-hook=Composer][data-highlight='#thread-composer-highlight'][data-suggestions='#thread-composer-suggestions'][data-upload=thread_files]"
             )

      # Details takes the side panel from the thread
      details(view)
      refute has_element?(view, "#thread-panel")
      view |> element("#edit-members") |> render_click()
      view |> form("#add-member-form", agent_id: outsider.id) |> render_submit()
      assert has_element?(view, "#{form}[data-members*='#{outsider.name}']")
    end

    test "a DM's composer knows only its own agents", ctx do
      %{agent: agent, reviewer: reviewer} = ctx
      {:ok, dm} = Canopy.Channels.ensure_dm(ctx.repository.id, agent)

      {:ok, view, _html} = open(conn_of(ctx), dm)
      assert has_element?(view, "#composer-form[data-agents='#{Jason.encode!([agent.name])}']")
      assert has_element?(view, "#composer-form[data-members='#{Jason.encode!([agent.name])}']")
      assert has_element?(view, "#composer-form[data-team-members='{}']")
      refute has_element?(view, "#composer-form[data-agents*='#{reviewer.name}']")
    end

    test "sent messages highlight known agents and teams only", ctx do
      %{channel: channel, user: user, reviewer: reviewer} = ctx
      team = Fixtures.team_fixture([reviewer], name: "crew#{Fixtures.unique_suffix()}")

      {:ok, message} =
        Messages.post_user_message(
          channel.id,
          user.id,
          "@#{reviewer.name} and @#{team.name}, not @nobody or `@#{reviewer.name}`"
        )

      {:ok, view, _html} = open(conn_of(ctx), channel)
      body = "#message-#{message.id} .message-body"
      assert has_element?(view, "#{body} span", "@#{reviewer.name}")
      assert has_element?(view, "#{body} span", "@#{team.name}")
      refute has_element?(view, "#{body} span", "@nobody")
      assert has_element?(view, "#{body} code", "@#{reviewer.name}")
      # the code span did not wake anyone twice, and @nobody resolved to no one
      assert message.mentions == [reviewer.id]
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
      details(view)
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

  describe "interrupts" do
    defp sent_message do
      assert_receive {:timeline, %{event_type: "message", message: %{agent_id: nil} = message}},
                     2_000

      message
    end

    test "off by default: no send menu, and nothing a message says interrupts", ctx do
      Timeline.subscribe(ctx.channel.id)
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      refute has_element?(view, "#composer-send-menu")
      refute has_element?(view, "#composer-form[data-interrupt]")

      view
      |> form("#composer-form", message: %{body: "@#{ctx.agent.name} look"})
      |> render_submit()

      refute sent_message().interrupt
    end

    test "on: Enter interrupts, Alt+Enter and the send menu do not", ctx do
      {:ok, _} = Canopy.Settings.update(%{interrupt_on_mention: true})
      Timeline.subscribe(ctx.channel.id)
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, "#composer-send-menu #composer-send-no-interrupt")
      assert has_element?(view, "#composer-form[data-interrupt=true]")
      # Send and its menu are one joined control
      assert has_element?(view, "#composer-send-group.join > #composer-send.join-item")
      assert has_element?(view, "#composer-send-group.join > #composer-send-menu.join-item")
      # the hint is one short line; `/` offers the palette's commands
      assert has_element?(
               view,
               "#composer-hint",
               "Enter to send · Shift+Enter new line · / for commands"
             )

      assert has_element?(view, ~s(#composer-form[data-slash*="Delegate a subtask to a member"]))

      view
      |> form("#composer-form", message: %{body: "@#{ctx.agent.name} look"})
      |> render_submit()

      assert sent_message().interrupt

      # Alt+Enter: the Composer hook sets the hidden input for that one send
      view
      |> form("#composer-form", message: %{body: "@#{ctx.agent.name} later"})
      |> render_submit(%{"interrupt" => "toggle"})

      refute sent_message().interrupt

      # the send menu's button says the same
      view
      |> form("#composer-form", message: %{body: "@#{ctx.agent.name} later still"})
      |> put_submitter("#composer-send-no-interrupt")
      |> render_submit()

      refute sent_message().interrupt
    end

    test "a message steered into a turn shows on its live card, with Interrupt now", ctx do
      {:ok, _} = Canopy.Settings.update(%{interrupt_on_mention: true})
      %{channel: channel, agent: agent} = ctx
      sid = ctx.session.engine_session_id
      stub(OC, :session_status, fn _dir, _opts -> {:ok, %{sid => %{"type" => "busy"}}} end)
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view |> form("#composer-form", message: %{body: "go"}) |> render_submit()
      assert_receive {:agent_status, _, :busy}, 2_000

      view
      |> form("#composer-form", message: %{body: "@#{agent.name} use the other file"})
      |> render_submit()

      assert_receive {:timeline, %{event_type: "agent_interrupted"}}, 2_000
      assert_receive {:steer, _, %{pending: 1}}, 2_000
      assert has_element?(view, "#steer-chip-#{agent.id}", "Interrupting after current step")
      # no step timer dangling on the chip
      refute has_element?(view, "#steer-elapsed-#{agent.id}")
      details(view)
      assert has_element?(view, "#member-#{agent.id}-steers", "1 message waiting")

      # the steered message says it has not been read yet
      assert has_element?(
               view,
               "#timeline [id^=message-queued-]",
               "Queued · delivered after the current step"
             )

      expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
      view |> element("#interrupt-now-#{agent.id}") |> render_click()

      assert_receive {:timeline, %{event_type: "agent_interrupted", payload: %{"mode" => "now"}}},
                     2_000

      # the turn ends: the chip goes with it
      broadcast_status(channel.id, agent.id, :idle)
      refute has_element?(view, "#steer-chip-#{agent.id}")
      refute has_element?(view, "#member-#{agent.id}-steers")
      refute has_element?(view, "#timeline [id^=message-queued-]")
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
      # closed by default, its header naming the call running now
      assert has_element?(view, "#telemetry-#{agent.id}-current", "lib/a.ex")
      refute has_element?(view, "#telemetry-#{agent.id}-c1")
      details(view)
      assert has_element?(view, "#member-#{agent.id} #abort-#{agent.id}")

      view |> element("#telemetry-toggle-#{agent.id}") |> render_click()
      assert has_element?(view, "#telemetry-#{agent.id}-c1", "Read")
      assert has_element?(view, "#telemetry-#{agent.id}-c1", "lib/a.ex")
      assert has_element?(view, "#telemetry-#{agent.id}-c1[data-status=running]")

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

      # streamed text is folded in batches, at most every 100 ms
      refute has_element?(view, "#telemetry-#{agent.id}", "Looking closer.")
      send(view.pid, {:flush_text, agent.id})

      assert has_element?(view, "#telemetry-#{agent.id}-c1[data-status=ok]", "lib/a.ex")
      assert has_element?(view, "#telemetry-#{agent.id}", "1 read")
      refute has_element?(view, "#telemetry-#{agent.id}", "1 reads")
      assert has_element?(view, "#telemetry-#{agent.id}", "Looking closer.")

      broadcast_telemetry(channel.id, agent.id, :text_done, %{
        message_id: "m",
        part_id: "p2",
        text: "Done looking."
      })

      assert has_element?(view, "#telemetry-#{agent.id}", "Done looking.")
      refute has_element?(view, "#telemetry-#{agent.id}", "Looking closer.")

      # the server owns the open state, so a patch keeps it; a pulsing dot in the header
      assert has_element?(view, "#telemetry-#{agent.id}[data-open=true]")
      assert has_element?(view, "#telemetry-toggle-#{agent.id} [data-status=busy] .animate-ping")

      # closing renders only the header again
      view |> element("#telemetry-toggle-#{agent.id}") |> render_click()
      refute has_element?(view, "#telemetry-#{agent.id}-body")

      broadcast_status(channel.id, agent.id, :idle)
      refute has_element?(view, "#telemetry-#{agent.id}")
      refute has_element?(view, "#abort-#{agent.id}")
    end
  end

  describe "activity cards" do
    defp record_turn(ctx, payload, opts \\ []) do
      {:ok, event} =
        Timeline.record(%{
          channel_id: ctx.channel.id,
          agent_id: Keyword.get(opts, :agent_id, ctx.agent.id),
          event_type: "agent_turn_completed",
          payload:
            Map.merge(
              %{
                "tools" => 1,
                "outcome" => "ok",
                "duration_ms" => 1_200,
                "activity" => [
                  %{
                    "key" => "c1",
                    "kind" => "tool",
                    "status" => "ok",
                    "category" => "shell",
                    "label" => "mix test",
                    "command" => "mix test",
                    "duration_ms" => 900,
                    "exit_code" => 1,
                    "fact" => "exit 1"
                  }
                ],
                "activity_meta" => %{"v" => 2, "tallies" => %{"shell" => 1}, "dropped" => 0}
              },
              payload
            )
        })

      event
    end

    test "a live card open when the turn ends arrives open as the finished card", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())
      view |> element("#telemetry-toggle-#{agent.id}") |> render_click()
      view |> element("#telemetry-#{agent.id}-c1-toggle") |> render_click()
      assert has_element?(view, "#telemetry-#{agent.id}-c1-detail", "lib/a.ex")

      turn =
        record_turn(ctx, %{
          "activity" => [
            %{
              "key" => "c1",
              "kind" => "tool",
              "status" => "ok",
              "category" => "read",
              "label" => "lib/a.ex"
            }
          ]
        })

      broadcast_status(channel.id, agent.id, :idle)

      refute has_element?(view, "#telemetry-#{agent.id}")
      assert has_element?(view, "#turn-#{turn.id}[data-open=true]")
      # its open row too, with the details the live card already held
      assert has_element?(view, "#turn-#{turn.id}-c1-detail", "lib/a.ex")

      # a card that was closed arrives closed
      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())
      next = record_turn(ctx, %{})
      broadcast_status(channel.id, agent.id, :idle)
      assert has_element?(view, "#turn-#{next.id}[data-open=false]")
    end

    test "a finished row opens to its stored details; an old turn says they weren't kept",
         ctx do
      %{channel: channel} = ctx
      turn = record_turn(ctx, %{})

      {:ok, _} =
        Canopy.Timeline.ActivityDetails.put(turn.id, %{
          "c1" => %{"input" => "mix test", "output" => "1) test fails\n42 tests, 1 failure"}
        })

      old = record_turn(ctx, %{})

      {:ok, view, _html} = open(conn_of(ctx), channel)
      view |> element("#turn-toggle-#{turn.id}") |> render_click()
      assert has_element?(view, "#turn-#{turn.id}-c1[data-status=ok]", "exit 1")
      assert has_element?(view, "#turn-#{turn.id}-c1", "0.9s")

      view |> element("#turn-#{turn.id}-c1-toggle") |> render_click()
      assert has_element?(view, "#turn-#{turn.id}-c1-toggle[aria-expanded=true]")
      assert has_element?(view, "#turn-#{turn.id}-c1-output-text", "42 tests, 1 failure")
      assert has_element?(view, "#turn-#{turn.id}-c1-command-text", "mix test")

      view |> element("#turn-#{turn.id}-c1-toggle") |> render_click()
      refute has_element?(view, "#turn-#{turn.id}-c1-detail")

      view |> element("#turn-toggle-#{old.id}") |> render_click()
      view |> element("#turn-#{old.id}-c1-toggle") |> render_click()
      assert has_element?(view, "#turn-#{old.id}-c1-detail", "recorded for turns before")
    end

    test "a file chip opens Changes on that file", ctx do
      %{channel: channel, repository: repository} = ctx
      path = Path.join(repository.path, "notes.txt")
      File.write!(path, "hello\n")

      turn =
        record_turn(ctx, %{
          "files" => [path],
          "activity_meta" => %{
            "v" => 2,
            "tallies" => %{"edit" => 1},
            "files" => [%{"path" => path, "adds" => 1, "dels" => 0}]
          }
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)
      view |> element("#turn-toggle-#{turn.id}") |> render_click()

      view
      |> element("#turn-#{turn.id}-files button[phx-value-path='notes.txt']")
      |> render_click()

      assert has_element?(view, "#changes-modal")
      assert has_element?(view, "#changed-files .text-primary", "notes.txt")
      assert has_element?(view, "#file-diff", "+hello")
    end

    test "?activity= opens the side panel; ?thread= replaces it", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      turn = record_turn(ctx, %{})
      {:ok, root} = Messages.post_user_message(channel.id, user.id, "a thread")

      {:ok, view, _html} = live(conn_of(ctx), ChannelLive.activity_path(channel.id, turn.id))
      assert has_element?(view, "#activity-panel", "@#{agent.name}")
      assert has_element?(view, "#panel-turn-#{turn.id}-c1", "mix test")
      assert has_element?(view, "#activity-panel-text", "mix test")
      # the card in the feed is marked as the one in the panel
      assert has_element?(view, "#turn-#{turn.id}.ring-2")

      render_patch(view, ChannelLive.thread_path(channel.id, root.id))
      assert has_element?(view, "#thread-panel")
      refute has_element?(view, "#activity-panel")
      refute has_element?(view, "#turn-#{turn.id}.ring-2")

      render_patch(view, ChannelLive.activity_path(channel.id, turn.id))
      assert has_element?(view, "#activity-panel")
      refute has_element?(view, "#thread-panel")

      render_patch(view, ~p"/channels/#{channel.id}")
      refute has_element?(view, "#activity-panel")

      # an id from elsewhere is refused
      render_patch(view, ChannelLive.activity_path(channel.id, "evt_nope"))
      refute has_element?(view, "#activity-panel")
    end

    test "a live turn in the panel moves to the finished turn when it ends", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())

      view |> element("#telemetry-#{agent.id}-panel") |> render_click()
      assert_patch(view, ChannelLive.activity_path(channel.id, "live:" <> agent.id))
      assert has_element?(view, "#activity-panel #panel-telemetry-#{agent.id}-c1", "lib/a.ex")
      assert has_element?(view, "#telemetry-#{agent.id}.ring-2")

      turn = record_turn(ctx, %{})
      assert_patch(view, ChannelLive.activity_path(channel.id, turn.id))
      assert has_element?(view, "#activity-panel #panel-turn-#{turn.id}-c1", "mix test")
    end

    test "in the compact timeline an agent's reply carries a receipt that opens the panel",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      {:ok, message} = Messages.post_agent_message(channel.id, agent.id, "Fixed it.")
      refute has_element?(view, "#message-receipt-#{message.id}")

      turn =
        record_turn(ctx, %{"message_ids" => [message.id], "tools" => 14, "duration_ms" => 185_000})

      assert has_element?(view, "#message-receipt-#{message.id}", "14 tools · 3m 5s")

      view |> element("#message-receipt-#{message.id}") |> render_click()
      assert_patch(view, ChannelLive.activity_path(channel.id, turn.id))
      assert has_element?(view, "#activity-panel")

      # a reload builds the same receipt from the stored turn
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#message-receipt-#{message.id}")
    end

    test "this browser can open live cards by itself", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      render_hook(view, "pref", %{"key" => "activity-open-live", "value" => "true"})
      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())
      assert has_element?(view, "#telemetry-#{agent.id}[data-open=true]")
      assert has_element?(view, "#telemetry-#{agent.id}-auto-open[checked]")

      # once closed, it stays closed while the turn runs
      view |> element("#telemetry-toggle-#{agent.id}") |> render_click()

      broadcast_telemetry(
        channel.id,
        agent.id,
        :tool_completed,
        Map.put(tool_data(), :status, :ok)
      )

      assert has_element?(view, "#telemetry-#{agent.id}[data-open=false]")
    end

    test "a turn waiting on a card says so on its live card", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())
      broadcast_status(channel.id, agent.id, :awaiting_user)

      assert has_element?(view, "#telemetry-#{agent.id}[data-status=awaiting_user]")
      assert has_element?(view, "#telemetry-toggle-#{agent.id}", "is waiting for you")
    end
  end

  describe "reactions" do
    test "the picker offers five emoji; a pick adds the user's chip and a click removes it",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, post} = Messages.post_agent_message(channel.id, agent.id, "Merged the fix.")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#react-#{post.id}")
      refute has_element?(view, "#reactions-#{post.id}")

      for key <- ~w(thumbs_up check eyes tada heart) do
        assert has_element?(view, "#react-picker-#{post.id} #react-picker-#{post.id}-#{key}")
      end

      view |> element("#react-picker-#{post.id}-check") |> render_click()
      chip = "#reaction-#{post.id}-check"
      assert has_element?(view, "#{chip}[data-mine=true][aria-pressed=true]", "1")
      assert has_element?(view, "#{chip}[title='You: done / approved']")
      assert [%{emoji: "check"}] = Messages.get!(post.id).reactions

      view |> element(chip) |> render_click()
      refute has_element?(view, chip)
      refute has_element?(view, "#reactions-#{post.id}")
      assert Messages.get!(post.id).reactions == []
    end

    test "an agent's reaction appears live, named in the chip's title, and marks nothing", ctx do
      %{channel: channel, reviewer: reviewer, user: user} = ctx
      {:ok, mine} = Messages.post_user_message(channel.id, user.id, "Ship it after CI?")

      {:ok, view, _html} = open(conn_of(ctx), channel)

      read_at = fn ->
        Canopy.Repo.get_by!(Canopy.Unread.ChannelRead, channel_id: channel.id).last_read_at
      end

      before = read_at.()
      {:ok, :added} = Canopy.Reactions.add(mine.id, {:agent, reviewer.id}, "eyes")
      {:ok, :added} = Canopy.Reactions.add(mine.id, {:user, user.id}, "eyes")

      chip = "#reaction-#{mine.id}-eyes"
      assert has_element?(view, chip, "2")
      assert has_element?(view, "#{chip}[title='@#{reviewer.name}, You: looking at it']")
      # still once in the feed: redrawn in place, not appended
      assert view |> render() |> String.split(~s(id="message-#{mine.id}")) |> length() == 2
      # a reaction is no event: the channel is not marked read again
      assert read_at.() == before
    end

    test "a reaction on a thread reply renders inside the open thread", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer, user: user} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")
      {:ok, reply} = Messages.thread_reply(root.id, {:agent, reviewer.id}, "390px")

      {:ok, view, _html} = live(conn_of(ctx), ChannelLive.thread_path(channel.id, root.id))
      assert has_element?(view, "#thread-msg-react-#{reply.id}")

      view |> element("#thread-msg-react-picker-#{reply.id}-thumbs_up") |> render_click()
      assert has_element?(view, "#thread-replies #thread-msg-reaction-#{reply.id}-thumbs_up", "1")
      # the reply is not in the feed, so nothing was added there
      refute has_element?(view, "#timeline #message-#{reply.id}")

      {:ok, :added} = Canopy.Reactions.add(root.id, {:user, user.id}, "tada")
      # the root shows in both places; each copy redraws
      assert has_element?(view, "#timeline #reaction-#{root.id}-tada")
      assert has_element?(view, "#thread-replies #thread-msg-reaction-#{root.id}-tada")
    end

    test "no React on system notes or in archived channels; chips there do not toggle", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, post} = Messages.post_agent_message(channel.id, agent.id, "Done.")
      {:ok, note} = Messages.post_user_note(channel.id, user.id, "handed off")
      {:ok, :added} = Canopy.Reactions.add(post.id, {:user, user.id}, "check")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#react-#{note.id}")
      assert has_element?(view, "#react-#{post.id}")

      {:ok, _} = Canopy.Channels.archive(channel)
      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#react-#{post.id}")
      assert has_element?(view, "#reaction-#{post.id}-check[disabled]")

      # a stale page still asking is refused with a flash
      html = render_hook(view, "toggle_reaction", %{"id" => post.id, "emoji" => "check"})
      assert html =~ "archived; it takes no reactions"
      assert [%{emoji: "check"}] = Messages.get!(post.id).reactions
    end

    test "a message from another channel is refused; one outside the loaded page is ignored",
         ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      other = Fixtures.channel_fixture(%{repository_id: ctx.repository.id})
      {:ok, elsewhere} = Messages.post_agent_message(other.id, agent.id, "elsewhere")
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
      {:ok, hidden} = Messages.thread_reply(root.id, {:agent, agent.id}, "only in the thread")

      {:ok, view, _html} = open(conn_of(ctx), channel)

      html = render_hook(view, "toggle_reaction", %{"id" => elsewhere.id, "emoji" => "check"})
      assert html =~ "That message is not in this channel."
      assert Messages.get!(elsewhere.id).reactions == []

      # the thread is closed: its reply is loaded nowhere
      {:ok, :added} = Canopy.Reactions.add(hidden.id, {:user, user.id}, "check")
      refute has_element?(view, "#message-#{hidden.id}")
      refute has_element?(view, "#thread-msg-#{hidden.id}")
      assert has_element?(view, "#message-#{root.id}")
    end
  end

  describe "threads" do
    defp open_thread(conn, channel, root_id, extra \\ %{}) do
      live(conn, ChannelLive.thread_path(channel.id, root_id, extra[:reply]))
    end

    test "the summary row shows the count and who replied, and opens the panel", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer, user: user} = ctx

      {:ok, root} =
        Messages.post_agent_message(channel.id, agent.id, "Which width should we use?")

      {:ok, first} = Messages.thread_reply(root.id, {:agent, reviewer.id}, "390px")
      {:ok, second} = Messages.thread_reply(root.id, {:user, user.id}, "agreed")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      summary = "#thread-summary-#{root.id}"
      assert has_element?(view, summary, "2 replies")
      assert has_element?(view, "#{summary} [title='@#{reviewer.name}']")
      assert has_element?(view, "#{summary} [title='@#{agent.name}']")
      refute has_element?(view, "#thread-panel")

      view |> element(summary) |> render_click()
      assert_patch(view, ChannelLive.thread_path(channel.id, root.id))

      assert has_element?(view, "#thread-panel #thread-msg-#{root.id}", "Which width")
      assert has_element?(view, "#thread-replies #thread-msg-#{first.id}", "390px")
      assert has_element?(view, "#thread-replies #thread-msg-#{second.id}", "agreed")
      assert has_element?(view, "#thread-divider", "2 replies")
      # the open thread's summary row is marked in the feed
      assert has_element?(view, "#{summary}[data-open=true]")
      refute has_element?(view, "#timeline #message-#{first.id}")

      view |> element("#thread-panel-close") |> render_click()
      assert_patch(view, ~p"/channels/#{channel.id}")
      refute has_element?(view, "#thread-panel")
    end

    test "Reply in thread opens the panel on a message without replies yet", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      refute has_element?(view, "#thread-summary-#{root.id}")
      view |> element("#reply-#{root.id}") |> render_click()

      assert has_element?(view, "#thread-panel #thread-msg-#{root.id}")
      assert has_element?(view, "#thread-divider", "0 replies")
      assert has_element?(view, "#thread-composer-form")
    end

    test "a reply from the thread composer lands in the thread and the panel stays open", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)

      view
      |> form("#thread-composer-form", %{"message" => %{"body" => "390px"}})
      |> render_submit()

      assert [^root, reply] = Messages.list_thread(root.id)
      assert reply.body == "390px"
      assert reply.thread_id == root.id
      assert reply.kind == "thread_reply"
      assert reply.user_id == user.id
      refute reply.sent_to_channel

      assert has_element?(view, "#thread-panel #thread-msg-#{reply.id}", "390px")
      assert has_element?(view, "#thread-composer-form")
      refute has_element?(view, "#timeline #message-#{reply.id}")
      assert has_element?(view, "#thread-summary-#{root.id}", "1 reply")

      # the next reply needs no second click
      view
      |> form("#thread-composer-form", %{"message" => %{"body" => "and 768px"}})
      |> render_submit()

      assert length(Messages.list_thread(root.id)) == 3
    end

    test "Also send to channel shows the reply in the thread and in the feed", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)

      view
      |> form("#thread-composer-form", %{
        "message" => %{"body" => "Going with 390px"},
        "also_send" => "true"
      })
      |> render_submit()

      assert [_, %{sent_to_channel: true} = reply] = Messages.list_thread(root.id)
      assert has_element?(view, "#thread-replies #thread-msg-#{reply.id}", "also in channel")
      assert has_element?(view, "#timeline #message-#{reply.id}", "Going with 390px")
      assert has_element?(view, "#message-parent-#{reply.id}", "Which width?")
    end

    test "?thread= opens a thread older than the loaded feed; an unknown one says so", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "an old question")
      {:ok, reply} = Messages.thread_reply(root.id, {:agent, agent.id}, "an old answer")
      for n <- 1..105, do: {:ok, _} = Messages.post_agent_message(channel.id, agent.id, "n#{n}")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)
      refute has_element?(view, "#timeline #message-#{root.id}")
      assert has_element?(view, "#thread-panel #thread-msg-#{root.id}", "an old question")
      assert has_element?(view, "#thread-panel #thread-msg-#{reply.id}", "an old answer")

      # a link to a reply opens its thread and marks that reply
      {:ok, view, _html} = open_thread(conn_of(ctx), channel, reply.id)
      assert has_element?(view, "#thread-panel #thread-msg-#{root.id}")
      assert has_element?(view, "[data-scroll-target] #thread-msg-#{reply.id}.message-target")

      other = Fixtures.channel_fixture(%{repository_id: ctx.repository.id, name: "elsewhere"})
      {:ok, elsewhere} = Messages.post_agent_message(other.id, agent.id, "not here")

      for id <- ["msg_unknown", elsewhere.id] do
        {:ok, view, html} = open_thread(conn_of(ctx), channel, id)
        refute has_element?(view, "#thread-panel")
        assert html =~ "That thread is not in this channel."
      end
    end

    test "a thread turn's summary lands in the panel, not in the feed", ctx do
      %{channel: channel, agent: agent, session: session} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)

      {:ok, turn} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          ref_id: session.id,
          thread_id: root.id,
          in_channel: false,
          payload: %{"outcome" => "error", "tools" => 2, "thread_id" => root.id}
        })

      assert has_element?(view, "#thread-replies #thread-evt-#{turn.id}", "stopped with an error")
      refute has_element?(view, "#timeline #evt-#{turn.id}")
    end

    test "the live card of a thread turn shows in the panel; the summary row says who is replying",
         ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
      {:ok, _} = Messages.thread_reply(root.id, {:user, user.id}, "and?")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      send_turn_thread(channel.id, agent.id, root.id)
      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())

      # the thread is not open: only the summary row shows the work
      assert has_element?(view, "#thread-working-#{root.id}", "@#{agent.name} is replying")
      refute has_element?(view, "#telemetry-#{agent.id}")

      view |> element("#thread-summary-#{root.id}") |> render_click()
      assert has_element?(view, "#thread-panel #telemetry-#{agent.id}")
      refute has_element?(view, "#timeline-scroll > #telemetry-#{agent.id}")

      # the turn ends: the row goes back to the last reply time
      send_turn_thread(channel.id, agent.id, nil)
      broadcast_status(channel.id, agent.id, :idle)
      refute has_element?(view, "#thread-working-#{root.id}")
      refute has_element?(view, "#telemetry-#{agent.id}")

      # a channel turn's card stays in the feed
      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())
      assert has_element?(view, "#timeline-scroll > #telemetry-#{agent.id}")
    end

    test "a question raised by a thread turn shows in that thread's panel", ctx do
      %{channel: channel, agent: agent, session: session} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, request} =
        QuestionRequests.record(%{
          channel_id: channel.id,
          agent_session_id: session.id,
          opencode_question_id: "que_thread",
          questions: [%{"question" => "Which key?", "options" => [%{"label" => "A"}]}],
          status: "pending"
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)
      send_turn_thread(channel.id, agent.id, root.id)
      assert has_element?(view, "#timeline-scroll > #question-#{request.id}")

      view |> element("#reply-#{root.id}") |> render_click()
      assert has_element?(view, "#thread-panel #question-#{request.id}")
      refute has_element?(view, "#timeline-scroll > #question-#{request.id}")
    end

    test "an unread dot marks a followed thread with new replies; opening it clears it", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, root} = Messages.post_user_message(channel.id, user.id, "my question")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      # the user wrote the root, so an agent's reply makes the thread followed and unread
      {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "an answer")
      assert has_element?(view, "#thread-unread-#{root.id}")
      assert has_element?(view, "#rail-threads-badge", "1")

      view |> element("#thread-summary-#{root.id}") |> render_click()
      refute has_element?(view, "#thread-unread-#{root.id}")
      refute has_element?(view, "#rail-threads-badge")

      # a reply while the panel is open is read as it arrives
      {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "one more")
      refute has_element?(view, "#thread-unread-#{root.id}")
      refute has_element?(view, "#rail-threads-badge")
    end

    test "the bell follows and unfollows the thread", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)
      assert has_element?(view, "#thread-follow[data-following=false]")

      view |> element("#thread-follow") |> render_click()
      assert has_element?(view, "#thread-follow[data-following=true]")
      assert Canopy.Threads.following?(root.id, user)

      view |> element("#thread-follow") |> render_click()
      assert has_element?(view, "#thread-follow[data-following=false]")
      refute Canopy.Threads.following?(root.id, user)

      # an explicit unfollow survives an agent's reply that mentions the user
      {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "@#{user.display_name} ping")
      refute Canopy.Threads.following?(root.id, user)
    end

    test "Esc (the SidePanel hook) closes the panel", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)
      assert has_element?(view, "#thread-panel[phx-hook=SidePanel]")

      view |> element("#thread-panel") |> render_hook("close_panel", %{})
      assert_patch(view, ~p"/channels/#{channel.id}")
      refute has_element?(view, "#thread-panel")
    end

    test "a &reply= link to a reply in the thread marks it; one from another thread does not",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
      {:ok, first} = Messages.thread_reply(root.id, {:agent, agent.id}, "first")
      {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "second")
      {:ok, other} = Messages.post_agent_message(channel.id, agent.id, "other root")
      {:ok, elsewhere} = Messages.thread_reply(other.id, {:agent, agent.id}, "elsewhere")

      # the shape every Copy link builds: ?thread=<root>&reply=<id>
      link = ChannelLive.thread_path(channel.id, root.id, first.id)
      assert %URI{path: path, query: query} = URI.parse(link)
      assert path == "/channels/#{channel.id}"
      assert URI.decode_query(query) == %{"thread" => root.id, "reply" => first.id}

      {:ok, view, _html} = live(conn_of(ctx), link)
      assert has_element?(view, "[data-scroll-target] #thread-msg-#{first.id}.message-target")

      {:ok, view, _html} =
        live(conn_of(ctx), ChannelLive.thread_path(channel.id, root.id, elsewhere.id))

      assert has_element?(view, "#thread-panel #thread-msg-#{root.id}")
      refute has_element?(view, "[data-scroll-target]")
    end

    @png File.read!(Path.expand("../../support/files/red.png", __DIR__))

    test "another thread starts with an empty composer; the same thread keeps it", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, a} = Messages.post_agent_message(channel.id, agent.id, "thread a")
      {:ok, a_reply} = Messages.thread_reply(a.id, {:agent, agent.id}, "in a")
      {:ok, b} = Messages.post_agent_message(channel.id, agent.id, "thread b")

      {:ok, doc} =
        Canopy.Documents.create(%{
          filename: "notes.md",
          source: {:binary, "# notes"},
          user_id: user.id
        })

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, a.id)
      assert has_element?(view, "#thread-composer-form[data-scope='#{a.id}']")
      assert has_element?(view, "#thread-scroll[data-scope='#{a.id}']")

      view |> element("#thread-composer-library") |> render_click()
      view |> element("#library-#{doc.id}") |> render_click()
      assert has_element?(view, "#thread-composer-picked-#{doc.id}")
      refute has_element?(view, "#picked-#{doc.id}")

      upload =
        file_input(view, "#thread-composer-upload-form", :thread_files, [
          %{name: "shot.png", content: @png, type: "image/png"}
        ])

      render_upload(upload, "shot.png")
      assert has_element?(view, "#thread-composer-files [id^=thread-composer-upload-]")

      # a link to a reply of the same thread keeps what is in the composer
      render_patch(view, ChannelLive.thread_path(channel.id, a.id, a_reply.id))
      assert has_element?(view, "#thread-composer-picked-#{doc.id}")
      assert has_element?(view, "#thread-composer-files [id^=thread-composer-upload-]")

      # another thread: the picks and uploads go, and the hook drops the draft
      render_patch(view, ChannelLive.thread_path(channel.id, b.id))
      refute has_element?(view, "#thread-composer-picked-#{doc.id}")
      refute has_element?(view, "#thread-composer-files")
      assert has_element?(view, "#thread-composer-form[data-scope='#{b.id}']")
      assert has_element?(view, "#thread-scroll[data-scope='#{b.id}']")
    end

    test "the bell shows the follow your own reply made", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)
      assert has_element?(view, "#thread-follow[data-following=false]")

      view
      |> form("#thread-composer-form", %{"message" => %{"body" => "count me in"}})
      |> render_submit()

      assert has_element?(view, "#thread-follow[data-following=true]")

      # the next click unfollows: it reads what is stored, not what was shown
      view |> element("#thread-follow") |> render_click()
      refute Canopy.Threads.following?(root.id, user)
      assert has_element?(view, "#thread-follow[data-following=false]")
    end

    test "a thread read or followed elsewhere updates the dots, the badge, and the bell", ctx do
      %{channel: channel, agent: agent, user: user} = ctx
      {:ok, root} = Messages.post_user_message(channel.id, user.id, "mine")
      {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "an answer")
      {:ok, other} = Messages.post_agent_message(channel.id, agent.id, "other")

      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#thread-unread-#{root.id}")
      assert has_element?(view, "#rail-threads-badge", "1")

      # another tab (here, the test process) reads the thread
      :ok = Canopy.Threads.mark_read(root.id, user)
      refute has_element?(view, "#thread-unread-#{root.id}")
      refute has_element?(view, "#rail-threads-badge")

      # and follows the open thread elsewhere: the bell follows
      view |> element("#reply-#{other.id}") |> render_click()
      assert has_element?(view, "#thread-follow[data-following=false]")
      :ok = Canopy.Threads.follow(other.id, user, true)
      assert has_element?(view, "#thread-follow[data-following=true]")
    end

    test "a deleted document leaves both composers, and a reply outside the panel's window stays out",
         ctx do
      %{channel: channel, agent: agent, user: user} = ctx

      {:ok, picked} =
        Canopy.Documents.create(%{filename: "p.md", source: {:binary, "p"}, user_id: user.id})

      {:ok, attached} =
        Canopy.Documents.create(%{filename: "a.md", source: {:binary, "a"}, user_id: user.id})

      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, oldest} =
        Messages.thread_reply(root.id, {:agent, agent.id}, "old", attachments: [attached.id])

      for n <- 1..200, do: {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "r#{n}")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)
      refute has_element?(view, "#thread-msg-#{oldest.id}")

      view |> element("#thread-composer-library") |> render_click()
      view |> element("#library-#{picked.id}") |> render_click()
      assert has_element?(view, "#thread-composer-picked-#{picked.id}")

      {:ok, _} = Canopy.Documents.delete(picked)
      {:ok, _} = Canopy.Documents.delete(attached)
      _ = render(view)

      refute has_element?(view, "#thread-composer-picked-#{picked.id}")
      refute has_element?(view, "#thread-msg-#{oldest.id}")
    end

    test "a thread's turn line costs the panel no thread queries; a reply only a few", ctx do
      %{channel: channel, agent: agent, session: session} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")
      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)

      test_pid = self()
      handler = "thread-queries-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:canopy, :repo, :query],
        fn _event, _measure, meta, _ -> send(test_pid, {:query, self(), meta.source}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_started",
          ref_id: session.id,
          thread_id: root.id,
          in_channel: false,
          payload: %{}
        })

      _ = render(view)
      assert view_queries(view.pid) == []

      {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "a reply")
      _ = render(view)
      queries = view_queries(view.pid)
      # one summary (counts, last reply, participants), the read mark, the
      # follow state, the root's row, and the unread map Nav refreshes once
      assert Enum.count(queries, &(&1 == "thread_reads")) <= 3
      assert length(queries) <= 12
    end

    test "a command cannot be sent in a thread", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "root")

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)

      html =
        view
        |> form("#thread-composer-form", %{
          "message" => %{"body" => "/handoff @#{agent.name} take it"}
        })
        |> render_submit()

      assert html =~ "commands cannot be sent in a thread"
      assert [_root] = Messages.list_thread(root.id)
    end
  end

  defp view_queries(pid) do
    receive do
      {:query, ^pid, source} -> [source | view_queries(pid)]
      {:query, _other, _source} -> view_queries(pid)
    after
      0 -> []
    end
  end

  defp send_turn_thread(channel_id, agent_id, thread_id) do
    :ok =
      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        Timeline.topic(channel_id),
        {:turn_thread, agent_id, thread_id}
      )
  end

  defp tool_data do
    %{
      call_id: "c1",
      tool: "read",
      status: :running,
      input: %{"filePath" => "lib/a.ex"},
      title: nil,
      message_id: "m",
      part_id: "p1"
    }
  end

  describe "questions" do
    defp ask_question(ctx, opts \\ []) do
      QuestionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.session.id,
        opencode_question_id: "que_live_1",
        questions: [
          %{
            "header" => "Mobile screenshots",
            "question" => "How should dense screenshots behave at 390px?",
            "options" => [
              %{"label" => "Keep as is", "description" => "Accept unreadable UI text."},
              %{"label" => "Add mobile crops", "description" => "Focused close-ups."}
            ],
            "custom" => Keyword.get(opts, :custom, false)
          }
        ],
        tool_call_id: "call_1",
        status: "pending"
      })
    end

    test "a pending question renders its options and sends the chosen label", ctx do
      {:ok, request} = ask_question(ctx)

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, "#question-#{request.id}", "How should dense screenshots")
      assert has_element?(view, "#question-#{request.id}", "Accept unreadable UI text.")

      assert has_element?(
               view,
               ~s(#question-#{request.id} input[type="radio"][value="Add mobile crops"])
             )

      expect(OC, :reply_question, fn _dir, "que_live_1", [["Add mobile crops"]], _opts ->
        {:ok, true}
      end)

      view
      |> form("#question-#{request.id} form", %{"answers" => %{"0" => ["Add mobile crops"]}})
      |> render_submit()

      refute has_element?(view, "#question-#{request.id}")

      assert %{status: "answered", answers: [["Add mobile crops"]]} =
               QuestionRequests.get!(request.id)
    end

    test "a question that allows free text sends what was typed", ctx do
      {:ok, request} = ask_question(ctx, custom: true)

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, ~s(#question-#{request.id} input[name="custom[0]"]))

      expect(OC, :reply_question, fn _dir, "que_live_1", [["crop the tall ones only"]], _opts ->
        {:ok, true}
      end)

      view
      |> form("#question-#{request.id} form", %{"custom" => %{"0" => "crop the tall ones only"}})
      |> render_submit()

      assert QuestionRequests.get!(request.id).status == "answered"
    end

    test "submitting with nothing chosen keeps the card and says so", ctx do
      {:ok, request} = ask_question(ctx)

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      html = view |> form("#question-#{request.id} form", %{}) |> render_submit()

      assert html =~ "Answer every question before sending"
      assert has_element?(view, "#question-#{request.id}")
      assert QuestionRequests.get!(request.id).status == "pending"
    end

    test "Send stays disabled until an option is picked or words are typed", ctx do
      {:ok, request} = ask_question(ctx, custom: true)
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      assert has_element?(view, "#question-#{request.id}-send[disabled]")
      # Dismiss is a neutral ghost button, not a red one
      assert has_element?(view, "#question-#{request.id}-dismiss.btn-ghost")
      refute has_element?(view, "#question-#{request.id}-dismiss.text-error")
      # no grey subtitle repeating the heading
      refute has_element?(view, "#question-#{request.id}", "Mobile screenshots")

      view
      |> form("#question-#{request.id} form", %{"answers" => %{"0" => ["Keep as is"]}})
      |> render_change()

      refute has_element?(view, "#question-#{request.id}-send[disabled]")
      # the pick survives a re-render
      assert has_element?(view, ~s(#question-#{request.id} input[value="Keep as is"][checked]))

      # cleared again (only blanks): disabled again
      render_change(view, "question_draft", %{
        "request_id" => request.id,
        "custom" => %{"0" => " "}
      })

      assert has_element?(view, "#question-#{request.id}-send[disabled]")

      view
      |> form("#question-#{request.id} form", %{"custom" => %{"0" => "crop them"}})
      |> render_change()

      refute has_element?(view, "#question-#{request.id}-send[disabled]")
    end

    test "while the turn waits on the question, its live card and the question are one card",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, request} = ask_question(ctx)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      broadcast_telemetry(channel.id, agent.id, :tool_started, tool_data())
      broadcast_status(channel.id, agent.id, :awaiting_user)

      # the question's form lives inside the live card, whose header asks
      assert has_element?(view, "#telemetry-#{agent.id} #question-#{request.id} form")
      assert has_element?(view, "#telemetry-toggle-#{agent.id}", "needs a decision to carry on")
      refute has_element?(view, "#timeline-scroll > #question-#{request.id}")
      feed = view |> element("#timeline-scroll") |> render()
      assert length(Regex.scan(~r/needs a decision/, feed)) == 1
    end

    test "Dismiss rejects the question", ctx do
      {:ok, request} = ask_question(ctx)

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      expect(OC, :reject_question, fn _dir, "que_live_1", _opts -> {:ok, true} end)

      view |> element("#question-#{request.id}-dismiss") |> render_click()

      refute has_element?(view, "#question-#{request.id}")
      assert QuestionRequests.get!(request.id).status == "rejected"
    end

    test "every question takes an answer in the user's own words, and text alone answers it",
         ctx do
      coder =
        Fixtures.agent_fixture(%{name: "coder#{Fixtures.unique_suffix()}", engine: "claude_code"})

      {:ok, _} = Canopy.Channels.add_agent(ctx.channel, coder)

      session =
        Fixtures.session_fixture(%{
          channel: ctx.channel,
          agent_id: coder.id,
          engine: "claude_code",
          engine_session_id: Ecto.UUID.generate(),
          mcp_token: Canopy.AgentSessions.generate_mcp_token()
        })

      questions = [
        %{
          "question" => "Which color?",
          "options" => [%{"label" => "Red"}, %{"label" => "Blue"}],
          "multiple" => false,
          "custom" => true
        },
        %{"question" => "Anything else?", "options" => [], "multiple" => false, "custom" => true}
      ]

      # the Claude Code tool call that asked is still waiting
      id = "toolu_live_" <> Fixtures.unique_suffix()
      :ok = Prompts.open(id, :question, session.engine_session_id, %{"id" => id})
      on_exit(fn -> Prompts.drop_session(session.engine_session_id) end)

      {:ok, request} =
        QuestionRequests.record(%{
          channel_id: ctx.channel.id,
          agent_session_id: session.id,
          opencode_question_id: id,
          questions: questions,
          status: "pending"
        })

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      assert has_element?(
               view,
               ~s(#question-#{request.id}-custom-0[placeholder="Or answer in your own words…"])
             )

      # a question with no options: the text box is the answer, and required
      assert has_element?(
               view,
               ~s(#question-#{request.id}-custom-1[placeholder="Your answer"][required])
             )

      view
      |> form("#question-#{request.id} form", %{
        "custom" => %{"0" => "Green, really", "1" => "ship it on Friday"}
      })
      |> render_submit()

      refute has_element?(view, "#question-#{request.id}")
      assert {:ok, {:answered, [["Green, really"], ["ship it on Friday"]]}} = Prompts.await(id)

      assert %{status: "answered", answers: [["Green, really"], ["ship it on Friday"]]} =
               QuestionRequests.get!(request.id)
    end

    test "a detached card says the agent stopped waiting; answering it posts the answer", ctx do
      {:ok, request} = ask_question(ctx)
      {:ok, request} = QuestionRequests.detach(request)
      test_pid = self()

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, "#question-#{request.id}-detached", "stopped waiting")
      refute has_element?(view, "#awaiting-bar")

      expect(OC, :reply_question, fn _dir, "que_live_1", _answers, _opts ->
        {:error, {:http, 404, %{}}}
      end)

      expect(OC, :prompt_async, fn _dir, _sid, body, _opts ->
        send(test_pid, {:woken, body})
        {:ok, ""}
      end)

      view
      |> form("#question-#{request.id} form", %{"answers" => %{"0" => ["Keep as is"]}})
      |> render_submit()

      assert_receive {:woken, %{parts: [%{text: text} | _]}}, 2_000
      assert text =~ "Answer to your question"
      assert text =~ "Keep as is"
      refute has_element?(view, "#question-#{request.id}")
      assert render(view) =~ "question (sent as a message)"
      assert has_element?(view, "#timeline", "@#{ctx.agent.name} Answer to your question")
    end

    test "answering a card in an archived channel says to unarchive it and keeps the card",
         ctx do
      {:ok, request} = ask_question(ctx)
      {:ok, _} = Canopy.Channels.archive(ctx.channel)

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      html =
        view
        |> form("#question-#{request.id} form", %{"answers" => %{"0" => ["Keep as is"]}})
        |> render_submit()

      assert html =~ "Unarchive (Reopen) the channel to answer"
      assert has_element?(view, "#question-#{request.id}")
      assert QuestionRequests.get!(request.id).status == "pending"
    end

    test "a banner says who is waiting on an answer and the composer knows it", ctx do
      {:ok, request} = ask_question(ctx)

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      assert has_element?(view, "#awaiting-bar", "@#{ctx.agent.name} is waiting on your answer")
      assert has_element?(view, ~s(#awaiting-bar a[href="#question-#{request.id}"]))
      assert has_element?(view, ~s(#composer-form[data-awaiting*="#{ctx.agent.name}"]))
      assert has_element?(view, "#composer-awaiting-hint")

      # once the agent stops waiting, the card stays but nobody is blocked
      {:ok, _} = QuestionRequests.detach(request)
      refute has_element?(view, "#awaiting-bar")
      assert has_element?(view, ~s(#composer-form[data-awaiting="[]"]))
      assert has_element?(view, "#question-#{request.id}")
    end

    test "a question in another channel shows a needs-you badge in the sidebar", ctx do
      other =
        Fixtures.channel_fixture(%{
          repository_id: ctx.repository.id,
          owner_agent_id: ctx.agent.id
        })

      other_session = Fixtures.session_fixture(%{channel: other, agent_id: ctx.agent.id})

      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      refute has_element?(view, "#attention-#{other.id}")

      {:ok, request} =
        QuestionRequests.record(%{
          channel_id: other.id,
          agent_session_id: other_session.id,
          opencode_question_id: "que_other_" <> Fixtures.unique_suffix(),
          questions: [%{"question" => "Go on?", "options" => [%{"label" => "Yes"}]}],
          status: "pending"
        })

      assert has_element?(view, "#attention-#{other.id}[data-attention='1']")

      {:ok, _} = QuestionRequests.resolve(request, :rejected)
      refute has_element?(view, "#attention-#{other.id}")
    end

    test "a member blocked on a card shows as waiting on you, and can still be aborted", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      details(view)

      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        Timeline.topic(ctx.channel.id),
        {:agent_status, ctx.agent.id, :awaiting_user}
      )

      assert has_element?(view, "#member-#{ctx.agent.id}-awaiting", "waiting on you")
      assert has_element?(view, ~s(#member-#{ctx.agent.id} [data-status="awaiting_user"]))
      assert has_element?(view, "#abort-#{ctx.agent.id}")
      refute has_element?(view, "#reset-session-#{ctx.agent.id}")
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
      details(view)
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
      details(view)

      view
      |> form("#handoff-#{handoff.id}-reject-form", %{reason: "not now"})
      |> render_submit()

      refute has_element?(view, "#handoff-#{handoff.id}")
      assert %{status: "rejected", rejection_reason: "not now"} = Handoffs.get!(handoff.id)
      assert has_element?(view, "#owner-badge", "@#{agent.name}")
      assert_receive {:agent_status, _previous_owner, :busy}, 2_000
    end

    test "the task form in Details › Task updates the task", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)
      refute has_element?(view, "#task-form")

      details(view)
      view |> element("#edit-task", "Edit") |> render_click()
      # one column in the narrow panel, with the read view and its Edit gone
      assert has_element?(view, "#details-task #task-panel #task-form")
      refute has_element?(view, "#task-title")
      refute has_element?(view, "#edit-task")

      view
      |> form("#task-form", task: %{title: "Ship retries", status: "working"})
      |> render_submit()

      assert has_element?(view, "#task-status", "working")
      assert has_element?(view, "#task-title", "Ship retries")
      refute has_element?(view, "#task-form")
    end
  end

  describe "stop all" do
    test "the header button aborts every turn and shows the stopped bar until Continue", ctx do
      %{channel: channel, agent: agent, session: session} = ctx
      Timeline.subscribe(channel.id)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      view
      |> form("#composer-form", message: %{body: "please look at retries"})
      |> render_submit()

      assert_receive {:agent_status, _, :busy}, 2_000
      details(view)
      assert has_element?(view, "#member-#{agent.id} #abort-#{agent.id}")

      sid = session.engine_session_id
      expect(OC, :abort, fn _dir, ^sid, _opts -> {:ok, true} end)
      view |> element("#stop-all") |> render_click()

      assert has_element?(view, "#flash-info", "Stopped: 1 turn aborted")
      assert has_element?(view, "#paused-bar", "Stopped.")
      refute has_element?(view, "#abort-#{agent.id}")
      assert Runtime.stopped?(channel.id)

      view |> element("#continue-chatter") |> render_click()
      refute has_element?(view, "#paused-bar")
      refute Runtime.stopped?(channel.id)
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
      refute has_element?(view, "#details-dot")

      {:ok, once} =
        Canopy.Schedules.create(%{
          channel_id: channel.id,
          agent_id: agent.id,
          created_by_agent_id: agent.id,
          instruction: "Check the deploy went out.",
          when: "2h"
        })

      # the Details button carries a dot while it is closed
      assert has_element?(view, "#details-dot.bg-primary[title='1 scheduled']")
      assert render(view) =~ "@#{agent.name} scheduled: once · Check the deploy went out."

      details(view)
      refute has_element?(view, "#details-dot")
      assert has_element?(view, "#schedule-count", "1 active")
      view |> element("#edit-schedules") |> render_click()
      assert has_element?(view, "#channel-schedules-#{once.id}", "Check the deploy went out.")
      assert has_element?(view, "#channel-schedules-#{once.id}", "in 2h")
      assert has_element?(view, "#channel-schedules-#{once.id}", "@#{agent.name}")

      view |> element("#cancel-schedule-#{once.id}") |> render_click()
      refute has_element?(view, "#channel-schedules-#{once.id}")
      refute has_element?(view, "#schedule-count")
      assert has_element?(view, "#edit-schedules", "none")
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

      # the browser's stored choice loads with Details closed
      assert has_element?(view, "#timeline-activity-pref[phx-hook=Pref]")

      details(view)
      assert has_element?(view, "#toggle-activity[role=switch][aria-checked=false]")
      view |> element("#toggle-activity") |> render_click()
      refute has_element?(view, "#timeline.timeline-compact")
      assert has_element?(view, "#toggle-activity[aria-checked=true]")
      assert_push_event(view, "pref", %{key: "timeline-activity", value: "full"})

      view
      |> element("#timeline-activity-pref")
      |> render_hook("pref", %{"key" => "timeline-activity", "value" => "compact"})

      assert has_element?(view, "#timeline.timeline-compact")
    end
  end

  describe "session reset" do
    test "the header button resets an idle member's session and says so on the timeline", ctx do
      %{channel: channel, agent: agent, session: session} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)

      # the confirmation names the agent's own engine
      assert has_element?(
               view,
               ~s(#reset-session-#{agent.id}[data-canopy-confirm*="fresh OpenCode session"])
             )

      view |> element("#reset-session-#{agent.id}") |> render_click()
      assert render(view) =~ "reset @#{agent.name}&#39;s session"
      assert Canopy.AgentSessions.get_root(channel.id, agent.id) == nil
      refute Canopy.Repo.get(Canopy.AgentSessions.AgentSession, session.id)

      # the old session stays readable from the line
      [reset] = Timeline.list(channel.id, types: ["session_reset"]) |> Enum.take(-1)

      assert view
             |> element("#line-#{reset.id}-transcript", "earlier transcript")
             |> render_click()
             |> follow_redirect(conn_of(ctx))
             |> then(fn {:ok, _view, html} -> html end) =~ "Transcript"
    end

    test "a Claude Code member's confirmation says Claude Code", ctx do
      coder =
        Fixtures.agent_fixture(%{
          name: "coder#{Fixtures.unique_suffix()}",
          engine: "claude_code"
        })

      channel =
        Fixtures.channel_fixture(%{
          repository_id: ctx.repository.id,
          owner_agent_id: coder.id
        })

      on_exit(fn -> Runtime.stop_channel(channel.id) end)
      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)

      assert has_element?(
               view,
               ~s(#reset-session-#{coder.id}[data-canopy-confirm*="fresh Claude Code session"])
             )
    end
  end

  describe "transcript links" do
    test "each agent row and an opened turn card link to the transcript", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer} = ctx

      {:ok, turn} =
        Timeline.record(%{
          channel_id: channel.id,
          agent_id: agent.id,
          event_type: "agent_turn_completed",
          payload: %{"tools" => 1, "outcome" => "ok", "final_text" => "Done."}
        })

      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)

      assert has_element?(
               view,
               ~s(#transcript-#{agent.id}[href="/channels/#{channel.id}/agents/#{agent.id}/transcript"])
             )

      assert has_element?(view, "#transcript-#{reviewer.id}")

      refute has_element?(view, "#turn-#{turn.id}-transcript")
      view |> element("#turn-toggle-#{turn.id}") |> render_click()

      assert has_element?(
               view,
               ~s(#turn-#{turn.id}-transcript[href="/channels/#{channel.id}/agents/#{agent.id}/transcript?turn=#{turn.id}"])
             )

      # and from the activity panel
      view |> element("#turn-#{turn.id}-panel") |> render_click()

      assert has_element?(
               view,
               ~s(#activity-panel-transcript[href="/channels/#{channel.id}/agents/#{agent.id}/transcript?turn=#{turn.id}"])
             )

      # the activity took the side panel; Details takes it back
      refute has_element?(view, "#details-panel")
      details(view)

      {:ok, _transcript, html} =
        view
        |> element("#transcript-#{agent.id}")
        |> render_click()
        |> follow_redirect(conn_of(ctx))

      assert html =~ "@#{agent.name} · Transcript"
    end
  end

  describe "members and archiving" do
    test "agents can be added and removed in Details › Agents; the owner cannot", ctx do
      %{channel: channel, agent: owner, reviewer: reviewer} = ctx
      newcomer = Fixtures.agent_fixture(%{name: "newcomer#{Fixtures.unique_suffix()}"})

      {:ok, view, _html} = open(conn_of(ctx), channel)
      view |> element("#agents-button") |> render_click()
      assert_push_event(view, "details:focus", %{section: "agents"})
      assert has_element?(view, "#details-agents", "Agents · 2")
      refute has_element?(view, "#members-panel")
      refute has_element?(view, "[id^=remove-member-]")

      view |> element("#edit-members", "Add or remove") |> render_click()
      assert has_element?(view, "#edit-members", "Done")
      assert has_element?(view, "#member-#{owner.id}", "owner")
      refute has_element?(view, "#remove-member-#{owner.id}")
      assert has_element?(view, "#remove-member-#{reviewer.id}")
      assert has_element?(view, "#add-member-select option[value='#{newcomer.id}']")

      view |> form("#add-member-form", agent_id: newcomer.id) |> render_submit()
      assert has_element?(view, "#member-#{newcomer.id}", "@#{newcomer.name}")
      refute has_element?(view, "#add-member-select option[value='#{newcomer.id}']")
      assert render(view) =~ "@#{newcomer.name} joined the channel"

      view |> element("#remove-member-#{reviewer.id}") |> render_click()
      refute has_element?(view, "#member-#{reviewer.id}")
      assert render(view) =~ "@#{reviewer.name} was removed from the channel"
      assert has_element?(view, "#add-member-select option[value='#{reviewer.id}']")

      # the composer suggests every active agent, member or not
      assert has_element?(view, "#composer-form[data-agents*='#{newcomer.name}']")
      assert has_element?(view, "#composer-form[data-agents*='#{reviewer.name}']")
    end

    test "a team is invited from the members panel, quietly, with one timeline line", ctx do
      %{channel: channel, reviewer: reviewer} = ctx
      newcomer = Fixtures.agent_fixture(%{name: "newcomer#{Fixtures.unique_suffix()}"})
      team = Fixtures.team_fixture([newcomer, reviewer], name: "crew#{Fixtures.unique_suffix()}")
      Timeline.subscribe(channel.id)

      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)
      view |> element("#edit-members") |> render_click()
      assert has_element?(view, "#invite-team-select option[value='#{team.id}']", "2 members")

      view |> form("#invite-team-form", team_id: team.id) |> render_submit()

      assert has_element?(
               view,
               "#flash-info",
               "Added @#{newcomer.name} (@#{reviewer.name} was already here)."
             )

      assert has_element?(view, "#member-#{newcomer.id}")
      assert_receive {:timeline, %{event_type: "team_added"}}, 2_000
      assert render(view) =~ "@#{team.name} joined: @#{newcomer.name}"
      # nobody was woken, and the team is no longer offered
      refute_receive {:timeline, %{event_type: "message"}}, 200
      refute has_element?(view, "#invite-team-form")
      assert Canopy.Channels.get!(channel.id).owner_agent_id == ctx.agent.id
    end

    test "Details › Spend sets and clears the spend limit; reaching it shows a bar", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#edit-budget", "$0.00")
      refute has_element?(view, "#budget-panel")

      # the header's $ opens Details on Spend, open
      view |> element("#edit-budget") |> render_click()
      assert has_element?(view, "#edit-budget-row[aria-expanded=true]")
      assert has_element?(view, "#details-panel #budget-panel #budget-form")
      assert has_element?(view, "#budget-spent", "$0.00 · no limit")
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
      assert has_element?(view, "#budget-panel")
      assert has_element?(view, "#edit-budget-row .text-error #budget-spent", "$3.00 of $2.50")
      view |> element("#clear-spend-limit") |> render_click()
      refute has_element?(view, "#limit-bar")
      assert has_element?(view, "#edit-budget", "$3.00")
      refute has_element?(view, "#edit-budget", "/")
      assert render(view) =~ "removed this channel&#39;s spend limit"
    end

    test "archiving hides the composer, marks the sidebar, and reopening restores it", ctx do
      %{channel: channel} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)

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

    test "the header is one row of chips and buttons; the rest lives in Details", ctx do
      %{channel: channel} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      assert has_element?(view, "#channel-header[phx-hook=HeaderFit][data-fit='']")
      refute has_element?(view, "#channel-more")
      refute has_element?(view, "#channel-header #archive-channel")

      for id <- ~w(search-channel edit-members toggle-activity edit-locks edit-playbook
                   edit-schedules edit-brief edit-task owner-badge members) do
        refute has_element?(view, "#channel-header ##{id}")
      end

      # Stop keeps its label longest; Changes and Details drop theirs first
      assert has_element?(view, "#stop-all[data-hdr=stop]")
      assert has_element?(view, "#open-changes[data-hdr=rest]")

      assert has_element?(
               view,
               "#toggle-details[data-hdr=rest][aria-expanded=false][aria-controls=details-panel]"
             )

      for id <- ~w(agents-button edit-budget open-changes stop-all) do
        assert has_element?(view, "##{id}[aria-label][title]")
      end

      details(view)
      assert has_element?(view, "#toggle-details.btn-active[aria-expanded=true]")

      for id <- ~w(details-task details-agents details-locks details-automation details-view) do
        assert has_element?(view, "#details-body > ##{id}")
      end

      assert has_element?(view, "#details-view #archive-channel[data-canopy-confirm]")
      assert has_element?(view, "#details-panel-close[phx-click=close_panel]")
    end

    test "an archived channel's header offers Reopen; Details has no Archive", ctx do
      %{channel: channel} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)

      view |> element("#archive-channel") |> render_click()
      refute has_element?(view, "#archive-channel")
      refute has_element?(view, "#stop-all")
      assert has_element?(view, "#channel-header-actions > #reopen-channel[data-hdr=stop]")
    end

    test "a reply sent to the channel quotes its parent as plain text", ctx do
      %{channel: channel, agent: agent} = ctx

      {:ok, root} =
        Messages.post_agent_message(
          channel.id,
          agent.id,
          "**Root cause.** The `claim` step:\n\n- runs late"
        )

      {:ok, view, _html} = open_thread(conn_of(ctx), channel, root.id)

      view
      |> form("#thread-composer-form", %{
        "message" => %{"body" => "Agreed"},
        "also_send" => "true"
      })
      |> render_submit()

      assert [_, reply] = Messages.list_thread(root.id)
      parent = element(view, "#message-parent-#{reply.id}")
      assert render(parent) =~ "Root cause. The claim step: runs late"
      refute render(parent) =~ "**"
      refute render(parent) =~ "`"
    end

    test "a DM's header switches its repository and the timeline says so", ctx do
      %{agent: agent, repository: repository} = ctx
      other = Fixtures.repository_fixture(%{name: "calc"})
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)
      {:ok, view, _html} = open(conn_of(ctx), dm)
      details(view)

      assert has_element?(
               view,
               "#details-task #dm-repository option[value='#{repository.id}'][selected]"
             )

      view |> form("#dm-repository-form", %{"repository_id" => other.id}) |> render_change()
      assert Canopy.Channels.get!(dm.id).repository_id == other.id
      assert has_element?(view, "#dm-repository option[value='#{other.id}'][selected]")
      assert render(view) =~ "moved this conversation to calc"
      assert has_element?(view, "#sidebar-dm-#{dm.id}[title*=calc]")

      # the locks shown follow it to the new repository, live
      {:granted, _} = Canopy.Locks.acquire(ctx.session, other.id, "deploy", nil)
      assert has_element?(view, "#lock-chip-deploy")
    end

    test "a DM has no agents button, and no Add or remove", ctx do
      %{agent: agent, repository: repository} = ctx
      {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)
      {:ok, view, _html} = open(conn_of(ctx), dm)
      refute has_element?(view, "#agents-button")
      details(view)
      refute has_element?(view, "#edit-members")
      refute has_element?(view, "#edit-playbook")
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

  describe "details panel" do
    test "it shares the side panel: a thread closes it, and closing the thread leaves none",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")
      {:ok, view, _html} = open(conn_of(ctx), channel)

      details(view)

      assert has_element?(
               view,
               "#details-panel[phx-hook=SidePanel][aria-label='Channel details']"
             )

      assert_push_event(view, "pref", %{key: "channel-details", value: "open"})

      view |> element("#reply-#{root.id}") |> render_click()
      assert has_element?(view, "#thread-panel")
      refute has_element?(view, "#details-panel")
      refute has_element?(view, "#toggle-details.btn-active")
      # the thread took the slot; the user didn't close Details, so it stays remembered open
      refute_push_event(view, "pref", %{key: "channel-details"})

      view |> element("#thread-panel-close") |> render_click()
      refute has_element?(view, "#thread-panel")
      refute has_element?(view, "#details-panel")

      # the Details button with a thread open: the thread closes, Details shows
      view |> element("#reply-#{root.id}") |> render_click()
      details(view)
      assert_patched(view, ~p"/channels/#{channel.id}")
      refute has_element?(view, "#thread-panel")
      assert has_element?(view, "#details-panel")

      # Esc (the SidePanel hook) and the button close it
      view |> element("#details-panel") |> render_hook("close_panel", %{})
      refute has_element?(view, "#details-panel")
      assert_push_event(view, "pref", %{key: "channel-details", value: "closed"})
      details(view)
      details(view)
      refute has_element?(view, "#details-panel")
    end

    test "the browser's preference opens it from lg up; a thread on arrival wins", ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert has_element?(view, "#channel-details-pref[data-pref-media='(min-width: 1024px)']")

      pref = fn view, value, media ->
        view
        |> element("#channel-details-pref")
        |> render_hook("pref", %{"key" => "channel-details", "value" => value, "media" => media})
      end

      pref.(view, "open", true)
      assert has_element?(view, "#details-panel")
      pref.(view, "closed", true)
      refute has_element?(view, "#details-panel")
      # below lg it never opens by itself
      pref.(view, "open", false)
      refute has_element?(view, "#details-panel")

      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")
      {:ok, view, _html} = live(conn_of(ctx), ChannelLive.thread_path(channel.id, root.id))
      pref.(view, "open", true)
      assert has_element?(view, "#thread-panel")
      refute has_element?(view, "#details-panel")
      # ...without forgetting that Details was left open
      refute_push_event(view, "pref", %{key: "channel-details"})

      # the palette's Show and Hide
      render_hook(view, "toggle_details", %{"open" => true})
      assert has_element?(view, "#details-panel")
      render_hook(view, "toggle_details", %{"open" => false})
      refute has_element?(view, "#details-panel")
    end

    test "only the user closing it is remembered: a thread, an activity or a narrower window is not",
         ctx do
      %{channel: channel, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")
      {:ok, view, _html} = open(conn_of(ctx), channel)

      pref = fn value, media ->
        view
        |> element("#channel-details-pref")
        |> render_hook("pref", %{"key" => "channel-details", "value" => value, "media" => media})
      end

      pref.("open", true)
      assert has_element?(view, "#details-panel")

      # a thread opens over it, then the window crosses lg both ways
      view |> element("#reply-#{root.id}") |> render_click()
      refute has_element?(view, "#details-panel")
      pref.("open", false)
      pref.("open", true)
      assert has_element?(view, "#thread-panel")
      refute has_element?(view, "#details-panel")

      refute_push_event(view, "pref", %{key: "channel-details", value: "closed"})

      # an activity panel takes the slot the same way
      details(view)
      assert_push_event(view, "pref", %{key: "channel-details", value: "open"})
      turn = record_turn(ctx, %{})
      render_patch(view, ChannelLive.activity_path(channel.id, turn.id))
      assert has_element?(view, "#activity-panel")
      refute has_element?(view, "#details-panel")
      refute_push_event(view, "pref", %{key: "channel-details", value: "closed"})

      # the user's own close is the one that sticks
      details(view)
      assert has_element?(view, "#details-panel")
      details(view)
      assert_push_event(view, "pref", %{key: "channel-details", value: "closed"})
    end

    test "narrowing the window below lg closes its forms too, so it reopens collapsed", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      pref = fn value, media ->
        view
        |> element("#channel-details-pref")
        |> render_hook("pref", %{"key" => "channel-details", "value" => value, "media" => media})
      end

      pref.("open", true)
      render_hook(view, "open_details", %{"section" => "spend"})
      view |> element("#take-lock-toggle") |> render_click()
      assert has_element?(view, "#budget-panel")
      assert has_element?(view, "#take-lock-form")

      pref.("open", false)
      refute has_element?(view, "#details-panel")
      refute_push_event(view, "pref", %{key: "channel-details", value: "closed"})

      # back above lg it opens as remembered, with nothing half-filled
      pref.("open", true)
      assert has_element?(view, "#details-panel")
      refute has_element?(view, "#budget-panel")
      refute has_element?(view, "#take-lock-form")
    end

    test "below lg, Brief › Add closes the Details overlay so the editor shows", ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      view
      |> element("#channel-details-pref")
      |> render_hook("pref", %{"key" => "channel-details", "value" => "", "media" => false})

      details(view)
      assert has_element?(view, "#details-panel")
      view |> element("#edit-brief") |> render_click()
      refute has_element?(view, "#details-panel")
      assert has_element?(view, "#brief-form")
      refute_push_event(view, "pref", %{key: "channel-details", value: "closed"})

      # from lg up Details is beside the feed, and stays
      render_hook(view, "toggle_brief_form", %{})
      refute has_element?(view, "#brief-form")

      view
      |> element("#channel-details-pref")
      |> render_hook("pref", %{"key" => "channel-details", "value" => "open", "media" => true})

      assert has_element?(view, "#details-panel")
      view |> element("#edit-brief") |> render_click()
      assert has_element?(view, "#details-panel")
      assert has_element?(view, "#brief-form")
    end

    test "each header chip opens it at its section", ctx do
      %{channel: channel, repository: repository} = ctx
      {:granted, _} = Canopy.Locks.acquire(ctx.session, repository.id, "tests", nil)
      {:ok, view, _html} = open(conn_of(ctx), channel)

      for {chip, section} <- [
            {"#agents-button", "agents"},
            {"#lock-chip-tests", "locks"},
            {"#edit-budget", "spend"}
          ] do
        render_hook(view, "close_panel", %{})
        view |> element(chip) |> render_click()
        assert has_element?(view, "#details-panel")
        assert_push_event(view, "details:focus", %{section: ^section})
      end

      assert has_element?(view, "#details-panel [data-section=spend] #budget-panel")

      # the palette's older commands land in Details too
      render_hook(view, "close_panel", %{})
      render_hook(view, "toggle_schedules", %{})
      assert has_element?(view, "#details-panel #schedules-panel")
      render_hook(view, "toggle_locks", %{})
      assert_push_event(view, "details:focus", %{section: "locks"})
    end

    test "closing it closes its parts; an old toggle reopens it on its part, never collapsed",
         ctx do
      {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

      # Change limit → close → the palette's "Channel: budget"
      render_hook(view, "open_details", %{"section" => "spend"})
      assert has_element?(view, "#budget-panel")
      render_hook(view, "close_panel", %{})
      render_hook(view, "toggle_budget", %{})
      assert has_element?(view, "#details-panel #budget-panel")
      assert_push_event(view, "details:focus", %{section: "spend"})
      # with Details showing, the same toggle closes it
      render_hook(view, "toggle_budget", %{})
      refute has_element?(view, "#budget-panel")

      # a half-taken lock doesn't come back either
      view |> element("#take-lock-toggle") |> render_click()
      assert has_element?(view, "#take-lock-form")
      render_hook(view, "close_panel", %{})
      details(view)
      refute has_element?(view, "#take-lock-form")
    end

    test "agent rows: working and waiting on you tick from when they began; idle shows no time",
         ctx do
      %{channel: channel, agent: agent, reviewer: reviewer, session: session} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      details(view)
      started = System.os_time(:millisecond) - 4 * 60_000

      broadcast_telemetry(channel.id, agent.id, :tool_started, %{
        call_id: "c1",
        tool: "read",
        status: :running,
        input: %{"filePath" => "lib/a.ex"},
        at: started,
        message_id: "m",
        part_id: "p1"
      })

      elapsed = "#member-#{agent.id}-elapsed-#{started}"
      assert has_element?(view, "#member-#{agent.id}", "working")
      assert has_element?(view, "#{elapsed}[data-started-at='#{started}'][data-coarse]", "4m")
      assert has_element?(view, "#{elapsed}[phx-hook][phx-update=ignore][title^='Working since']")
      # idle: no time
      assert has_element?(view, "#member-#{reviewer.id}", "idle")
      refute has_element?(view, "[id^='member-#{reviewer.id}-elapsed']")

      # waiting on you: from the question's time
      {:ok, question} =
        QuestionRequests.record(%{
          channel_id: channel.id,
          agent_session_id: session.id,
          opencode_question_id: "que_" <> Fixtures.unique_suffix(),
          questions: [%{"question" => "Which key?", "options" => [%{"label" => "A"}]}],
          status: "pending"
        })

      broadcast_status(channel.id, agent.id, :awaiting_user)
      asked = DateTime.to_unix(question.inserted_at, :millisecond)
      assert has_element?(view, "#member-#{agent.id}-awaiting", "waiting on you")

      assert has_element?(
               view,
               "#member-#{agent.id}-elapsed-#{asked}[title^='Waiting on you since']",
               "<1m"
             )

      # the agents button leads with who needs you
      assert has_element?(view, "#agents-button #agents-waiting", "1")
      assert render(element(view, "#agents-button")) =~ "@#{agent.name} waiting on you"
    end
  end

  defp conn_of(%{conn: conn}), do: conn
end
