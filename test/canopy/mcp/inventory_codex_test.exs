defmodule Canopy.MCP.InventoryCodexTest do
  @moduledoc "§10: the Codex adapter's MCP inventory, from Codex config files in a tmp dir."
  use Canopy.DataCase, async: false

  alias Canopy.{AgentSessions, Fixtures}
  alias Canopy.Codex.McpConfig
  alias Canopy.Engine.Codex
  alias Canopy.MCP.Inventory

  @moduletag :tmp_dir

  @user_config """
  [shell_environment_policy]
  exclude = ["AWS_*", "*_SECRET"]

  [mcp_servers.docs]
  command = "docs-mcp"
  args = ["--verbose"]
  env = { DOCS_API_KEY = "sk_fixtureEnvSecret" }

  [mcp_servers.canopy]
  command = "old-canopy"
  args = ["serve"]

  [mcp_servers.remote]
  url = "https://remote.example.com/mcp"
  bearer_token_env_var = "REMOTE_TOKEN"
  """

  @project_config """
  [mcp_servers.proj]
  command = "proj-mcp"
  """

  setup %{tmp_dir: dir} do
    config_dir = Path.join(dir, "codex-home")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, "config.toml"), @user_config)

    scenario = Fixtures.scenario()
    repo = scenario.repository
    File.mkdir_p!(Path.join(repo.path, ".codex"))
    File.write!(Path.join(repo.path, ".codex/config.toml"), @project_config)
    File.write!(Path.join(repo.path, ".mcp.json"), ~s({"mcpServers":{"x":{"command":"x"}}}))

    {:ok, Map.merge(scenario, %{config_dir: config_dir, repo: repo})}
  end

  defp inventory(ctx, opts \\ []) do
    assert {:ok, %Inventory.Engine{} = inv} =
             Codex.mcp_inventory(ctx.repo, Keyword.put_new(opts, :config_dir, ctx.config_dir))

    inv
  end

  test "Canopy's server first, then the user's, then the project's", ctx do
    inv = inventory(ctx)
    assert inv.engine == "codex"
    assert Enum.map(inv.servers, & &1.name) == ["canopy", "docs", "remote", "proj"]
    assert inv.notes == []

    [canopy, docs, remote, proj] = inv.servers

    assert canopy.source == %{kind: :canopy, path: nil}
    assert canopy.transport == :http
    assert canopy.secrets == ["CANOPY_MCP_TOKEN"]
    assert canopy.target =~ "/mcp"

    assert canopy.note ==
             "Per-session token through bearer_token_env_var; Canopy's tools never ask."

    user_path = Path.join(ctx.config_dir, "config.toml")
    assert docs.source == %{kind: :user, path: user_path}
    assert docs.note == "From your Codex config."
    assert docs.transport == :stdio
    assert docs.target =~ "docs-mcp"
    assert "DOCS_API_KEY" in docs.secrets
    refute docs.target =~ "sk_fixtureEnvSecret"

    assert remote.transport == :http
    assert remote.target == "https://remote.example.com/mcp"
    assert "REMOTE_TOKEN" in remote.secrets
    assert remote.note == "From your Codex config."

    assert proj.source == %{kind: :project, path: Path.join(ctx.repo.path, ".codex/config.toml")}
    assert proj.note == "Loaded when Codex trusts this project."
  end

  test "a user server named canopy and the repository's .mcp.json are ignored", ctx do
    inv = inventory(ctx)
    assert [clash, mcp_json] = inv.ignored

    assert clash.name == "canopy"
    assert clash.source == %{kind: :user, path: Path.join(ctx.config_dir, "config.toml")}
    assert clash.target =~ "old-canopy"

    assert clash.note ==
             "Codex can't load Canopy's own server while this one has the same name; rename it."

    assert mcp_json.name == ".mcp.json"
    assert mcp_json.enabled? == false
    assert mcp_json.source == %{kind: :project, path: Path.join(ctx.repo.path, ".mcp.json")}
    assert mcp_json.note == "Claude Code's format; Codex reads .codex/config.toml."
  end

  test "the newest turn's reported status", ctx do
    coder = Fixtures.agent_fixture(%{engine: "codex"})

    session =
      Fixtures.session_fixture(%{channel: ctx.channel, agent_id: coder.id, engine: "codex"})

    :ok =
      AgentSessions.record_mcp_servers(session, [
        %{name: "canopy", status: "connected", tool_count: nil},
        %{name: "docs", status: "failed", tool_count: nil}
      ])

    [canopy, docs, remote, _proj] = inventory(ctx).servers
    assert canopy.status == :connected
    assert %DateTime{} = canopy.observed_at
    assert docs.status == :failed
    assert remote.status == :unknown
    assert remote.observed_at == nil
  end

  test "an unparseable config becomes a note, without its contents", ctx do
    File.write!(Path.join(ctx.config_dir, "config.toml"), "[mcp_servers.docs\nsecret = \"sk_x\"")

    inv = inventory(ctx)
    assert Enum.map(inv.servers, & &1.name) == ["canopy", "proj"]
    assert [note] = inv.notes
    assert note =~ "config.toml"
    assert note =~ "not valid TOML"
    refute note =~ "sk_x"
    # the project's .mcp.json is still listed
    assert [%{name: ".mcp.json"}] = inv.ignored
  end

  test "a missing config dir or project config is empty, not an error", ctx do
    File.rm!(Path.join(ctx.repo.path, ".codex/config.toml"))
    File.rm!(Path.join(ctx.repo.path, ".mcp.json"))

    inv = inventory(ctx, config_dir: Path.join(ctx.tmp_dir, "nope"))
    assert Enum.map(inv.servers, & &1.name) == ["canopy"]
    assert inv.ignored == []
    assert inv.notes == []
  end

  describe "McpConfig" do
    test "read/1, servers/1 and shell_exclude/1", ctx do
      assert {:ok, config} = McpConfig.read(Path.join(ctx.config_dir, "config.toml"))
      assert McpConfig.shell_exclude(config) == ["AWS_*", "*_SECRET"]
      assert config |> McpConfig.servers() |> Map.keys() |> Enum.sort() == ~w(canopy docs remote)

      assert McpConfig.read(Path.join(ctx.tmp_dir, "missing.toml")) == {:ok, %{}}
      assert McpConfig.shell_exclude(%{}) == []

      assert McpConfig.shell_exclude(%{"shell_environment_policy" => %{"exclude" => ["A", 1]}}) ==
               ["A"]

      assert McpConfig.servers(%{"mcp_servers" => %{"a" => %{}, "b" => "nope"}}) == %{"a" => %{}}
    end

    test "canopy_clash/2: the user's config, then the project's", ctx do
      user_path = Path.join(ctx.config_dir, "config.toml")

      assert McpConfig.canopy_clash(ctx.config_dir) ==
               {:error,
                "#{user_path} defines an MCP server named canopy; rename it so Canopy's own can load"}

      File.write!(user_path, "[mcp_servers.docs]\ncommand = \"docs\"\n")
      assert McpConfig.canopy_clash(ctx.config_dir) == :ok
      assert McpConfig.canopy_clash(ctx.config_dir, ctx.repo.path) == :ok

      project_path = Path.join(ctx.repo.path, ".codex/config.toml")
      File.write!(project_path, "[mcp_servers.canopy]\nurl = \"http://x\"\n")

      assert {:error, message} = McpConfig.canopy_clash(ctx.config_dir, ctx.repo.path)
      assert message =~ project_path
      assert message =~ "defines an MCP server named canopy"
    end

    test "an unreadable config is not a clash", ctx do
      File.write!(Path.join(ctx.config_dir, "config.toml"), "not = [valid")
      assert McpConfig.canopy_clash(ctx.config_dir) == :ok
    end

    test "codex_home/1 and the paths", ctx do
      assert McpConfig.codex_home(ctx.config_dir) == ctx.config_dir
      # tests point the default at a fixture dir, never ~/.codex
      assert McpConfig.codex_home(nil) ==
               Keyword.fetch!(Application.get_env(:canopy, :codex), :default_config_dir)

      assert McpConfig.user_path("/c") == "/c/config.toml"
      assert McpConfig.project_path("/r") == "/r/.codex/config.toml"
    end
  end
end
