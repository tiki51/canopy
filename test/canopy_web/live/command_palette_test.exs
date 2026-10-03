defmodule CanopyWeb.CommandPaletteLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Canopy.PlaybookHelpers, only: [playbook_fixture: 2]

  alias Canopy.{Agents, Channels, Documents, Fixtures, Hold, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC

  # the agents and settings pages ask OpenCode for models in the background
  setup {Mox, :set_mox_global}

  setup do
    Mox.stub(OC, :providers, fn _opts -> {:error, :econnrefused} end)
    Mox.stub(OC, :agents, fn _dir, _opts -> {:error, :econnrefused} end)
    :ok
  end

  defp data(view, attribute) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#cmdk")
    |> LazyHTML.attribute(attribute)
    |> List.first()
    |> Jason.decode!()
  end

  defp item(view, id), do: Enum.find(data(view, "data-items"), &(&1["id"] == id))

  test "renders on every page with a sidebar, closed, with the Jump to button", %{conn: conn} do
    %{channel: channel, repository: repository} = Fixtures.scenario()

    for path <- [
          ~p"/agents",
          ~p"/settings",
          ~p"/files",
          ~p"/teams",
          ~p"/threads",
          ~p"/playbooks",
          ~p"/repositories/#{repository.id}",
          ~p"/channels/#{channel.id}"
        ] do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               "#cmdk[phx-hook=CommandPalette][phx-update=ignore] dialog#cmdk-dialog"
             )

      refute has_element?(view, "#cmdk-dialog[open]")
      assert has_element?(view, "#cmdk-input[role=combobox][aria-controls=cmdk-list]")
      assert has_element?(view, "#cmdk-list[role=listbox]")
      assert has_element?(view, "#sidebar #cmdk-open")
      assert %{"name" => "i", "prefill" => "/i @"} = hd(data(view, "data-commands"))
    end
  end

  test "is not on the first-run setup", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/welcome")
    refute has_element?(view, "#cmdk")
    refute has_element?(view, "#cmdk-open")
  end

  test "data-items lists archived channels flagged, DMs by label, active agents, teams and enabled playbooks",
       %{conn: conn} do
    %{channel: channel, repository: repository, agent: owner} = Fixtures.scenario()
    old = Fixtures.channel_fixture(%{repository_id: repository.id, owner_agent_id: owner.id})
    {:ok, _} = Channels.archive(old)
    {:ok, dm} = Channels.ensure_dm(repository.id, owner)
    gone = Fixtures.agent_fixture()
    {:ok, _} = Agents.deactivate(gone)
    team = Fixtures.team_fixture([owner], name: "crew" <> Fixtures.unique_suffix())
    playbook = playbook_fixture("triage", [{"a", "A", "coordinator"}])

    {:ok, view, _html} = live(conn, ~p"/agents")

    assert %{"t" => "channel", "archived" => false, "repo" => repo} = item(view, channel.id)
    assert repo == repository.name
    assert %{"t" => "channel", "archived" => true} = item(view, old.id)
    assert %{"t" => "dm", "label" => "@" <> name} = item(view, dm.id)
    assert name == owner.name
    assert %{"t" => "agent", "name" => _} = item(view, owner.id)
    refute item(view, gone.id)
    assert %{"t" => "team", "name" => team_name} = item(view, team.id)
    assert team_name == team.name
    assert %{"t" => "playbook", "name" => "triage"} = item(view, playbook.id)
    assert %{"t" => "repo"} = item(view, repository.id)
  end

  test "data-context follows the page and the hold", %{conn: conn} do
    %{channel: channel} = Fixtures.scenario()

    {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}")

    assert %{"channel_id" => id, "repo_id" => repo_id, "hold" => false} =
             data(view, "data-context")

    assert id == channel.id
    assert repo_id == channel.repository_id

    {:ok, view, _html} = live(conn, ~p"/agents")

    assert %{"channel_id" => nil, "path" => "/agents", "hold" => false} =
             data(view, "data-context")

    :ok = Hold.engage("Insufficient balance")
    on_exit(fn -> Hold.release() end)
    _ = :sys.get_state(view.pid)
    assert %{"hold" => true} = data(view, "data-context")
  end

  test "channels, teams and playbooks created elsewhere show up without a reload", %{conn: conn} do
    %{repository: repository, agent: owner} = Fixtures.scenario()
    {:ok, view, _html} = live(conn, ~p"/settings")

    new = Fixtures.channel_fixture(%{repository_id: repository.id, owner_agent_id: owner.id})
    team = Fixtures.team_fixture([owner], name: "squad" <> Fixtures.unique_suffix())
    playbook = playbook_fixture("release", [{"a", "A", "coordinator"}])
    _ = :sys.get_state(view.pid)

    assert %{"t" => "channel"} = item(view, new.id)
    assert %{"t" => "team"} = item(view, team.id)
    assert %{"t" => "playbook"} = item(view, playbook.id)
  end

  test "data-badges carries unread and cards waiting, non-zero only", %{conn: conn} do
    %{channel: channel, agent: agent} = Fixtures.scenario()
    {:ok, view, _html} = live(conn, ~p"/agents")
    assert data(view, "data-badges") == %{}

    {:ok, _} = Canopy.Messages.post_agent_message(channel.id, agent.id, "a quiet finding")
    _ = :sys.get_state(view.pid)
    assert data(view, "data-badges") == %{channel.id => [1, 0, 0]}
  end

  describe "cmdk:files" do
    test "replies with matching filenames, newest first; one character asks for nothing",
         %{conn: conn} do
      %{user: user} = Fixtures.scenario()

      {:ok, plan} =
        Documents.create(%{
          filename: "release-plan.md",
          source: {:binary, "# plan"},
          user_id: user.id
        })

      {:ok, _} =
        Documents.create(%{filename: "notes.txt", source: {:binary, "hi"}, user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/agents")

      render_hook(view, "cmdk:files", %{"q" => " plan ", "seq" => 3})
      url = Documents.url_path(plan)
      plan_id = plan.id

      assert_reply(view, %{
        seq: 3,
        files: [%{id: ^plan_id, filename: "release-plan.md", kind: _, size_label: _, url: ^url}]
      })

      render_hook(view, "cmdk:files", %{"q" => "p", "seq" => 4})
      assert_reply(view, %{files: [], seq: 4})
    end
  end

  describe "cmdk:stop" do
    setup do
      on_exit(&Canopy.PlaybookHelpers.stop_channels/0)
    end

    test "stops a channel from another page and names it in a flash", %{conn: conn} do
      %{channel: channel} = Fixtures.scenario()
      {:ok, view, _html} = live(conn, ~p"/agents")

      render_hook(view, "cmdk:stop", %{"channel_id" => channel.id})
      assert_reply(view, %{ok: true})
      assert Runtime.stopped?(channel.id)
      assert has_element?(view, "#flash-info", "Stopped ##{channel.name}: 0 turns aborted")
      assert_patched_or_same(view, "/agents")
    end

    test "an unknown or archived channel is refused", %{conn: conn} do
      %{channel: channel} = Fixtures.scenario()
      {:ok, _} = Channels.archive(channel)
      {:ok, view, _html} = live(conn, ~p"/agents")

      render_hook(view, "cmdk:stop", %{"channel_id" => "ch_nope"})
      assert_reply(view, %{ok: false})
      assert has_element?(view, "#flash-error", "no longer exists")

      render_hook(view, "cmdk:stop", %{"channel_id" => channel.id})
      assert_reply(view, %{ok: false})
      assert has_element?(view, "#flash-error", "archived")
      refute Runtime.stopped?(channel.id)
    end
  end

  # /stop from the palette never navigates
  defp assert_patched_or_same(view, path) do
    assert %{"path" => ^path} = data(view, "data-context")
  end
end
