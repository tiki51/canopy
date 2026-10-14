defmodule CanopyWeb.EnvironmentLiveTest do
  @moduledoc """
  Settings → Environment (rerun the seeder, reset from scratch), and what a
  reset does to every other page through `CanopyWeb.Nav` and
  `CanopyWeb.ChannelLive`. Resets run for real against
  `Canopy.Environment.FakeBackup`; in-between states are driven by
  broadcasting the contract's messages on "environment".
  """
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.EnvironmentHelpers

  alias Canopy.{Agents, Channels, Environment, Fixtures, Runtime, Seeds}
  alias Canopy.Environment.Resetter
  alias Canopy.OpenCode.ClientMock, as: OC
  alias CanopyWeb.{ChannelLive, EnvironmentComponents}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(OC, :providers, fn _opts -> {:error, {:transport, %{reason: :econnrefused}}} end)
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
    stub(OC, :abort, fn _dir, _sid, _opts -> {:ok, true} end)
    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)

    Resetter.forget()
    # a test that started a reset never leaves it running for the next one, nor
    # its outcome: a recent reset sends a missing agent's or channel's page to
    # the banner (CanopyWeb.Nav), whichever test opens one next
    on_exit(fn ->
      await_reset()
      Resetter.forget()
    end)

    :ok
  end

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, "environment", {:environment, message})

  defp step(id \\ "rst_test", step, index),
    do: {:reset_step, %{id: id, step: step, index: index, total: 4}}

  defp open_modal(view) do
    view |> element("#open-reset") |> render_click()
    assert has_element?(view, "#reset-modal")
    view
  end

  defp confirm(view) do
    view |> form("#reset-form", %{phrase: "reset"}) |> render_change()
    view |> form("#reset-form", %{phrase: "reset"}) |> render_submit()
  end

  describe "the panel" do
    test "renders last on the page, with both actions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#environment-panel #rerun-seeder")
      assert has_element?(view, "#environment-panel #open-reset")

      panels =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("section[id$='-panel']")

      assert panels |> LazyHTML.attribute("id") |> List.last() == "environment-panel"
      refute has_element?(view, "#reset-modal")
      refute has_element?(view, "#reset-result")
    end
  end

  describe "rerun seeder" do
    test "lists what it created, then that nothing was missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#rerun-seeder") |> render_click()
      html = render_async(view)

      assert has_element?(view, "#seed-result[role=status]")
      assert html =~ "Created #{length(Seeds.agent_names()) + 3}"
      assert has_element?(view, "#seed-result .badge", "agent @backend")
      assert has_element?(view, "#seed-result .badge", "team @bugfix-team")
      assert has_element?(view, "#seed-result .badge", "playbook bug-fix")
      assert has_element?(view, "#seed-result .badge", "playbook feature-build")
      assert has_element?(view, "#seed-result details dd", "feature-build")
      assert has_element?(view, "#seed-result details dd", "@finops")
      refute has_element?(view, "#rerun-seeder[disabled]")

      view |> element("#rerun-seeder") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#seed-result",
               "Nothing to add. All #{length(Seeds.agent_names()) + 3} starters already exist."
             )
    end

    test "names a starter team it skipped", %{conn: conn} do
      # an agent holding the team's name makes the seeder skip the team
      Fixtures.agent_fixture(%{name: "bugfix-team"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#rerun-seeder") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#seed-result #seed-skipped",
               "Not created: team @bugfix-team (the name is taken, or none of the team's agents exist)."
             )

      refute has_element?(view, "#seed-result .badge", "team @bugfix-team")

      view |> element("#rerun-seeder") |> render_click()
      render_async(view)

      assert has_element?(view, "#seed-result", "Nothing added.")
      assert has_element?(view, "#seed-result #seed-skipped", "team @bugfix-team")
    end

    test "says where it stopped", %{conn: conn} do
      # a team holding a starter agent's name makes that agent's insert fail
      Fixtures.team_fixture([Fixtures.agent_fixture()], %{name: "designer"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#rerun-seeder") |> render_click()
      render_async(view)

      assert has_element?(view, "#seed-result.alert-error", "The seeder stopped: agent @designer")
      assert has_element?(view, "#seed-result", "Anything created before that is kept.")
    end

    test "while a reset runs, it is disabled and refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      broadcast(step(:clearing, 3))

      assert has_element?(view, "#rerun-seeder[disabled]")
      render_click(view, "rerun_seeder")
      refute has_element?(view, "#seed-result")
    end
  end

  describe "the reset modal" do
    test "shows what goes and what stays, counted now", %{conn: conn} do
      channel = Fixtures.channel_fixture()
      {:ok, view, _html} = live(conn, ~p"/settings")
      open_modal(view)

      preview = Environment.preview()
      d = preview.deleted
      assert d.channels >= 1

      assert has_element?(view, "#reset-deleted dd", "#{d.channels + d.dms}")
      assert has_element?(view, "#reset-deleted dd", "#{d.agents} · #{d.teams}")
      assert has_element?(view, "#reset-deleted dd", Canopy.Costs.money(d.cost_usd))

      assert has_element?(
               view,
               "#reset-kept li",
               "Registered repositories (#{preview.kept.repositories})"
             )

      assert has_element?(view, "#reset-kept li", "Everything inside your repositories")
      refute has_element?(view, "#reset-kept li", "Spend hold")
      assert has_element?(view, "#reset-backup-preview", preview.backup_path)
      assert has_element?(view, "#reset-dialog[role=dialog][aria-modal=true]")
      assert Channels.get(channel.id)
    end

    test "Reset Canopy is enabled only by the phrase", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      open_modal(view)

      for phrase <- ["", "rese", "resets"] do
        view |> form("#reset-form", %{phrase: phrase}) |> render_change()
        assert has_element?(view, "#confirm-reset[disabled]"), phrase
      end

      for phrase <- ["reset", " RESET "] do
        view |> form("#reset-form", %{phrase: phrase}) |> render_change()
        refute has_element?(view, "#confirm-reset[disabled]"), phrase
      end

      # a forged submit with the wrong phrase does nothing
      render_submit(view, "start_reset", %{"phrase" => "nope"})
      render_submit(view, "start_reset", %{})
      assert has_element?(view, "#reset-form")
      assert Environment.status() == :idle
    end

    test "Cancel closes it; a running one can't be closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      open_modal(view)
      view |> element("#cancel-reset") |> render_click()
      refute has_element?(view, "#reset-modal")

      open_modal(view)
      render_keydown(view, "close_reset", %{"key" => "Escape"})
      refute has_element?(view, "#reset-modal")

      broadcast(step(:backing_up, 2))
      assert has_element?(view, "#cancel-reset[disabled]")
      refute has_element?(view, "#reset-modal[phx-window-keydown]")
      render_click(view, "close_reset")
      assert has_element?(view, "#reset-modal")
    end

    test "running names the step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      open_modal(view)

      broadcast(step(:stopping, 1))
      assert has_element?(view, "#reset-step", "Stopping agents")
      assert has_element?(view, "#reset-step", "(step 1 of 4)")

      broadcast(step(:seeding, 4))
      assert has_element?(view, "#reset-step", "Creating starters")
      assert has_element?(view, "#reset-step", "(step 4 of 4)")
      assert has_element?(view, "#reset-dialog[aria-busy=true]")
    end
  end

  describe "a reset that deletes nothing" do
    test "fails in the modal and tries again", %{conn: conn} do
      channel = Fixtures.channel_fixture()
      {:ok, view, _html} = live(conn, ~p"/settings")

      fail_reset_at(:backing_up)
      view |> open_modal() |> confirm()
      await_reset()

      assert has_element?(view, "#reset-failure p.font-medium", "Backing up the database failed.")
      assert has_element?(view, "#reset-failure p.font-mono", "injected failure")
      assert has_element?(view, "#reset-failure", "Nothing was deleted.")
      refute has_element?(view, "#reset-failure", "Your backup is at")
      assert Channels.get(channel.id)

      # nothing was deleted, so nothing reloaded; try again after the clear fails
      view |> element("#cancel-reset") |> render_click()
      fail_reset_at(:clearing)
      view |> open_modal() |> confirm()
      await_reset()

      assert has_element?(view, "#reset-failure p.font-medium", "Clearing failed.")
      assert has_element?(view, "#reset-failure", "Your backup is at")
      assert has_element?(view, "#reset-failure code", ".db")
      assert Channels.get(channel.id)

      clear_reset_failure()
      view |> element("#retry-reset") |> render_click()
      await_reset()
      {path, _flash} = assert_redirect(view)

      assert path == "/settings?reset=" <> Environment.last_reset().id
      refute Channels.get(channel.id)
    end
  end

  describe "a reset that deletes" do
    test "reloads onto the banner, which a plain /settings drops", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> open_modal() |> confirm()
      await_reset()
      {"/settings?reset=" <> id, _flash} = assert_redirect(view)

      assert %{status: :done, id: ^id, backup_path: backup} = Environment.last_reset()

      {:ok, view, _html} = live(conn, ~p"/settings?reset=#{id}")
      assert has_element?(view, "#reset-result[role=status]", "Canopy was reset")
      assert has_element?(view, "#reset-result", "Seeder created")
      assert has_element?(view, "#reset-backup-path", backup)
      assert has_element?(view, "#copy-backup-path")

      {:ok, view, _html} = live(conn, ~p"/settings")
      refute has_element?(view, "#reset-result")

      {:ok, view, _html} = live(conn, ~p"/settings?reset=rst_other")
      refute has_element?(view, "#reset-result")
    end

    test "a seeder that stops shows the error banner", %{conn: conn} do
      fail_reset_at(:seeding)
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> open_modal() |> confirm()
      await_reset()
      {"/settings?reset=" <> id, _flash} = assert_redirect(view)

      {:ok, view, _html} = live(conn, ~p"/settings?reset=#{id}")

      assert has_element?(
               view,
               "#reset-result[role=alert]",
               "Canopy was cleared, but the seeder stopped."
             )

      assert has_element?(view, "#reset-result", "Rerun the seeder below")
      assert has_element?(view, "#reset-backup-path")
    end

    test "files that stay show the warning banner", %{conn: conn} do
      fail_reset_at(:sweeping)
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> open_modal() |> confirm()
      await_reset()
      {"/settings?reset=" <> id, _flash} = assert_redirect(view)

      {:ok, view, _html} = live(conn, ~p"/settings?reset=#{id}")

      assert has_element?(
               view,
               "#reset-result[role=status]",
               "Canopy was reset, but some shared files couldn't be deleted."
             )

      assert has_element?(view, "#reset-result code", Canopy.Documents.Store.dir())
      # the seeder still ran
      assert Agents.get_by_name("backend")

      fail_reset_at([:sweeping, :seeding])
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> open_modal() |> confirm()
      await_reset()
      {"/settings?reset=" <> id, _flash} = assert_redirect(view)

      {:ok, view, _html} = live(conn, ~p"/settings?reset=#{id}")
      assert has_element?(view, "#reset-result[role=alert]", "the seeder stopped")
    end
  end

  describe "another tab's reset" do
    test "locks every Settings tab", %{conn: conn} do
      {:ok, a, _html} = live(conn, ~p"/settings")
      {:ok, b, _html} = live(conn, ~p"/settings")

      broadcast(step(:backing_up, 2))

      for view <- [a, b] do
        assert has_element?(view, "#reset-sub", "A reset is running. This page reloads")
        assert has_element?(view, "#rerun-seeder[disabled]")
        assert has_element?(view, "#open-reset[disabled]")

        render_click(view, "rerun_seeder")
        render_click(view, "open_reset")
        render_click(view, "close_reset")

        assert has_element?(view, "#reset-step", "Backing up the database")
        refute has_element?(view, "#seed-result")
      end
    end

    test "a failure that deleted nothing is a flash on a closed modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      broadcast(
        {:reset_failed,
         %{
           id: "rst_x",
           status: :failed,
           at: DateTime.utc_now(),
           step: :stopping,
           reason: "boom",
           backup_path: nil,
           deleted?: false
         }}
      )

      assert render(view) =~ "Stopping agents failed: boom. Nothing was deleted."
    end
  end

  describe "every page" do
    test "reloads onto the banner when a reset deleted something, only then", %{conn: conn} do
      %{channel: channel} = Fixtures.scenario()

      failure = %{
        id: "rst_x",
        status: :failed,
        at: DateTime.utc_now(),
        step: :seeding,
        reason: "x",
        backup_path: nil
      }

      for path <- [~p"/agents", ~p"/channels/#{channel.id}", ~p"/settings"] do
        {:ok, view, _html} = live(conn, path)
        broadcast({:reset_failed, Map.put(failure, :deleted?, false)})
        broadcast(step(:clearing, 3))
        assert render(view)

        broadcast({:reset_failed, Map.put(failure, :deleted?, true)})
        assert_redirect(view, "/settings?reset=rst_x")

        {:ok, view, _html} = live(conn, path)

        broadcast(
          {:reset_done,
           %{id: "rst_y", status: :done, at: DateTime.utc_now(), backup_path: "/x.db", seed: %{}}}
        )

        assert_redirect(view, "/settings?reset=rst_y")
      end

      Runtime.stop_channel(channel.id)
    end

    test "Settings is subscribed once, by Nav", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      subscriptions =
        for {pid, _} <- Registry.lookup(Canopy.PubSub, "environment"), pid == view.pid, do: pid

      assert length(subscriptions) == 1
    end

    test "the palette's /stop is refused during a reset", %{conn: conn} do
      raise_gate()
      %{channel: channel} = Fixtures.scenario()
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "cmdk:stop", %{"channel_id" => channel.id})
      assert render(view) =~ EnvironmentComponents.resetting_message()
    end
  end

  describe "a channel during a reset" do
    test "mounts read-only and refuses runtime events", %{conn: conn} do
      %{channel: channel} = Fixtures.scenario()
      Runtime.stop_channel(channel.id)
      raise_gate()

      {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}")
      assert Canopy.Runtime.Supervisor.whereis(channel.id) == nil

      for event <- ChannelLive.runtime_events() do
        assert render_click(view, event, %{}) =~ EnvironmentComponents.resetting_message(), event
      end

      # the browser clears the composer only when the server says it sent
      render_submit(view, "send", %{"message" => %{"body" => "still here"}})
      refute_push_event(view, "composer:clear", _)
      assert Canopy.Runtime.Supervisor.whereis(channel.id) == nil
    end

    test "a channel the reset deleted goes to the banner", %{conn: conn} do
      %{channel: channel} = Fixtures.scenario()
      Runtime.stop_channel(channel.id)

      {:ok, settings, _html} = live(conn, ~p"/settings")
      settings |> open_modal() |> confirm()
      await_reset()
      {"/settings?reset=" <> id, _flash} = assert_redirect(settings)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/channels/#{channel.id}")
      assert to == "/settings?reset=" <> id

      # a row that is merely missing is still a 404
      Resetter.forget()
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/channels/#{channel.id}") end
    end
  end
end
