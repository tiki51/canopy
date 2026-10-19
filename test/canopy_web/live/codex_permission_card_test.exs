defmodule CanopyWeb.CodexPermissionCardTest do
  @moduledoc """
  Permission cards for Codex requests: the head reads as what the agent wants
  to do (`metadata["action"]`), the outside-sandbox and once-only marks, the
  buttons, and the diff behind *view change*. A request without an action
  renders as before.
  """
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, PermissionRequests, Runtime, Timeline}
  alias Canopy.OpenCode.ClientMock, as: OC

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

  defp pending(ctx, permission, patterns, metadata) do
    {:ok, request} =
      PermissionRequests.record(%{
        channel_id: ctx.channel.id,
        agent_session_id: ctx.session.id,
        opencode_permission_id: "per_" <> Fixtures.unique_suffix(),
        permission: permission,
        patterns: patterns,
        metadata: metadata,
        status: "pending"
      })

    request
  end

  defp command(ctx, extra \\ %{}) do
    pending(
      ctx,
      "Bash",
      ["npm install csv-stringify"],
      Map.merge(
        %{
          "action" => "command",
          "command" => "npm install csv-stringify",
          "reason" => "needs network access",
          "always_prefix" => "npm install"
        },
        extra
      )
    )
  end

  defp open(ctx), do: live(ctx.conn, ~p"/channels/#{ctx.channel.id}")

  defp title(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("title")
  end

  defp reason(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "a command card" do
    test "asks to run a command, with the reason and all four buttons", ctx do
      request = command(ctx)
      {:ok, view, _html} = open(ctx)
      card = "#permission-#{request.id}"

      assert has_element?(view, card, "asks to")
      assert has_element?(view, card, "run a command")
      assert has_element?(view, "#{card}-command", "npm install csv-stringify")
      assert has_element?(view, "#{card}-reason", "needs network access")
      refute has_element?(view, card, "Bash permission")

      for button <- ~w(once always global reject),
          do: assert(has_element?(view, "#{card}-#{button}"))

      assert title(view, "#{card}-always") == [
               ~s(For commands starting with "npm install", until this session resets)
             ]

      assert title(view, "#{card}-global") == [
               "Run any command without asking, in every channel"
             ]

      assert title(view, "#{card}-once") == []
    end

    test "without always_prefix, Always covers this command", ctx do
      request = command(ctx, %{"always_prefix" => nil})
      {:ok, view, _html} = open(ctx)

      assert title(view, "#permission-#{request.id}-always") == [
               "For this command, until this session resets"
             ]
    end

    test "a command that needs the network has the network badge", ctx do
      plain = command(ctx)
      networked = command(ctx, %{"network" => true})
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#permission-#{networked.id} .badge", "network")
      refute has_element?(view, "#permission-#{plain.id} .badge", "network")
    end

    test "unsandboxed: the badge, the reason's note and the titles say so", ctx do
      request = command(ctx, %{"unsandboxed" => true})
      plain = command(ctx)
      {:ok, view, _html} = open(ctx)
      card = "#permission-#{request.id}"

      assert has_element?(view, "#{card} .badge-warning", "outside sandbox")

      assert has_element?(
               view,
               "#{card}-reason",
               "needs network access · runs outside Codex's sandbox, so it can change files anywhere and use the network"
             )

      assert ["Runs outside Codex's sandbox:" <> _] = title(view, "#{card}-once")

      assert title(view, "#{card}-always") == [
               ~s(Runs outside Codex's sandbox: for commands starting with "npm install", until this session resets)
             ]

      refute has_element?(view, "#permission-#{plain.id} .badge-warning")
      refute has_element?(view, "#permission-#{plain.id}-reason", "outside Codex's sandbox")
    end

    test "once_only (a read-only agent): Once and Reject only", ctx do
      request = command(ctx, %{"unsandboxed" => true, "once_only" => true})
      {:ok, view, _html} = open(ctx)
      card = "#permission-#{request.id}"

      assert has_element?(view, "#{card}-once")
      assert has_element?(view, "#{card}-reject")
      refute has_element?(view, "#{card}-always")
      refute has_element?(view, "#{card}-global")
      assert title(view, "#{card}-once") == ["Runs outside Codex's sandbox, this time only"]

      assert reason(view, "#{card}-reason") ==
               "needs network access · read-only agent: runs outside Codex's sandbox, so it can change files and use the network"
    end

    test "no_always (a git command no rule could match): no Always, the rest stay", ctx do
      request = command(ctx, %{"command" => "git push", "no_always" => true})
      {:ok, view, _html} = open(ctx)
      card = "#permission-#{request.id}"

      refute has_element?(view, "#{card}-always")

      for button <- ~w(once global reject),
          do: assert(has_element?(view, "#{card}-#{button}"))
    end

    test "the badges come after the command", ctx do
      request = command(ctx, %{"network" => true, "unsandboxed" => true})
      {:ok, view, _html} = open(ctx)
      html = view |> element("#permission-#{request.id}") |> render()

      [before_command, after_command] =
        String.split(html, ~s(id="permission-#{request.id}-command"))

      refute before_command =~ "outside sandbox"
      refute before_command =~ ">network<"
      assert after_command =~ ">network<"
      assert after_command =~ "outside sandbox"
    end

    test "detached, it is in the past tense", ctx do
      request = command(ctx)
      {:ok, _} = PermissionRequests.detach(request)
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#permission-#{request.id}", "asked to")
    end
  end

  describe "a file-change card" do
    @diff "--- a/.npmrc\n+++ b/.npmrc\n@@ -1 +1,2 @@\n registry=x\n+save-exact=true\n"

    test "asks to edit files, with the paths and a collapsed diff behind view change", ctx do
      request =
        pending(ctx, "file_change", ["~/.npmrc"], %{
          "action" => "file_change",
          "paths" => ["~/.npmrc"],
          "outside_repo" => true,
          "diff" => @diff
        })

      {:ok, view, _html} = open(ctx)
      card = "#permission-#{request.id}"

      assert has_element?(view, card, "edit files")
      assert has_element?(view, card, "outside the repo:")
      assert has_element?(view, "#{card} code", "~/.npmrc")
      assert has_element?(view, "#{card}-diff.hidden")

      assert has_element?(
               view,
               ~s(#{card}-view-change[aria-controls="permission-#{request.id}-diff"][aria-expanded="false"]),
               "view change"
             )

      assert has_element?(view, "#{card}-always")
      refute has_element?(view, "#{card}-global")
    end

    test "a protected path in the repo has no outside-the-repo prefix, and no diff no link",
         ctx do
      request =
        pending(ctx, "file_change", [".codex/config.toml"], %{
          "action" => "file_change",
          "paths" => [".codex/config.toml"],
          "outside_repo" => false
        })

      {:ok, view, _html} = open(ctx)
      card = "#permission-#{request.id}"

      assert has_element?(view, "#{card} code", ".codex/config.toml")
      refute has_element?(view, card, "outside the repo")
      refute has_element?(view, "#{card}-view-change")
      refute has_element?(view, "#{card}-diff")
    end

    test "more than three paths show the first three and a count", ctx do
      paths = ~w(~/a ~/b ~/c ~/d ~/e)

      request =
        pending(ctx, "file_change", paths, %{
          "action" => "file_change",
          "paths" => paths,
          "outside_repo" => true
        })

      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#permission-#{request.id} code", "~/c")
      refute has_element?(view, "#permission-#{request.id} code", "~/d")
      assert has_element?(view, "#permission-#{request.id}", "+2 more")
    end
  end

  describe "a more-access card" do
    test "names what it would grant, and has no Allow globally", ctx do
      cases = [
        {%{"network" => true, "paths" => []}, "asks for network access"},
        {%{"network" => false, "paths" => ["~/data"]}, "asks to use files outside the repo"},
        {%{"network" => true, "paths" => ["~/data"]},
         "asks for network access and files outside the repo"},
        {%{"network" => false, "paths" => []}, "asks for more access"}
      ]

      requests =
        for {meta, head} <- cases do
          request =
            pending(
              ctx,
              "permissions",
              meta["paths"],
              Map.merge(meta, %{"action" => "permissions", "reason" => "to fetch"})
            )

          {request, head}
        end

      {:ok, view, _html} = open(ctx)

      for {request, head} <- requests do
        assert has_element?(view, "#permission-#{request.id}", head)
        assert has_element?(view, "#permission-#{request.id}-reason", "to fetch")
        refute has_element?(view, "#permission-#{request.id}-global")
      end
    end
  end

  test "a request without an action renders as before", ctx do
    request = pending(ctx, "edit", ["lib/app.ex"], %{})
    {:ok, view, _html} = open(ctx)
    card = "#permission-#{request.id}"

    assert has_element?(view, card, "asks for")
    assert has_element?(view, card, "edit")
    assert has_element?(view, card, "permission")
    assert title(view, "#{card}-always") == ["Until this session resets"]
    assert title(view, "#{card}-once") == []
  end

  test "the requested line uses the card's verb for a Codex request", ctx do
    for {action, patterns} <- [{"command", ["ls -la"]}, {nil, ["lib/app.ex"]}] do
      {:ok, _} =
        Timeline.record(%{
          channel_id: ctx.channel.id,
          agent_id: ctx.agent.id,
          event_type: "permission_requested",
          payload: %{"permission" => "Bash", "patterns" => patterns, "action" => action}
        })
    end

    {:ok, view, _html} = open(ctx)
    html = render(view)
    assert html =~ "@#{ctx.agent.name} asked to run a command: ls -la"
    refute html =~ "asked for Bash permission: ls -la"
    assert html =~ "@#{ctx.agent.name} asked for Bash permission: lib/app.ex"
  end

  test "the resolved line uses the card's verb for a Codex request", ctx do
    {:ok, event} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        event_type: "permission_resolved",
        payload: %{"permission" => "Bash", "status" => "once", "action" => "command"}
      })

    {:ok, view, _html} = open(ctx)
    assert render(view) =~ "let @#{ctx.agent.name} run a command once"
    assert event.id
  end
end
