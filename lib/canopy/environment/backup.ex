defmodule Canopy.Environment.Backup do
  @moduledoc """
  The copy of the database a reset takes before it deletes anything:
  `VACUUM INTO` a file next to the database, named for the minute it started
  (`canopy_dev.db` → `canopy_dev.2026-10-13T1112.db`, then `-2`, `-3` on a
  collision). Backups are never pruned.

  `config :canopy, :environment_backup` swaps the implementation; tests use
  `Canopy.Environment.FakeBackup`, because `VACUUM INTO` can't run inside the
  sandbox's transaction.
  """

  @callback path(NaiveDateTime.t()) :: String.t()
  @callback run(String.t()) :: :ok | {:error, String.t()}

  @behaviour __MODULE__

  @doc "The configured implementation."
  def impl, do: Application.get_env(:canopy, :environment_backup, __MODULE__)

  @impl true
  def path(now), do: path_in(Path.dirname(database()), Path.basename(database(), ".db"), now)

  @doc "`<dir>/<base>.<YYYY-MM-DDTHHMM>.db`, with `-2`, `-3`… when that file exists."
  def path_in(dir, base, now) do
    stamp = Calendar.strftime(now, "%Y-%m-%dT%H%M")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> Path.join(dir, "#{base}.#{stamp}.db")
      n -> Path.join(dir, "#{base}.#{stamp}-#{n}.db")
    end)
    |> Enum.find(&(not File.exists?(&1)))
  end

  @impl true
  def run(path) do
    # VACUUM INTO can't run inside a transaction; Repo.query checks out a
    # connection of its own. No timeout: a large database takes as long as it
    # takes, and the default 15 s would fail every reset of one.
    case Canopy.Repo.query("VACUUM INTO ?", [path], timeout: :infinity) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Canopy.Environment.error_message(error)}
    end
  end

  defp database, do: Path.expand(Canopy.Repo.config()[:database])
end
