defmodule Canopy.Migrations.AddCodexSettingsTest do
  use Canopy.DataCase, async: false

  alias Canopy.Repo
  alias Canopy.Settings.Setting

  defp columns do
    %{rows: rows} = Repo.query!("PRAGMA table_info(settings)")
    # cid, name, type, notnull, dflt_value, pk
    Map.new(rows, fn [_cid, name, type, notnull, default, _pk] ->
      {name, %{type: type, notnull: notnull, default: default}}
    end)
  end

  test "settings gain the six Codex columns; the binary is required, codex by default" do
    columns = columns()

    assert %{notnull: 1, default: "'codex'"} = columns["codex_binary"]

    for name <-
          ~w(codex_config_dir codex_default_model codex_default_effort codex_light_model codex_light_effort) do
      assert %{notnull: 0, default: nil} = columns[name], name
    end
  end

  test "a row written without them reads the defaults" do
    Repo.delete_all(Setting)

    Repo.query!("""
    INSERT INTO settings (id, opencode_url, user_display_name, mcp_token, inserted_at, updated_at)
    VALUES ('default', 'http://127.0.0.1:4096', 'You', 'tok', '2026-01-01T00:00:00', '2026-01-01T00:00:00')
    """)

    assert %Setting{codex_binary: "codex", codex_config_dir: nil, codex_default_model: nil} =
             Canopy.Settings.get()
  end
end
