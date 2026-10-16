defmodule CanopyWeb.AllowGloballyLiveTest do
  @moduledoc "Allow globally in the browser, the edges: copy, plain-text lines, threads, stale Undo."
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, GlobalPermissions, Messages, PermissionRequests, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias CanopyWeb.ChannelLive

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    stub(OC, :messages, fn _dir, _sid, _query, _opts -> {:ok, []} end)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    scenario
  end

  defp pending(ctx, permission) do
    {:ok, request} =
      PermissionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.session.id,
        opencode_permission_id: "per_" <> Fixtures.unique_suffix(),
        permission: permission,
        patterns: ["/tmp/elsewhere"],
        status: "pending"
      })

    request
  end

  defp line(ctx, attrs) do
    {:ok, event} =
      Timeline.record(
        Map.merge(
          %{
            channel_id: ctx.channel.id,
            agent_id: ctx.agent.id,
            event_type: "permission_auto_approved",
            ref_id: "gp_test"
          },
          attrs
        )
      )

    Timeline.broadcast(event)
    event
  end

  defp auto(patterns),
    do: %{payload: %{"permission" => "Bash", "patterns" => patterns, "grant_id" => "gp_test"}}

  describe "the card" do
    test "external_directory offers Allow globally, and its toast says what it reaches", ctx do
      request = pending(ctx, "external_directory")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

      expect(OC, :reply_permission, fn _dir, _id, :once, _opts -> {:ok, true} end)
      view |> element("#permission-#{request.id}-global") |> render_click()

      assert has_element?(
               view,
               "#undo-toast",
               "@#{ctx.agent.name} can now reach files outside its project folder, in every channel, without asking."
             )
    end

    test "Allow globally sent for doom_loop anyway shows an error and keeps the card", ctx do
      request = pending(ctx, "doom_loop")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      expect(OC, :reply_permission, 0, fn _dir, _id, _reply, _opts -> {:ok, true} end)

      render_click(view, "respond_permission", %{"id" => request.id, "reply" => "global"})

      assert has_element?(view, "#flash-error", "doom_loop can't be allowed globally.")
      assert has_element?(view, "#permission-#{request.id}")
      assert GlobalPermissions.list_for_agent(ctx.agent.id) == []
    end

    test "Undo after the grant was removed on the agent page just closes the toast", ctx do
      request = pending(ctx, "bash")
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      expect(OC, :reply_permission, fn _dir, _id, :once, _opts -> {:ok, true} end)
      view |> element("#permission-#{request.id}-global") |> render_click()

      {:ok, _} = GlobalPermissions.revoke(GlobalPermissions.get(ctx.agent.id, "bash"))
      view |> element("#undo-delete") |> render_click()

      refute has_element?(view, "#undo-toast")
      refute has_element?(view, "#flash-error")
    end
  end

  describe "the auto-approval line" do
    test "joins patterns and cuts long ones", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      event = line(ctx, auto(["npm run build", "npm test"]))

      assert has_element?(
               view,
               ~s(#line-#{event.id}[data-tone="secondary"]),
               "@#{ctx.agent.name} ran Bash without asking · global permission · npm run build, npm test"
             )

      assert has_element?(view, "#line-#{event.id} .hero-globe-alt-mini")

      long = line(ctx, auto([String.duplicate("x", 400)]))
      text = view |> element("#line-#{long.id}") |> render()
      refute text =~ String.duplicate("x", 161)
      assert text =~ String.duplicate("x", 100)
    end

    test "is plain text: markup, links and mentions in a pattern stay literal", ctx do
      other = Fixtures.agent_fixture(%{name: "frontend#{Fixtures.unique_suffix()}"})
      {:ok, view, _html} = live(ctx.conn, ~p"/channels/#{ctx.channel.id}")
      event = line(ctx, auto(["echo <b>x</b> [a](http://x.test) @#{other.name}"]))

      html = view |> element("#line-#{event.id}") |> render()
      refute has_element?(view, "#line-#{event.id} b")
      refute has_element?(view, "#line-#{event.id} a")
      assert html =~ "&lt;b&gt;x&lt;/b&gt;"
      assert html =~ "[a](http://x.test)"
    end

    test "from a thread turn shows in the thread, not in the feed", ctx do
      {:ok, root} = Messages.post_agent_message(ctx.channel.id, ctx.agent.id, "Which width?")

      {:ok, view, _html} =
        live(ctx.conn, ChannelLive.thread_path(ctx.channel.id, root.id, nil))

      event = line(ctx, Map.merge(auto(["npm test"]), %{thread_id: root.id, in_channel: false}))
      text = "ran Bash without asking · global permission · npm test"

      assert view |> element("#thread-panel") |> render() =~ text
      refute view |> element("#timeline") |> render() =~ text
      refute has_element?(view, "#timeline #line-#{event.id}")
    end
  end

  describe "the agent page" do
    test "a grant from another year shows the year; removing the last hides the About link",
         %{conn: conn} do
      agent = Fixtures.agent_fixture(%{engine: "claude_code"})
      {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash")

      {:ok, _} =
        grant
        |> Ecto.Changeset.change(granted_at: ~U[2025-03-04 10:00:00.000000Z])
        |> Canopy.Repo.update()

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")
      assert has_element?(view, "#grant-#{grant.id}-meta", "Allowed Mar 4, 2025")
      assert has_element?(view, "#agent-grants-link", "+ 1 global")

      view |> element("#remove-grant-#{grant.id}") |> render_click()
      refute has_element?(view, "#agent-grants-link")
      assert has_element?(view, "#agent-grants-empty")

      view |> element("#undo-delete") |> render_click()
      assert has_element?(view, "#agent-grants-link", "+ 1 global")
      assert has_element?(view, "#grant-#{grant.id}-meta", "Allowed Mar 4, 2025")
    end

    test "Remove on a grant another tab already removed just drops the row", %{conn: conn} do
      agent = Fixtures.agent_fixture()
      {:ok, grant} = GlobalPermissions.grant(agent.id, "Bash")
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      # removed elsewhere without a broadcast reaching this page yet
      Canopy.Repo.delete!(grant)
      view |> element("#remove-grant-#{grant.id}") |> render_click()

      refute has_element?(view, "#grant-#{grant.id}")
      refute has_element?(view, "#undo-toast")
    end
  end
end
