defmodule Canopy.Engine.OpenCodeMCPInventoryTest do
  @moduledoc "The OpenCode adapter's MCP inventory and repository-page actions, against the Mox client."
  use Canopy.DataCase, async: false

  import Mox

  alias Canopy.Engine.OpenCode
  alias Canopy.{Fixtures, MCP}
  alias Canopy.OpenCode.ClientMock, as: OC

  @fixtures Path.expand("../../support/mcp_fixtures/opencode", __DIR__)

  setup :verify_on_exit!

  setup do
    repository = Fixtures.repository_fixture()

    File.cp!(
      Path.join([@fixtures, "repo", "opencode.json"]),
      Path.join(repository.path, "opencode.json")
    )

    opts = [config_home: Path.join(@fixtures, "global"), opencode_config: nil]
    {:ok, repository: repository, opts: opts}
  end

  defp config_mcp do
    %{
      "search" => %{
        "type" => "remote",
        "url" => "https://search.example.com/mcp",
        "headers" => %{"Authorization" => "Bearer resolved_fixtureSecret"}
      },
      "shared" => %{"type" => "local", "command" => ["shared-mcp", "--verbose"]},
      "db" => %{
        "type" => "local",
        "command" => ["db-mcp", "--password", "pw_fixtureDbSecret"],
        "environment" => %{"DB_URL" => "postgres://admin:pw_fixtureUrlSecret@localhost/app"}
      },
      "tracker" => %{
        "type" => "remote",
        "url" => "https://tracker.example.com/mcp",
        "enabled" => false
      },
      "oauth-thing" => %{"type" => "remote", "url" => "https://oauth.example.com/mcp"}
    }
  end

  defp status do
    %{
      "canopy" => %{"status" => "connected"},
      "search" => %{"status" => "connected"},
      "shared" => %{"status" => "connected"},
      "db" => %{
        "status" => "failed",
        "error" => "connect ECONNREFUSED http://user:pw_fixtureErr@db.internal:5432"
      },
      "tracker" => %{"status" => "disabled"},
      "oauth-thing" => %{"status" => "needs_auth"},
      "runtime-only" => %{"status" => "connected"}
    }
  end

  defp stub_engine(status, config) do
    expect(OC, :mcp_status, fn _dir, opts ->
      assert opts[:base_url] == Canopy.Settings.get().opencode_url
      status
    end)

    expect(OC, :config, fn _dir, _opts -> config end)
  end

  defp row(engine, name), do: Enum.find(engine.servers, &(&1.name == name))

  test "status per server, sources from the files, values redacted", ctx do
    stub_engine({:ok, status()}, {:ok, %{"mcp" => config_mcp()}})

    assert {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    assert engine.reachable?
    assert engine.error == nil

    assert %{status: :connected, source: %{kind: :canopy}, transport: :remote} =
             row(engine, "canopy")

    assert %{status: :connected, source: %{kind: :global}} = search = row(engine, "search")
    # the file's reference is shown, not the resolved secret
    assert search.secrets == ["Authorization"]

    assert %{status: :failed, source: %{kind: :project, path: path}} = db = row(engine, "db")
    assert path == Path.join(ctx.repository.path, "opencode.json")
    assert db.error == "connect ECONNREFUSED http://db.internal:5432"
    assert db.target == "db-mcp --password ••••"
    assert db.secrets == ["DB_URL"]

    assert %{status: :disabled, enabled?: false} = row(engine, "tracker")
    assert %{status: :needs_auth, note: note} = row(engine, "oauth-thing")
    assert note =~ "opencode mcp auth oauth-thing"

    # reported by OpenCode, defined in no file Canopy reads
    assert %{source: %{kind: :server}} = row(engine, "runtime-only")
    assert %{source: %{kind: :server}} = row(engine, "oauth-thing")

    # the repository's own `canopy` entry is overridden by the registration
    assert Enum.any?(engine.notes, &(&1 =~ "defines its own \"canopy\""))

    for secret <-
          ~w(resolved_fixtureSecret pw_fixtureDbSecret pw_fixtureUrlSecret pw_fixtureErr admin:),
        do: refute(inspect(engine) =~ secret)
  end

  test "OpenCode away: files listed with unknown status", ctx do
    stub_engine({:error, {:transport, %{reason: :econnrefused}}}, {:error, {:transport, %{}}})

    assert {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    refute engine.reachable?
    assert engine.error =~ "OpenCode did not answer"

    names = Enum.map(engine.servers, & &1.name)
    assert names == ["canopy", "db", "search", "shared", "tracker"]
    assert Enum.all?(engine.servers -- [row(engine, "tracker")], &(&1.status == :unknown))
    assert row(engine, "tracker").status == :disabled
  end

  test "the API wins: a file server OpenCode does not load is listed as not loaded", ctx do
    config = Map.delete(config_mcp(), "shared")
    stub_engine({:ok, Map.delete(status(), "shared")}, {:ok, %{"mcp" => config}})

    assert {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    refute row(engine, "shared")
    assert [%{name: "shared", source: %{kind: :global}}] = engine.ignored
  end

  test "canopy not registered yet", ctx do
    stub_engine({:ok, Map.delete(status(), "canopy")}, {:ok, %{"mcp" => config_mcp()}})

    assert {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    assert %{status: :unknown, note: "Not registered yet" <> _} = row(engine, "canopy")
  end

  test "registered this boot, and the plugin state", ctx do
    stub(OC, :mcp_status, fn _, _ -> {:ok, status()} end)
    stub(OC, :config, fn _, _ -> {:ok, %{"mcp" => %{}}} end)

    {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    assert engine.canopy.registered_this_boot? == false
    # repository creation installed it
    assert engine.canopy.plugin == :current

    MCP.mark_registered(ctx.repository.id)
    File.write!(MCP.project_plugin_path(ctx.repository.path), "// old")
    {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    assert engine.canopy.registered_this_boot? == true
    assert engine.canopy.plugin == :outdated

    File.rm!(MCP.project_plugin_path(ctx.repository.path))
    {:ok, engine} = OpenCode.mcp_inventory(ctx.repository, ctx.opts)
    assert engine.canopy.plugin == :missing
  end

  describe "actions" do
    test "reregister posts the current registration and marks it", ctx do
      expect(OC, :add_mcp, fn dir, "canopy", config, _opts ->
        assert dir == ctx.repository.path
        assert config.headers["Authorization"] == "Bearer " <> Canopy.Settings.mcp_token()
        {:ok, %{"canopy" => %{"status" => "connected"}}}
      end)

      assert OpenCode.reregister(ctx.repository) == :ok
      assert MCP.registered_this_boot?(ctx.repository.id)
    end

    test "reconnect asks OpenCode to connect the server", ctx do
      expect(OC, :mcp_connect, fn _dir, "db", _opts -> {:ok, true} end)
      assert OpenCode.reconnect(ctx.repository, "db") == :ok

      expect(OC, :mcp_connect, fn _dir, "db", _opts -> {:ok, false} end)
      assert OpenCode.reconnect(ctx.repository, "db") == {:error, :not_connected}
    end

    test "reinstall_plugin rewrites the file, disposes the instance, and registers again", ctx do
      File.write!(MCP.project_plugin_path(ctx.repository.path), "// old")

      expect(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
      expect(OC, :add_mcp, fn _dir, "canopy", _config, _opts -> {:ok, %{}} end)

      assert OpenCode.reinstall_plugin(ctx.repository) == :ok
      assert MCP.project_plugin_state(ctx.repository.path) == :current
    end
  end
end
