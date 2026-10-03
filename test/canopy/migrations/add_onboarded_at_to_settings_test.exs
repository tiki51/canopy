defmodule Canopy.Migrations.AddOnboardedAtToSettingsTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Repo, Settings}
  alias Canopy.Settings.Setting

  @migration Canopy.Repo.Migrations.AddOnboardedAtToSettings
  @path "priv/repo/migrations/20261003084914_add_onboarded_at_to_settings.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    :ok
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp stamp(now), do: apply(@migration, :stamp, [Repo, now])

  test "an install that already has its settings row is stamped, so it skips setup" do
    Repo.update_all(Setting, set: [onboarded_at: nil])
    _ = Settings.get()
    refute Settings.onboarded?()

    now = DateTime.utc_now()
    stamp(now)

    assert Settings.get().onboarded_at == now
    assert Settings.onboarded?()
  end

  test "a fresh database has no row to stamp; the one created afterwards is not onboarded" do
    Repo.delete_all(Setting)
    stamp(DateTime.utc_now())

    assert Repo.aggregate(Setting, :count) == 0
    refute Settings.onboarded?()
  end

  test "a row already stamped keeps its time" do
    {:ok, %{onboarded_at: at}} = Settings.mark_onboarded()
    stamp(DateTime.add(at, 3600, :second))

    assert Settings.get().onboarded_at == at
  end
end
