defmodule Canopy.Environment.FakeBackup do
  @moduledoc """
  Stands in for `VACUUM INTO` in tests (it can't run inside the sandbox's
  transaction): writes a stub file under `_build/test/tmp/backups/`, named as
  the real backup would be. A backup failure is `fail_at: :backing_up`.
  """

  @behaviour Canopy.Environment.Backup

  def dir,
    do:
      Path.expand("../../_build/test/tmp/backups#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)

  @impl true
  def path(now) do
    File.mkdir_p!(dir())
    Canopy.Environment.Backup.path_in(dir(), "canopy_test", now)
  end

  @impl true
  def run(path), do: File.write(path, "stub backup")
end
