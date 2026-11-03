defmodule CanopyWeb.PlaybookSharingLiveTest do
  @moduledoc """
  Sharing playbooks through GitHub on the Playbooks page: the GitHub menu,
  the notice and chips, the Import and Export dialogs, Compare and View.
  GitHub is the in-memory `FakeRemote`, so tests are `async: false`.
  """
  use CanopyWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Canopy.PlaybookSharingHelpers

  alias Canopy.{Playbooks, Repo, Settings}
  alias Canopy.Playbooks.Playbook
  alias Canopy.Playbooks.Sharing.FakeRemote
  alias CanopyWeb.PlaybookSharing

  defp text(name, opts \\ []), do: Canopy.PlaybookSharingHelpers.playbook_text(name, opts)

  defp create(name, opts \\ []) do
    {:ok, playbook} = Playbooks.create(%{body: text(name, opts)})
    playbook
  end

  # a local playbook that was imported from playbooks/<name>.md at v`version`
  defp linked(name, version, opts \\ []) do
    body = text(name, opts)
    {:ok, playbook} = Playbooks.create(%{body: body})
    link_playbook(playbook, "playbooks/#{name}.md", version, body)
  end

  defp dom(key), do: PlaybookSharing.dom_id(key)

  defp text_of(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  describe "the GitHub menu" do
    test "keeps Import a file, and offers Open repo once sharing is set up", %{conn: conn} do
      view = open(conn, ~p"/playbooks")

      assert has_element?(view, "#github-menu #import-playbook[href='/agents/import']")
      assert has_element?(view, "#github-import[href='/playbooks?github=import']")
      assert has_element?(view, "#github-export[href='/playbooks?github=export']")
      refute has_element?(view, "#github-open-repo")

      configure_sharing()
      stub_remote(%{})
      view = open(conn, ~p"/playbooks")

      assert has_element?(
               view,
               "#github-open-repo[href='https://github.com/acme/playbooks/tree/main/playbooks']"
             )
    end
  end

  describe "notice and chips" do
    setup do
      configure_sharing()

      update = linked("alpha", 1)
      both = linked("beta", 2)
      {:ok, _} = Playbooks.update(both, %{body: text("beta", description: "Mine now.")})
      plain = create("delta")

      stub_remote(
        %{
          "alpha" => text("alpha", description: "Newer on GitHub."),
          "beta" => text("beta", description: "Theirs now."),
          "gamma" => text("gamma")
        },
        versions: %{"alpha" => 2, "beta" => 3, "gamma" => 1}
      )

      %{update: update, both: both, plain: plain}
    end

    test "count update and both-changed, not new; each chip carries its state", %{
      conn: conn,
      update: update,
      both: both,
      plain: plain
    } do
      view = open(conn, ~p"/playbooks")

      assert has_element?(view, "#playbook-github-notice", "2 updates on GitHub")
      assert has_element?(view, "#github-import-badge", "2")

      assert has_element?(
               view,
               "#sync-chip-#{update.id}[data-state='update']",
               "Update · v1 → v2"
             )

      assert has_element?(view, "#sync-chip-#{both.id}[data-state='both_changed']")
      refute has_element?(view, "#sync-chip-#{plain.id}")

      href = ~p"/playbooks?#{[github: "import", row: "playbooks/alpha.md"]}"
      assert has_element?(view, "#sync-chip-#{update.id}[href='#{href}']")
    end

    test "a status broadcast updates the chips on an open page", %{conn: conn, update: update} do
      view = open(conn, ~p"/playbooks")
      assert has_element?(view, "#sync-chip-#{update.id}")

      FakeRemote.put_file("playbooks/alpha.md", text("alpha"))
      {:ok, _status} = Canopy.Playbooks.Sharing.status(max_age: 0)

      render(view)
      refute has_element?(view, "#sync-chip-#{update.id}")
      assert has_element?(view, "#playbook-github-notice", "1 update on GitHub")
    end

    test "an open PR shows In PR #N, linked to it", %{conn: conn, plain: plain} do
      Repo.update_all(from(p in Playbook, where: p.id == ^plain.id),
        set: [
          pr_number: 14,
          pr_url: "https://github.com/acme/playbooks/pull/14",
          pr_path: "playbooks/delta.md",
          pr_version: 1,
          pr_sha: Canopy.Playbooks.Sharing.Text.content_hash(plain.body),
          pr_body: plain.body
        ]
      )

      stub_remote(%{"gamma" => text("gamma")}, prs: [%{number: 14, state: :open}])
      view = open(conn, ~p"/playbooks")

      assert has_element?(
               view,
               "#sync-chip-#{plain.id}[data-state='in_pr'][href='https://github.com/acme/playbooks/pull/14']",
               "In PR #14"
             )
    end
  end

  describe "first-run setup" do
    test "a pasted URL fills the fields; Continue saves and shows Import", %{conn: conn} do
      stub_remote(%{"gamma" => text("gamma")})
      view = open(conn, ~p"/playbooks?github=import")

      assert has_element?(view, "#sharing-setup-form")
      assert has_element?(view, "#sharing-setup-continue[disabled]")

      view
      |> form("#sharing-setup-form",
        sharing: %{repo: "https://github.com/acme/playbooks/tree/dev/pb"}
      )
      |> render_change(%{"_target" => ["sharing", "repo"]})

      assert has_element?(view, "#sharing-repo[value='acme/playbooks']")
      assert has_element?(view, "#sharing-branch[value='dev']")
      assert has_element?(view, "#sharing-folder[value='pb']")
      refute has_element?(view, "#sharing-check-ok")

      # the check runs once Repository loses focus
      view |> element("#sharing-repo") |> render_blur()
      render_async(view)
      assert has_element?(view, "#sharing-check-ok", "Connected as sbarber · can push")

      view
      |> form("#sharing-setup-form",
        sharing: %{repo: "acme/playbooks", branch: "", folder: "playbooks"}
      )
      |> render_submit()

      render_async(view)
      assert Settings.get().playbook_repo == "acme/playbooks"
      refute has_element?(view, "#sharing-setup-form")
      assert has_element?(view, "#import-ready", "gamma")
    end

    test "Continue with Repository blanked inside the debounce saves nothing", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")

      view
      |> form("#sharing-setup-form", sharing: %{repo: "", branch: "", folder: "playbooks"})
      |> render_submit()

      assert Canopy.Playbooks.Sharing.config() == :not_set_up
      assert has_element?(view, "#sharing-setup-continue[disabled]")
    end
  end

  describe "Import" do
    setup do
      configure_sharing()
      update = linked("alpha", 1)
      clash = create("eps", description: "Mine.")

      stub_remote(
        %{
          "alpha" => text("alpha", description: "Newer on GitHub."),
          "gamma" =>
            text("gamma",
              guidance: "Read **everything** first.",
              instructions: %{"work" => "Do it <script>alert(1)</script> well."}
            ),
          "eps" => text("eps", description: "Theirs.")
        },
        versions: %{"alpha" => 2, "gamma" => 3}
      )

      %{update: update, clash: clash}
    end

    test "Ready rows start ticked; Needs-a-look waits for a choice", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")

      assert has_element?(view, "#import-tick-#{dom("playbooks/gamma.md")}[checked]")
      assert has_element?(view, "#import-tick-#{dom("playbooks/alpha.md")}[checked]")
      assert has_element?(view, "#import-tick-#{dom("playbooks/eps.md")}[disabled]")
      assert has_element?(view, "#import-submit", "Import 2")

      assert has_element?(
               view,
               "#github-import-dialog-sub",
               "acme/playbooks › playbooks/ on main"
             )
    end

    test "an update since the cached read is ticked once the dialog reads", %{conn: conn} do
      linked("zeta", 1)
      FakeRemote.put_file("playbooks/zeta.md", text("zeta"))
      {:ok, _status} = Canopy.Playbooks.Sharing.status(max_age: 0)
      FakeRemote.put_file("playbooks/zeta.md", text("zeta", description: "Newer on GitHub."))

      view = open(conn, ~p"/playbooks?github=import")
      assert has_element?(view, "#import-ready #import-tick-#{dom("playbooks/zeta.md")}[checked]")
    end

    test "View shows a new playbook rendered, with Close and Import this", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")
      key = "playbooks/gamma.md"

      view |> element("#import-tick-#{dom(key)}") |> render_click()
      assert has_element?(view, "#import-submit", "Import 1")

      view |> element("#import-compare-#{dom(key)}", "View") |> render_click()
      render_async(view)

      assert has_element?(view, "#compare-dialog-title", "on GitHub · v3")
      assert has_element?(view, "#view-guidance strong", "everything")
      html = view |> element("#view-steps") |> render()
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      refute has_element?(view, "#compare-changes")
      refute has_element?(view, "#compare-file-diff")

      view |> element("#compare-import-this") |> render_click()
      refute has_element?(view, "#compare-dialog")
      assert has_element?(view, "#import-tick-#{dom(key)}[checked]")
      assert has_element?(view, "#import-submit", "Import 2")
    end

    test "Compare on an Update row says the versions, with Close and Import this", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")
      view |> element("#import-compare-#{dom("playbooks/alpha.md")}") |> render_click()
      render_async(view)

      assert has_element?(view, "#compare-dialog-sub", "GitHub has v2; yours is v1")
      assert has_element?(view, "#compare-changes")
      assert has_element?(view, "#compare-file-diff:not([open])")
      assert has_element?(view, "#compare-close")
      assert has_element?(view, "#compare-import-this")
    end

    test "Compare on a name clash, then Keep both, ticks the row with its copy name", %{
      conn: conn
    } do
      view = open(conn, ~p"/playbooks?github=import")
      key = "playbooks/eps.md"

      view |> element("#import-compare-#{dom(key)}", "Compare") |> render_click()
      render_async(view)

      assert has_element?(view, "#compare-dialog-sub", "Yours wasn't imported from this repo")
      # for a name clash, Keep both is the primary choice
      assert has_element?(view, "#compare-keep-both.btn-primary")

      view |> element("#compare-keep-both") |> render_click()
      refute has_element?(view, "#compare-dialog")
      assert has_element?(view, "#import-choice-#{dom(key)}", "Keep both")
      assert has_element?(view, "#import-as-#{dom(key)}", "eps-2")
      assert has_element?(view, "#import-tick-#{dom(key)}[checked]")
      assert has_element?(view, "#import-submit", "Import 3")

      view |> element("#import-submit") |> render_click()
      render_async(view)

      assert Playbooks.get_by_name("eps-2")
      assert has_element?(view, "#undo-toast", "Imported 3 playbooks")
    end

    test "Import N imports, closes, and Undo puts the library back", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")
      before = Playbooks.list() |> Enum.map(& &1.name) |> Enum.sort()

      view |> element("#import-submit") |> render_click()
      render_async(view)

      assert_patch(view, ~p"/playbooks")
      refute has_element?(view, "#github-import-dialog")
      assert has_element?(view, "#undo-toast", "Imported 2 playbooks")
      assert Playbooks.get_by_name("gamma")

      view |> element("#undo-delete") |> render_click()
      render_async(view)

      assert Playbooks.list() |> Enum.map(& &1.name) |> Enum.sort() == before
      refute has_element?(view, "#undo-toast")
    end

    test "a local edit since the dialog read is stale, and the dialog reads again", %{
      conn: conn,
      update: update
    } do
      view = open(conn, ~p"/playbooks?github=import")

      # an edit the page hasn't heard about yet
      Repo.update_all(from(p in Playbook, where: p.id == ^update.id), inc: [lock_version: 1])

      view |> element("#import-submit") |> render_click()
      render_async(view)

      assert has_element?(view, "#sharing-error[data-kind='stale']")
      assert has_element?(view, "#github-import-dialog")
    end

    test "with nothing ticked, Import is disabled and shows no count", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")

      for name <- ["alpha", "gamma"],
          do: view |> element("#import-tick-#{dom("playbooks/#{name}.md")}") |> render_click()

      assert has_element?(view, "#import-submit[disabled]")
      assert view |> element("#import-submit") |> render() =~ ~r/>\s*Import\s*</
    end

    test "Compare on a file that can't be read says why, and offers only Close", %{conn: conn} do
      FakeRemote.put_file("playbooks/bad.md", "not a playbook")
      view = open(conn, ~p"/playbooks?github=import")
      assert has_element?(view, "#import-cant", "bad")

      render_patch(view, ~p"/playbooks?github=import&compare=playbooks/bad.md")
      render_async(view)

      assert has_element?(view, "#compare-dialog-title", "playbooks/bad.md")
      assert has_element?(view, "#compare-error[data-kind='unreadable']", "Can't read this file")
      assert has_element?(view, "#compare-error .font-mono")
      assert has_element?(view, "#compare-error", "until then it's listed under Can't import.")
      refute has_element?(view, "#compare-dialog", "Something changed")

      refute has_element?(view, "#compare-take")
      refute has_element?(view, "#compare-keep-both")
      refute has_element?(view, "#compare-skip")
      assert has_element?(view, "#compare-close", "Close")
    end

    test "Compare's choices wait for the diff; Skip doesn't", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")
      key = "playbooks/eps.md"
      FakeRemote.hold(:last_commit)

      view |> element("#import-compare-#{dom(key)}", "Compare") |> render_click()

      assert has_element?(view, "#compare-loading")

      for id <- ["compare-take", "compare-keep-both"],
          do: assert(has_element?(view, "##{id}[disabled][title='Loading the comparison…']"))

      assert has_element?(view, "#compare-skip:not([disabled])")

      FakeRemote.release(:last_commit)
      render_async(view)

      assert has_element?(view, "#compare-changes")
      assert has_element?(view, "#compare-take:not([disabled]):not([title])")
      assert has_element?(view, "#compare-keep-both:not([disabled])")
    end

    test "Compare's choices stay disabled when it fails; Skip and Close don't", %{conn: conn} do
      for {path, id} <- [
            {"/playbooks?github=import&compare=playbooks/eps.md", "compare-keep-both"},
            {"/playbooks?github=import&compare=playbooks/alpha.md", "compare-import-this"}
          ] do
        FakeRemote.fail(:account, nil)
        {:ok, _status} = Canopy.Playbooks.Sharing.status(max_age: 0)
        FakeRemote.fail(:account, :gh_signed_out)

        view = open(conn, path)

        assert has_element?(view, "#compare-error[data-kind='gh_signed_out']")
        # Compare has no Check again of its own
        assert has_element?(view, "#compare-error", "then close this and Compare again.")
        assert has_element?(view, "##{id}[disabled][title='Loading the comparison…']")
        assert has_element?(view, "#compare-skip:not([disabled]), #compare-close:not([disabled])")
      end
    end

    test "a failed read leaves the dialog open with gh's own words", %{conn: conn} do
      stub_remote(%{"gamma" => text("gamma")}, fail: [account: :gh_signed_out])
      view = open(conn, ~p"/playbooks?github=import")

      assert has_element?(view, "#sharing-error[data-kind='gh_signed_out']", "gh isn't signed in")
      assert has_element?(view, "#sharing-error .font-mono", "not logged into any GitHub hosts")
      assert has_element?(view, "#sharing-error-retry")
    end

    test "the section headings put the count after the name", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")

      # LiveViewTest drops the whitespace-only text between the spans; a browser keeps it
      assert view |> element("#import-ready-heading") |> render() |> text_of() =~
               ~r/^Ready \d+ ?· checked for you$/

      assert view |> element("#import-look-heading") |> render() |> text_of() =~
               ~r/^Needs a look \d+ ?· compare, then choose$/
    end

    test "a Needs-a-look box is locked until a choice, and says so", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=import")
      tick = "#import-tick-#{dom("playbooks/eps.md")}"

      assert has_element?(view, "#{tick}[disabled].opacity-40.cursor-not-allowed")
      assert has_element?(view, "#{tick}[title='Compare first, then choose']")
      assert has_element?(view, "label[for='#{String.trim_leading(tick, "#")}'][title]")

      view |> element("#import-compare-#{dom("playbooks/eps.md")}", "Compare") |> render_click()
      render_async(view)
      view |> element("#compare-keep-both") |> render_click()

      assert has_element?(view, "#{tick}:not([disabled]):not(.opacity-40):not([title])")
    end
  end

  describe "import names" do
    test "new files whose name is taken show the copy name they'll import as", %{conn: conn} do
      configure_sharing()
      # xy follows another file here, so playbooks/xy.md and the second xy pair with nothing
      x = create("xy")
      link_playbook(x, "playbooks/xy-old.md", 1, x.body)

      stub_remote(%{
        "playbooks/xy.md" => text("xy", description: "One."),
        "playbooks/zz.md" => text("xy", description: "Two.")
      })

      view = open(conn, ~p"/playbooks?github=import")

      assert has_element?(view, "#import-as-#{dom("playbooks/xy.md")}", "imports as xy-2")
      assert has_element?(view, "#import-as-#{dom("playbooks/zz.md")}", "imports as xy-3")

      view |> element("#import-submit") |> render_click()
      render_async(view)

      assert Playbooks.get_by_name("xy-2")
      assert Playbooks.get_by_name("xy-3")
    end

    test "Keep both names its copy after the new files in the same import", %{conn: conn} do
      configure_sharing()
      create("eps", description: "Mine.")

      stub_remote(%{
        "eps" => text("eps", description: "Theirs."),
        "eps-2" => text("eps-2")
      })

      view = open(conn, ~p"/playbooks?github=import")
      key = "playbooks/eps.md"

      view |> element("#import-compare-#{dom(key)}", "Compare") |> render_click()
      render_async(view)
      assert has_element?(view, "#compare-dialog", "Keep both adds GitHub's copy as eps-3")

      view |> element("#compare-keep-both") |> render_click()
      assert has_element?(view, "#import-as-#{dom(key)}", "Will import as eps-3")

      view |> element("#import-submit") |> render_click()
      render_async(view)

      assert Playbooks.get_by_name("eps-2")
      assert Playbooks.get_by_name("eps-3")
    end
  end

  describe "Export" do
    setup do
      configure_sharing()
      edited = linked("alpha", 2)

      {:ok, edited} =
        Playbooks.update(edited, %{body: text("alpha", description: "Edited here.")})

      fresh = create("omega")
      behind = linked("beta", 1)

      stub_remote(
        %{"alpha" => text("alpha"), "beta" => text("beta", description: "Newer.")},
        versions: %{"alpha" => 2, "beta" => 2}
      )

      %{edited: edited, fresh: fresh, behind: behind}
    end

    test "edited rows start ticked; new ones don't; GitHub-newer ones can't export", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=export")

      assert has_element?(view, "#export-tick-#{dom("playbooks/alpha.md")}[checked]")

      [fresh_key] =
        Canopy.Playbooks.Sharing.cached_status()
        |> elem(1)
        |> Map.fetch!(:entries)
        |> Enum.filter(&(&1.state == :not_on_github))
        |> Enum.map(& &1.key)

      assert has_element?(view, "#export-tick-#{dom(fresh_key)}:not([checked])")
      assert has_element?(view, "#export-cant", "GitHub is newer (v2)")
      assert has_element?(view, "#export-branch", "→ main")
      assert has_element?(view, "#export-pr-form_title[value='Update alpha (v3)']")
    end

    test "Open pull request sends the ticked playbooks and shows the toast", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=export")
      [_, branch] = Regex.run(~r/Branch <span class="font-mono">([^<]+)</, render(view))

      view
      |> form("#export-pr-form", pr: %{title: "Share alpha", note: "For the team."})
      |> render_submit()

      render_async(view)

      # on the branch the footer showed
      assert [
               %{
                 title: "Share alpha",
                 body: body,
                 branch: ^branch,
                 files: [%{path: "playbooks/alpha.md"}]
               }
             ] = FakeRemote.opened_prs()

      assert body =~ "For the team."
      assert has_element?(view, "#pr-toast", "Opened PR #1 on acme/playbooks")
      assert has_element?(view, "#pr-toast", "1 playbook. It shows In PR #1 until it's merged.")
      assert has_element?(view, "#pr-toast-branch", branch)
      assert has_element?(view, "#pr-toast-link[href='https://github.com/acme/playbooks/pull/1']")
      refute has_element?(view, "#github-export-dialog")
    end

    test "the toast's grammar follows the count, and names the branch GitHub took" do
      toast = %{number: 4, url: "u", repo: "acme/playbooks", count: 2, branch: "canopy/x-2"}
      html = render_component(&CanopyWeb.PlaybookSharingComponents.pr_toast/1, toast: toast)

      assert html =~ "2 playbooks. They show In PR #4 until it's merged."
      assert html =~ "canopy/x-2"
    end

    test "a failed read still prefills the title from the page's last read", %{conn: conn} do
      {:ok, _status} = Canopy.Playbooks.Sharing.status(max_age: 0)
      FakeRemote.fail(:account, :gh_signed_out)

      view = open(conn, ~p"/playbooks?github=export")

      assert has_element?(view, "#sharing-error[data-kind='gh_signed_out']")
      assert has_element?(view, "#export-pr-form_title[value='Update alpha (v3)']")
    end

    test "opening and closing a dialog leaves Drafts as the user left it", %{
      conn: conn,
      fresh: fresh
    } do
      Repo.update_all(from(p in Playbook, where: p.id == ^fresh.id), set: [enabled: false])
      view = open(conn, ~p"/playbooks")

      view |> element("#toggle-drafts") |> render_click()
      assert has_element?(view, "#toggle-drafts[aria-expanded='true']")

      render_patch(view, ~p"/playbooks?github=export")
      render_async(view)
      render_patch(view, ~p"/playbooks")
      assert has_element?(view, "#toggle-drafts[aria-expanded='true']")
    end

    test "the title follows the ticks until typed in", %{conn: conn, fresh: fresh} do
      view = open(conn, ~p"/playbooks?github=export")
      key = "local:#{fresh.id}"

      view |> element("#export-tick-#{dom(key)}") |> render_click()

      assert has_element?(
               view,
               "#export-pr-form_title[value='Update alpha (v3), add omega (v1)']"
             )

      view
      |> form("#export-pr-form", pr: %{title: "My title"})
      |> render_change(%{"_target" => ["pr", "title"]})

      view |> element("#export-tick-#{dom(key)}") |> render_click()
      assert has_element?(view, "#export-pr-form_title[value='My title']")
    end

    test "the ticked Edited rows come first, before new ones earlier by name", %{conn: conn} do
      create("aardvark")
      view = open(conn, ~p"/playbooks?github=export")

      states =
        Regex.scan(
          ~r/id="export-row-[^"]+" data-state="(\w+)"/,
          view |> element("#export-changed") |> render()
        )
        |> Enum.map(fn [_, state] -> state end)

      assert states == ["edited", "not_on_github", "not_on_github"]
    end

    test "a failed pull request offers no Check again: Open pull request is the retry", %{
      conn: conn
    } do
      view = open(conn, ~p"/playbooks?github=export")
      FakeRemote.fail(:open_pr, :pr_failed)

      view |> form("#export-pr-form", pr: %{title: "Share alpha"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#sharing-error[data-kind='pr_failed']")
      refute has_element?(view, "#sharing-error-retry")
      assert has_element?(view, "#export-submit:not([disabled])")
    end

    test "with nothing ticked, Open pull request is disabled and says why", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=export")
      view |> element("#export-tick-#{dom("playbooks/alpha.md")}") |> render_click()

      assert has_element?(view, "#export-submit[disabled][title='Tick at least one playbook']")
      assert has_element?(view, "#export-pr-form_title[value='']")
    end

    test "without push access, Import only, and no export", %{conn: conn} do
      FakeRemote.set_push(false)
      view = open(conn, ~p"/playbooks?github=export")

      assert has_element?(view, "#export-read-only", "Import only")
      assert has_element?(view, "#export-submit[disabled]")
    end

    test "a change on GitHub since the dialog read is stale", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=export")
      FakeRemote.put_file("playbooks/alpha.md", text("alpha", description: "Someone else."))

      view |> form("#export-pr-form", pr: %{title: "Share alpha"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#sharing-error[data-kind='stale']")
      assert FakeRemote.opened_prs() == []
    end

    test "while the PR opens, the dialog can't be closed", %{conn: conn} do
      view = open(conn, ~p"/playbooks?github=export")
      assert has_element?(view, "#github-export-dialog[phx-window-keydown]")

      FakeRemote.hold(:open_pr)
      view |> form("#export-pr-form", pr: %{title: "Share alpha"}) |> render_submit()

      assert has_element?(view, "#export-submit", "Opening pull request…")
      assert has_element?(view, "#github-export-dialog input[phx-click=tick][disabled]")
      refute has_element?(view, "#github-export-dialog input[phx-click=tick]:not([disabled])")
      refute has_element?(view, "#github-export-dialog[phx-window-keydown]")
      refute has_element?(view, "#github-export-dialog-panel[phx-click-away]")

      FakeRemote.release(:open_pr)
      render_async(view)
      assert has_element?(view, "#pr-toast")
    end

    test "a local edit shows up in an open Export dialog", %{conn: conn, behind: behind} do
      view = open(conn, ~p"/playbooks?github=export")
      refute has_element?(view, "#export-cant [data-state='both_changed']")

      {:ok, _} = Playbooks.update(behind, %{body: text("beta", description: "Mine.")})
      render(view)

      assert has_element?(
               view,
               "#export-row-#{dom("playbooks/beta.md")}[data-state='both_changed']"
             )
    end
  end

  describe "the branch" do
    test "a blank branch shows the one GitHub resolved", %{conn: conn} do
      configure_sharing()
      stub_remote(%{"gamma" => text("gamma")}, default_branch: "trunk")
      view = open(conn, ~p"/playbooks?github=import")

      assert has_element?(view, "#sharing-where", "on trunk")

      assert has_element?(
               view,
               "#github-open-repo[href='https://github.com/acme/playbooks/tree/trunk/playbooks']"
             )
    end
  end
end
