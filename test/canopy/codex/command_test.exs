defmodule Canopy.Codex.CommandTest do
  use ExUnit.Case, async: true

  alias Canopy.Codex.Command

  @modes [
    "default",
    "acceptEdits",
    "plan",
    nil,
    "",
    "bypassPermissions",
    "PLAN",
    "junk",
    42,
    :plan
  ]

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        binary: "/usr/local/bin/codex",
        cwd: "/repo",
        stderr_file: "/tmp/canopy-codex/s/stderr.log",
        mcp_url: "http://127.0.0.1:4000/mcp",
        token: "tok-secret-123"
      ],
      extra
    )
  end

  # The `-c` overrides as {key, raw TOML value}.
  defp overrides(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["-c", kv] ->
        [key, value] = String.split(kv, "=", parts: 2)
        [{key, value}]

      _ ->
        []
    end)
  end

  defp override(args, key),
    do: args |> overrides() |> List.keyfind(key, 0) |> then(&(&1 && elem(&1, 1)))

  describe "policy/1" do
    test "the table" do
      assert Command.policy("plan") == {"read-only", "on-request"}
      assert Command.policy("acceptEdits") == {"workspace-write", "on-request"}
      assert Command.policy("default") == {"workspace-write", "untrusted"}
      assert Command.policy(nil) == {"workspace-write", "untrusted"}
      assert Command.policy("junk") == {"workspace-write", "untrusted"}
    end

    test "no permission mode yields full access or never asks, and approvals go to the user" do
      random = for _ <- 1..50, do: Base.encode64(:crypto.strong_rand_bytes(Enum.random(0..12)))

      for mode <- @modes ++ random do
        {sandbox, approval} = Command.policy(mode)
        assert sandbox in ["read-only", "workspace-write"], "#{inspect(mode)} -> #{sandbox}"
        refute sandbox == "danger-full-access"
        assert approval in ["untrusted", "on-request"], "#{inspect(mode)} -> #{approval}"
        refute approval == "never"
      end

      assert Command.approvals_reviewer() == "user"
    end
  end

  describe "sandbox_policy/2" do
    @tag :tmp_dir
    test "plan is read-only with no network", %{tmp_dir: dir} do
      assert Command.sandbox_policy("plan", dir) == %{
               "type" => "readOnly",
               "networkAccess" => false
             }
    end

    @tag :tmp_dir
    test "every other mode writes only in the resolved repository, with no network",
         %{tmp_dir: dir} do
      resolved = Command.resolve(dir)

      for mode <- @modes -- ["plan"] do
        assert Command.sandbox_policy(mode, dir) == %{
                 "type" => "workspaceWrite",
                 "writableRoots" => [resolved],
                 "networkAccess" => false,
                 "excludeTmpdirEnvVar" => false,
                 "excludeSlashTmp" => false
               }
      end
    end

    @tag :tmp_dir
    test "property: never wider than the repository, never with network", %{tmp_dir: dir} do
      for mode <- @modes do
        policy = Command.sandbox_policy(mode, dir)
        assert policy["networkAccess"] == false
        assert policy["type"] in ["readOnly", "workspaceWrite"]
        assert Map.get(policy, "writableRoots", [Command.resolve(dir)]) == [Command.resolve(dir)]
      end
    end
  end

  describe "resolve/1" do
    @tag :tmp_dir
    test "resolves a symlinked directory to its target", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      link = Path.join(dir, "link")
      File.mkdir_p!(Path.join(real, "sub"))
      File.ln_s!(real, link)

      assert Command.resolve(link) == Command.resolve(real)
      assert Command.resolve(Path.join(link, "sub")) == Command.resolve(Path.join(real, "sub"))
      refute Command.resolve(link) =~ "/link"

      # a component that doesn't exist yet is kept as it is
      assert Command.resolve(Path.join(link, "new/file.txt")) ==
               Path.join(Command.resolve(real), "new/file.txt")
    end

    @tag :tmp_dir
    test "a relative symlink resolves against its directory", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "a/b"))
      File.ln_s!("a/b", Path.join(dir, "rel"))
      assert Command.resolve(Path.join(dir, "rel")) == Command.resolve(Path.join(dir, "a/b"))
    end

    @tag :tmp_dir
    test "a chain of symlinks resolves to the final target", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(dir, "second"))
      File.ln_s!(Path.join(dir, "second"), Path.join(dir, "first"))

      assert Command.resolve(Path.join(dir, "first/x")) ==
               Path.join(Command.resolve(outside), "x")
    end

    @tag :tmp_dir
    test "a symlink loop terminates", %{tmp_dir: dir} do
      File.ln_s!(Path.join(dir, "b"), Path.join(dir, "a"))
      File.ln_s!(Path.join(dir, "a"), Path.join(dir, "b"))
      assert is_binary(Command.resolve(Path.join(dir, "a/x")))
    end

    test "expands the path" do
      assert Command.resolve("/nonexistent-canopy/a/../b") == "/nonexistent-canopy/b"
    end
  end

  describe "args/1" do
    test "app-server on stdio with Canopy's MCP server configured" do
      args = Command.args(opts())
      assert Enum.take(args, 3) == ["app-server", "--listen", "stdio://"]

      assert override(args, "mcp_servers.canopy.url") == ~s("http://127.0.0.1:4000/mcp")
      assert override(args, "mcp_servers.canopy.bearer_token_env_var") == ~s("CANOPY_MCP_TOKEN")
      assert override(args, "mcp_servers.canopy.default_tools_approval_mode") == ~s("approve")
      assert override(args, "mcp_servers.canopy.tool_timeout_sec") == "1800"
      assert override(args, "mcp_servers.canopy.startup_timeout_sec") == "20"
      assert override(args, "notify") == "[]"
    end

    test "the tool timeout follows the option" do
      args = Command.args(opts(mcp_tool_timeout_ms: 90_000))
      assert override(args, "mcp_servers.canopy.tool_timeout_sec") == "90"
    end

    test "shell_environment_policy.exclude carries the user's list, the token var and CANOPY_*" do
      args = Command.args(opts())

      assert override(args, "shell_environment_policy.exclude") ==
               ~s(["CANOPY_MCP_TOKEN","CANOPY_*"])

      args = Command.args(opts(shell_exclude: ["AWS_*", "*SECRET*"]))

      assert JSON.decode!(override(args, "shell_environment_policy.exclude")) ==
               ["AWS_*", "*SECRET*", "CANOPY_MCP_TOKEN", "CANOPY_*"]

      args = Command.args(opts(shell_exclude: ["CANOPY_MCP_TOKEN", "X"]))

      assert JSON.decode!(override(args, "shell_environment_policy.exclude")) ==
               ["CANOPY_MCP_TOKEN", "X", "CANOPY_*"]
    end

    test "without an MCP url, no mcp_servers overrides" do
      args = Command.args(opts(mcp_url: nil))
      refute Enum.any?(args, &String.starts_with?(&1, "mcp_servers."))
      assert override(args, "notify") == "[]"

      assert override(args, "shell_environment_policy.exclude") ==
               ~s(["CANOPY_MCP_TOKEN","CANOPY_*"])
    end

    test "sandbox and approval are never flags" do
      args = Command.args(opts())
      refute Enum.any?(args, &(&1 =~ ~r/sandbox|approval_policy|danger|full-access/))
      refute "--dangerously-bypass-approvals-and-sandbox" in args
    end
  end

  describe "build/1" do
    test "spawns through /bin/sh with stderr to a file, in the repository" do
      cmd = Command.build(opts())
      assert cmd.executable == "/bin/sh"
      assert cmd.cwd == "/repo"

      assert ["-c", script, "/usr/local/bin/codex" | rest] = cmd.args
      assert script == ~s(exec "$0" "$@" 2>>"/tmp/canopy-codex/s/stderr.log")
      assert rest == Command.args(opts())
    end

    test "the token travels only in the environment" do
      cmd = Command.build(opts())
      refute Enum.any?(cmd.args, &String.contains?(&1, "tok-secret-123"))
      assert {~c"CANOPY_MCP_TOKEN", ~c"tok-secret-123"} in cmd.env
    end

    test "without a token, the variable is unset rather than inherited" do
      for token <- [nil, ""] do
        env = Command.env(opts(token: token))
        assert {~c"CANOPY_MCP_TOKEN", false} in env
      end
    end

    test "CODEX_HOME only when a config dir is set" do
      refute Enum.any?(Command.env(opts()), &match?({~c"CODEX_HOME", _}, &1))
      refute Enum.any?(Command.env(opts(config_dir: "")), &match?({~c"CODEX_HOME", _}, &1))
      assert {~c"CODEX_HOME", ~c"/cfg/codex"} in Command.env(opts(config_dir: "/cfg/codex"))
    end

    test "extra env comes last" do
      env = Command.env(opts(extra_env: [{"FAKE_CODEX_SCRIPT", "/x.jsonl"}, {:N, 1}]))
      assert Enum.take(env, -2) == [{~c"FAKE_CODEX_SCRIPT", ~c"/x.jsonl"}, {~c"N", ~c"1"}]
    end
  end

  test "client_info introduces Canopy without experimental APIs" do
    info = Command.client_info()
    assert info["clientInfo"]["name"] == "canopy"
    assert info["clientInfo"]["title"] == "Canopy"
    assert is_binary(info["clientInfo"]["version"])
    assert info["capabilities"] == %{"experimentalApi" => false, "requestAttestation" => false}
  end

  test "token_var/0" do
    assert Command.token_var() == "CANOPY_MCP_TOKEN"
  end
end
