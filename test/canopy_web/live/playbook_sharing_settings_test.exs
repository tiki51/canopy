defmodule CanopyWeb.PlaybookSharingSettingsTest do
  @moduledoc "Settings → Playbook sharing: the repository, branch and folder, and the connection check."
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Canopy.PlaybookSharingHelpers

  alias Canopy.OpenCode.ClientMock, as: OC
  alias Canopy.Settings

  setup :set_mox_global

  setup do
    stub(OC, :providers, fn _opts -> {:ok, %{"providers" => [], "default" => %{}}} end)
    stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
    stub_remote(%{"bug-fix" => playbook_text("bug-fix"), "triage" => playbook_text("triage")})
    :ok
  end

  test "saves the repository, branch and folder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#playbook-sharing-panel")
    assert has_element?(view, "#save-sharing[disabled]")

    view
    |> form("#sharing-form", sharing: %{repo: "acme/playbooks", branch: "dev", folder: "team/pb"})
    |> render_submit()

    setting = Settings.get()

    assert {setting.playbook_repo, setting.playbook_branch, setting.playbook_folder} ==
             {"acme/playbooks", "dev", "team/pb"}

    assert has_element?(view, "#sharing-repo-help", "Leave blank to stop sharing.")
  end

  test "saving a blank repository turns sharing off", %{conn: conn} do
    configure_sharing()
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             "#sharing-repo-help",
             "owner/name, or paste the repo URL. Leave blank to stop sharing."
           )

    view |> form("#sharing-form", sharing: %{repo: ""}) |> render_change()
    refute has_element?(view, "#save-sharing[disabled]")

    html = view |> form("#sharing-form", sharing: %{repo: ""}) |> render_submit()
    assert html =~ "Stopped sharing playbooks through GitHub."
    assert Canopy.Playbooks.Sharing.config() == :not_set_up
    refute has_element?(view, "#sharing-repo-help", "Leave blank")
    assert has_element?(view, "#save-sharing[disabled]")
  end

  test "a pasted URL fills all three fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#sharing-form", sharing: %{repo: "https://github.com/acme/playbooks/tree/main/pb"})
    |> render_change()

    assert has_element?(view, "#sharing-repo[value='acme/playbooks']")
    assert has_element?(view, "#sharing-branch[value='main']")
    assert has_element?(view, "#sharing-folder[value='pb']")
  end

  test "Check connection reports push access, import only, and gh's errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    view |> form("#sharing-form", sharing: %{repo: "acme/playbooks"}) |> render_change()

    view |> element("#check-sharing") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#sharing-check-ok",
             "Connected as sbarber · can push · 2 playbooks"
           )

    Canopy.Playbooks.Sharing.FakeRemote.set_push(false)
    view |> element("#check-sharing") |> render_click()
    render_async(view)
    assert has_element?(view, "#sharing-check-ok", "import only")

    for {callback, kind, lead} <- [
          {:account, :gh_missing, "GitHub CLI not found"},
          {:account, :gh_signed_out, "gh isn't signed in"},
          {:repo, :not_found, "Can't see acme/playbooks"}
        ] do
      stub_remote(%{}, fail: [{callback, kind}])
      view |> element("#check-sharing") |> render_click()
      render_async(view)
      assert has_element?(view, "#sharing-check-error[data-kind='#{kind}']", lead)
    end

    # the copy names this panel's button
    stub_remote(%{}, fail: [{:account, :gh_signed_out}])
    view |> element("#check-sharing") |> render_click()
    render_async(view)
    assert has_element?(view, "#sharing-check-error", "then Check connection.")
    refute has_element?(view, "#sharing-check-error", "Check again")

    # editing a field clears the result
    view |> form("#sharing-form", sharing: %{folder: "other"}) |> render_change()
    refute has_element?(view, "#sharing-check-error")
  end
end
