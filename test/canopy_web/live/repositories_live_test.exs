defmodule CanopyWeb.RepositoriesLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Repositories, Runtime, Settings}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global
  setup :verify_on_exit!

  # `Fixtures.git_dir_fixture/0` lives under the project's `_build`, which is inside
  # the home directory; this one is in the system temp dir, outside it.
  defp outside_home_git_dir do
    path = Path.join(System.tmp_dir!(), "canopy-lv-" <> Fixtures.unique_suffix())
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", path])
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "renders the empty state without repositories", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/repositories")

    assert has_element?(view, "#repositories-empty")
    assert has_element?(view, "#repository-form")
  end

  test "lists registered repositories with their branch", %{conn: conn} do
    repository = Fixtures.repository_fixture()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    assert has_element?(view, "#repository-#{repository.id}", repository.name)
    assert has_element?(view, "#repository-#{repository.id}", "main")
    assert has_element?(view, "#sidebar-repo-#{repository.id}")
  end

  test "adds a git repository inside the home directory", %{conn: conn} do
    path = Fixtures.git_dir_fixture()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form", repository: %{path: path, name: "My Project"})
    |> render_submit()

    assert %{name: "My Project"} = repository = Repositories.get_by_path(path)
    assert has_element?(view, "#repository-#{repository.id}", "My Project")
    assert has_element?(view, "#sidebar-repo-#{repository.id}")
    refute has_element?(view, "#repositories-empty")
    # The form is reset for the next entry.
    refute has_element?(view, "#repository-form input[name='repository[path]'][value='#{path}']")
  end

  test "rejects a path that does not exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form",
      repository: %{path: "/definitely/not/here"},
      allow_outside_home: "true"
    )
    |> render_submit()

    assert has_element?(view, "#repository-form", "does not exist")
    assert Repositories.list() == []
  end

  test "initialises a directory that is not a git repository yet", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "canopy-plain-" <> Fixtures.unique_suffix())
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form", repository: %{path: path}, allow_outside_home: "true")
    |> render_submit()

    assert render(view) =~ "so one was initialised"
    assert File.dir?(Path.join(path, ".git"))
    assert [%{path: ^path}] = Repositories.list()
  end

  test "rejects a path outside the home directory unless allowed", %{conn: conn} do
    path = outside_home_git_dir()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view
    |> form("#repository-form", repository: %{path: path})
    |> render_submit()

    assert has_element?(view, "#repository-form", "must be inside your home directory")
    assert Repositories.list() == []

    view
    |> form("#repository-form", repository: %{path: path}, allow_outside_home: "true")
    |> render_submit()

    assert %{} = repository = Repositories.get_by_path(path)
    assert has_element?(view, "#repository-#{repository.id}")
  end

  test "deletes a repository", %{conn: conn} do
    repository = Fixtures.repository_fixture()
    {:ok, view, _html} = live(conn, ~p"/repositories")

    view |> element("#delete-repository-#{repository.id}") |> render_click()

    refute has_element?(view, "#repository-#{repository.id}")
    refute has_element?(view, "#sidebar-repo-#{repository.id}")
    assert Repositories.list() == []
  end

  describe "a repository's MCP servers" do
    @claude_fixtures Path.expand("../../support/mcp_fixtures/claude", __DIR__)

    setup do
      repository = Fixtures.repository_fixture()

      File.cp!(
        Path.join([@claude_fixtures, "repo", ".mcp.json"]),
        Path.join(repository.path, ".mcp.json")
      )

      stub(OC, :mcp_status, fn _dir, _opts ->
        {:ok,
         %{
           "canopy" => %{"status" => "connected"},
           "flaky" => %{
             "status" => "failed",
             "error" => "connect ECONNREFUSED http://user:pw_liveSecret@flaky.example.com/mcp"
           }
         }}
      end)

      stub(OC, :config, fn _dir, _opts ->
        {:ok,
         %{
           "mcp" => %{
             "flaky" => %{
               "type" => "local",
               "command" => ["flaky-mcp"],
               "environment" => %{"FLAKY_TOKEN" => "ft_liveSecret"}
             }
           }
         }}
      end)

      {:ok, repository: repository}
    end

    test "the list row links to the repository page", %{conn: conn, repository: repository} do
      {:ok, view, _html} = live(conn, ~p"/repositories")

      assert has_element?(view, "#repository-mcp-#{repository.id}")

      {:ok, view, _html} =
        view
        |> element("#repository-mcp-#{repository.id}")
        |> render_click()
        |> follow_redirect(conn, ~p"/repositories/#{repository.id}")

      assert has_element?(view, "#repository-mcp-panel")
    end

    test "shows both engines, a failed server's badge, and no secrets", %{
      conn: conn,
      repository: repository
    } do
      {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}")
      render_async(view)

      assert has_element?(view, "#mcp-engine-opencode")
      assert has_element?(view, "#mcp-engine-claude_code")

      # no agent uses either engine here: both start collapsed
      refute has_element?(view, "#mcp-servers-opencode")
      view |> element("#mcp-engine-opencode-toggle") |> render_click()
      view |> element("#mcp-engine-claude_code-toggle") |> render_click()

      assert has_element?(view, "#mcp-server-opencode-canopy [data-status='connected']")
      assert has_element?(view, "#mcp-server-opencode-flaky [data-status='failed']")
      assert has_element?(view, "#mcp-server-opencode-flaky", "http://flaky.example.com/mcp")
      assert has_element?(view, "#mcp-reconnect-flaky")

      # Claude Code loads the repository's .mcp.json; personal servers are listed apart
      assert has_element?(view, "#mcp-server-claude_code-github")
      assert has_element?(view, "#mcp-server-claude_code-docs")
      assert has_element?(view, "#mcp-claude-security")
      assert has_element?(view, "#mcp-ignored-claude_code-personal")
      assert has_element?(view, "#mcp-ignored-claude_code-canopy")

      html = render(view)
      token = Settings.mcp_token()
      assert has_element?(view, "#mcp-token", String.slice(token, -4, 4))
      refute html =~ token

      for secret <- ~w(ghp_ sk_fixture docs-pass pw_liveSecret ft_liveSecret pk_fixture),
          do: refute(html =~ secret)
    end

    test "an engine an agent uses starts expanded", %{conn: conn, repository: repository} do
      Fixtures.channel_fixture(%{repository_id: repository.id})

      {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}")
      render_async(view)

      assert has_element?(view, "#mcp-servers-opencode")
      refute has_element?(view, "#mcp-servers-claude_code")
    end

    test "a malformed .mcp.json shows its parse error", %{conn: conn, repository: repository} do
      File.write!(Path.join(repository.path, ".mcp.json"), "{ broken")

      {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}")
      render_async(view)
      view |> element("#mcp-engine-claude_code-toggle") |> render_click()

      assert has_element?(view, "#mcp-notes-claude_code", "invalid JSON")
    end

    test "Refresh and a token rotation ask again", %{conn: conn, repository: repository} do
      {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}")
      render_async(view)
      before = render(view)

      {:ok, _} = Settings.rotate_mcp_token()
      _ = :sys.get_state(view.pid)
      render_async(view)

      new_token = Settings.mcp_token()
      assert has_element?(view, "#mcp-token", String.slice(new_token, -4, 4))
      assert before != render(view)

      view |> element("#refresh-mcp") |> render_click()
      render_async(view)
      assert has_element?(view, "#mcp-engine-opencode")
    end

    test "Re-register, Reconnect, and Reinstall call OpenCode", %{
      conn: conn,
      repository: repository
    } do
      Fixtures.channel_fixture(%{repository_id: repository.id})
      dir = repository.path

      {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}")
      render_async(view)

      expect(OC, :add_mcp, fn ^dir, "canopy", _config, _opts -> {:ok, %{}} end)
      view |> element("#mcp-reregister") |> render_click()
      assert render(view) =~ "re-registered"
      render_async(view)

      expect(OC, :mcp_connect, fn ^dir, "flaky", _opts -> {:ok, true} end)
      view |> element("#mcp-reconnect-flaky") |> render_click()
      assert render(view) =~ "reconnected flaky"
      render_async(view)

      expect(OC, :dispose_instance, fn ^dir, _opts -> {:ok, true} end)
      expect(OC, :add_mcp, fn ^dir, "canopy", _config, _opts -> {:ok, %{}} end)
      view |> element("#mcp-reinstall-plugin") |> render_click()
      assert render(view) =~ "Identity plugin reinstalled"
    end

    test "Reinstall is disabled while an agent is busy in the repository", %{
      conn: conn,
      repository: repository
    } do
      dir = Path.join([File.cwd!(), "_build", "test", "tmp", "busy-" <> Fixtures.unique_suffix()])
      File.mkdir_p!(dir)
      script = Path.join(dir, "script.jsonl")

      File.write!(
        script,
        JSON.encode!(%{type: "system", subtype: "init", session_id: "SESSION_ID"}) <> "\n"
      )

      previous = Application.get_env(:canopy, :claude_code)

      Application.put_env(
        :canopy,
        :claude_code,
        Keyword.put(previous, :env, [{"FAKE_CLAUDE_SCRIPT", script}, {"FAKE_CLAUDE_SLEEP", "5"}])
      )

      coder = Fixtures.agent_fixture(%{engine: "claude_code"})

      channel =
        Fixtures.channel_fixture(%{repository_id: repository.id, agent_ids: [coder.id]})

      Canopy.Timeline.subscribe(channel.id)
      {:ok, _} = Runtime.ensure_channel(channel.id, start_stream: false)

      on_exit(fn ->
        Runtime.stop_channel(channel.id)
        Application.put_env(:canopy, :claude_code, previous)
        File.rm_rf!(dir)
      end)

      {:ok, _} = Runtime.post_user_message(channel.id, "@#{coder.name} take your time")
      assert_receive {:timeline, %{event_type: "agent_started"}}, 5_000

      {:ok, view, _html} = live(conn, ~p"/repositories/#{repository.id}")
      render_async(view)

      assert has_element?(view, "#mcp-reinstall-plugin[disabled]")
      assert has_element?(view, "#mcp-reregister")

      Runtime.abort(channel.id, coder.id)
    end
  end
end
