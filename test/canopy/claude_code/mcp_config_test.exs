defmodule Canopy.ClaudeCode.MCPConfigTest do
  use ExUnit.Case, async: true

  alias Canopy.ClaudeCode.MCPConfig

  @fixtures Path.expand("../../support/mcp_fixtures/claude", __DIR__)

  # A temp home whose .claude.json names `repo` in its projects map.
  defp home_for(repo) do
    home =
      Path.join(System.tmp_dir!(), "canopy-claude-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    text = File.read!(Path.join([@fixtures, "home", ".claude.json"]))
    File.write!(Path.join(home, ".claude.json"), String.replace(text, "REPO_PATH", repo))
    home
  end

  describe "project_servers/1" do
    test "reads the repository's .mcp.json servers as written" do
      assert {:ok, servers} = MCPConfig.project_servers(Path.join(@fixtures, "repo"))
      assert Map.keys(servers) |> Enum.sort() == ["canopy", "docs", "github"]
      assert servers["github"]["command"] == "npx"
      assert servers["docs"]["type"] == "http"
    end

    test "no file is no servers" do
      assert MCPConfig.project_servers(Path.join(@fixtures, "home")) == {:ok, %{}}
    end

    test "a malformed file is an error that quotes no content" do
      assert {:error, reason} = MCPConfig.project_servers(Path.join(@fixtures, "broken"))
      assert reason =~ "invalid JSON"
      refute reason =~ "half"
    end

    test "wrong shapes are errors" do
      assert {:error, _} = MCPConfig.parse_servers(~s({"mcpServers": []}))
      assert {:error, _} = MCPConfig.parse_servers(~s({"mcpServers": {"a": "b"}}))
      assert {:error, _} = MCPConfig.parse_servers(~s([1]))
      assert MCPConfig.parse_servers(~s({"other": 1})) == {:ok, %{}}
    end
  end

  describe "other_sources/2" do
    test "user and local scope from .claude.json, nothing else from it" do
      repo = Path.join(@fixtures, "repo")
      home = home_for(repo)

      {entries, errors} =
        MCPConfig.other_sources(repo, home: home, managed_path: "/nonexistent/managed.json")

      assert errors == []

      assert [
               %{name: "local-db", kind: :local},
               %{name: "personal", kind: :user}
             ] = entries

      # another project's servers and the rest of the file are not kept
      refute Enum.any?(entries, &(&1.name == "elsewhere"))
      refute inspect(entries) =~ "oat_fixtureNeverShown"
    end

    test "a configured CLAUDE_CONFIG_DIR replaces the home .claude.json" do
      repo = Path.join(@fixtures, "repo")
      config_dir = home_for(repo)

      {entries, []} =
        MCPConfig.other_sources(repo,
          home: "/nonexistent-home",
          config_dir: config_dir,
          managed_path: "/nonexistent/managed.json"
        )

      assert Enum.map(entries, & &1.name) == ["local-db", "personal"]
    end

    test "managed config is listed; a broken file becomes an error, not a crash" do
      repo = Path.join(@fixtures, "repo")

      {entries, errors} =
        MCPConfig.other_sources(repo,
          home: Path.join(@fixtures, "broken"),
          managed_path: Path.join([@fixtures, "repo", ".mcp.json"])
        )

      assert Enum.all?(entries, &(&1.kind == :managed))
      assert "canopy" in Enum.map(entries, & &1.name)
      assert errors == []

      broken_home =
        Path.join(System.tmp_dir!(), "canopy-broken-#{System.unique_integer([:positive])}")

      File.mkdir_p!(broken_home)
      on_exit(fn -> File.rm_rf!(broken_home) end)
      File.write!(Path.join(broken_home, ".claude.json"), "{nope")

      assert {[], [error]} =
               MCPConfig.other_sources(repo, home: broken_home, managed_path: "/nonexistent")

      assert error =~ ".claude.json: invalid JSON"
    end
  end

  describe "to_server/3" do
    test "redacts the command, the URL, and lists secret keys" do
      {:ok, servers} = MCPConfig.project_servers(Path.join(@fixtures, "repo"))

      github = MCPConfig.to_server("github", servers["github"], %{kind: :project, path: nil})
      assert github.transport == :stdio
      assert github.target =~ "npx -y @modelcontextprotocol/server-github --token ••••"
      assert github.secrets == ["GITHUB_TOKEN"]

      docs = MCPConfig.to_server("docs", servers["docs"], %{kind: :project, path: nil})
      assert docs.transport == :http
      assert docs.target == "https://mcp.example.com/mcp?api_key=••••"
      assert docs.secrets == ["Authorization"]

      for secret <- ~w(ghp_fixture sk_fixture docs-pass),
          do: refute(inspect([github, docs]) =~ secret)
    end
  end
end
