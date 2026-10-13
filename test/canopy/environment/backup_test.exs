defmodule Canopy.Environment.BackupTest do
  use Canopy.DataCase, async: false

  alias Canopy.Environment.Backup

  @tag :tmp_dir
  test "run/1 copies the database with VACUUM INTO", %{tmp_dir: dir} do
    path = Path.join(dir, "copy.db")

    # VACUUM INTO can't run inside the sandbox's transaction
    assert :ok = Ecto.Adapters.SQL.Sandbox.unboxed_run(Canopy.Repo, fn -> Backup.run(path) end)
    assert File.stat!(path).size > 0

    {:ok, conn} = Exqlite.Sqlite3.open(path)
    on_exit(fn -> Exqlite.Sqlite3.close(conn) end)

    {:ok, statement} =
      Exqlite.Sqlite3.prepare(conn, "SELECT name FROM sqlite_master WHERE type = 'table'")

    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, statement)
    tables = List.flatten(rows)

    assert "settings" in tables
    assert "messages" in tables
    assert "schema_migrations" in tables
  end

  @tag :tmp_dir
  test "a failed run/1 gives SQLite's message without the statement", %{tmp_dir: dir} do
    path = Path.join([dir, "missing", "copy.db"])

    assert {:error, reason} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Canopy.Repo, fn -> Backup.run(path) end)

    assert reason =~ "unable to open database"
    refute reason =~ "VACUUM"
  end

  @tag :tmp_dir
  test "path_in/3 names the file for the minute and counts up on a collision", %{tmp_dir: dir} do
    now = ~N[2026-10-13 11:12:59]
    first = Backup.path_in(dir, "canopy_dev", now)
    assert first == Path.join(dir, "canopy_dev.2026-10-13T1112.db")

    File.write!(first, "x")

    assert Backup.path_in(dir, "canopy_dev", now) ==
             Path.join(dir, "canopy_dev.2026-10-13T1112-2.db")
  end

  test "path/1 puts the backup next to the database" do
    path = Backup.path(~N[2026-10-13 11:12:00])
    db = Path.expand(Canopy.Repo.config()[:database])
    assert Path.dirname(path) == Path.dirname(db)
    assert Path.basename(path) =~ ~r/^canopy_test\.2026-10-13T1112(-\d+)?\.db$/
  end
end
