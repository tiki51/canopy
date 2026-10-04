defmodule Canopy.Migrations.AddDefaultEngineTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Agents, Repo, Settings}

  @migration Canopy.Repo.Migrations.AddDefaultEngine
  @path "priv/repo/migrations/20261004015719_add_default_engine.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    :ok
  end

  # The migration file is loaded at run time, so it is called dynamically.
  # Both run inside the test's transaction, so the schema change rolls back.
  defp make_nullable, do: apply(@migration, :make_nullable, [Repo])
  defp restore_not_null, do: apply(@migration, :restore_not_null, [Repo])

  defp engines do
    %{rows: rows} = Repo.query!("SELECT name, engine FROM agents ORDER BY name")
    Map.new(rows, fn [name, engine] -> {name, engine} end)
  end

  defp engine_column do
    %{rows: rows} = Repo.query!("PRAGMA table_info(agents)")
    # cid, name, type, notnull, dflt_value, pk
    Enum.find_value(rows, fn
      [_cid, "engine", type, notnull, default, _pk] ->
        %{type: type, notnull: notnull, default: default}

      _ ->
        nil
    end)
  end

  test "every existing agent keeps its engine, written out; the column then takes nil" do
    # the table as it was: engine required, OpenCode by default
    restore_not_null()
    assert %{notnull: 1} = engine_column()

    Repo.query!("""
    INSERT INTO agents (id, name, display_name, engine, opencode_agent, permission_mode, active, routing_enabled, inserted_at, updated_at)
    VALUES ('agt_old_oc', 'old-oc', 'old-oc', 'opencode', 'build', 'default', 1, 0, '2026-01-01T00:00:00', '2026-01-01T00:00:00'),
           ('agt_old_cc', 'old-cc', 'old-cc', 'claude_code', 'build', 'plan', 1, 0, '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    make_nullable()

    assert %{notnull: 0, default: nil} = engine_column()
    assert engines() == %{"old-cc" => "claude_code", "old-oc" => "opencode"}

    # explicit engines stay explicit when the default changes
    {:ok, _} = Settings.put_default_engine("claude_code")
    assert Agents.effective_engine(Agents.get_by_name("old-oc")) == "opencode"

    # and a new agent can follow the default
    {:ok, follower} = Agents.create(%{name: "follower"})
    assert Agents.get!(follower.id).engine == nil
    assert Agents.effective_engine(follower) == "claude_code"
  end

  test "rolling back writes the default's engine onto agents that follow it" do
    {:ok, _} = Settings.put_default_engine("claude_code")
    {:ok, follower} = Agents.create(%{name: "follower"})
    {:ok, own} = Agents.create(%{name: "own", engine: "opencode"})

    restore_not_null()

    assert %{notnull: 1} = engine_column()
    assert engines() == %{"follower" => "claude_code", "own" => "opencode"}

    make_nullable()
    assert Agents.get!(follower.id).engine == "claude_code"
    assert Agents.get!(own.id).engine == "opencode"
  end
end
