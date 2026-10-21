defmodule Canopy.Migrations.CreateEnginePausesTest do
  @moduledoc """
  The engine-pauses migration on a database of its own (a temporary file,
  outside the sandbox): an active global hold carries over as a pause of the
  default engine, and the root-session indexes allow one primary and one
  fallback root per channel and agent.
  """
  use ExUnit.Case, async: false

  alias Canopy.Repo

  @version 20_261_020_130_000
  @before 20_261_020_120_000

  setup do
    path = Path.join(System.tmp_dir!(), "engine-pauses-#{System.unique_integer([:positive])}.db")

    pid =
      start_supervised!(
        {Repo, name: nil, database: path, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(pid)
    # the migrations are already loaded (the test database ran them)
    Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(ignore_module_conflict: false)
      Enum.each(["", "-wal", "-shm"], &File.rm(path <> &1))
    end)

    migrate(:up, to: @before)
    {:ok, pid: pid}
  end

  defp migrate(direction, opts) do
    dir = Application.app_dir(:canopy, "priv/repo/migrations")

    Ecto.Migrator.run(
      Repo,
      dir,
      direction,
      [log: false, dynamic_repo: Repo.get_dynamic_repo()] ++ opts
    )
  end

  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp settings_with_hold(reason, default_engine) do
    now = "2026-10-01T00:00:00Z"

    case query("SELECT count(*) FROM settings") do
      [[0]] ->
        Repo.query!(
          "INSERT INTO settings (id, mcp_token, inserted_at, updated_at) VALUES (1, 't', ?1, ?1)",
          [now]
        )

      _ ->
        :ok
    end

    Repo.query!(
      "UPDATE settings SET hold_reason = ?1, hold_at = ?2, default_engine = ?3",
      [reason, now, default_engine]
    )
  end

  test "an active hold becomes a billing pause of the default engine, with the hold's schedule reason" do
    settings_with_hold("Insufficient balance", "claude_code")
    migrate(:up, to: @version)

    assert [
             [
               "claude_code",
               "billing",
               "usage limit",
               "Insufficient balance",
               nil,
               "on hold: Insufficient balance",
               nil
             ]
           ] =
             query(
               "SELECT engine, kind, reason, detail, resets_at, schedule_reason, lifted_at FROM engine_pauses"
             )

    columns = query("PRAGMA table_info(settings)") |> Enum.map(&Enum.at(&1, 1))
    refute "hold_reason" in columns
    refute "hold_at" in columns
    assert "claude_fallback" in columns
  end

  test "a hold with no default engine pauses OpenCode; no hold, no pause" do
    settings_with_hold("billing", nil)
    migrate(:up, to: @version)
    assert [["opencode"]] = query("SELECT engine FROM engine_pauses")

    migrate(:down, to: @before)
    settings_with_hold(nil, "codex")
    migrate(:up, to: @version)
    assert [] = query("SELECT engine FROM engine_pauses")
  end

  test "one primary root and one fallback root per channel and agent" do
    migrate(:up, to: @version)
    now = "2026-10-01T00:00:00Z"

    Repo.query!(
      "INSERT INTO agents (id, name, display_name, active, routing_enabled, permission_mode, opencode_agent, inserted_at, updated_at) " <>
        "VALUES ('agt_1', 'a', 'a', 1, 0, 'default', 'build', ?1, ?1)",
      [now]
    )

    Repo.query!(
      "INSERT INTO repositories (id, name, path, inserted_at, updated_at) VALUES ('repo_1', 'r', '/tmp/r', ?1, ?1)",
      [now]
    )

    Repo.query!(
      "INSERT INTO channels (id, name, repository_id, owner_agent_id, inserted_at, updated_at) " <>
        "VALUES ('ch_1', 'c', 'repo_1', 'agt_1', ?1, ?1)",
      [now]
    )

    insert = fn id, engine, fallback_of ->
      Repo.query(
        "INSERT INTO agent_sessions (id, channel_id, agent_id, engine, engine_session_id, fallback_of, inserted_at, updated_at) " <>
          "VALUES (?1, 'ch_1', 'agt_1', ?2, ?1, ?3, ?4, ?4)",
        [id, engine, fallback_of, now]
      )
    end

    assert {:ok, _} = insert.("s_primary", "claude_code", nil)
    assert {:error, _} = insert.("s_primary2", "claude_code", nil)
    assert {:ok, _} = insert.("s_fallback", "opencode", "claude_code")
    assert {:error, _} = insert.("s_fallback2", "codex", "claude_code")

    # rolling back drops the fallback roots and restores the single root index
    migrate(:down, to: @before)
    assert [["s_primary"]] = query("SELECT id FROM agent_sessions")
  end
end
