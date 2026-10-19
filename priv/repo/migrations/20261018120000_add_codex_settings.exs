defmodule Canopy.Repo.Migrations.AddCodexSettings do
  use Ecto.Migration

  # Codex, the third engine: its binary (a name on PATH or a path), an
  # optional config dir (`CODEX_HOME`; nil is `~/.codex`), and the default
  # and light model and effort, as Claude Code has. Agents need no new
  # columns: Codex reads `model_id`, `effort` and `permission_mode`.
  def change do
    alter table(:settings) do
      add :codex_binary, :string, null: false, default: "codex"
      add :codex_config_dir, :string
      add :codex_default_model, :text
      add :codex_default_effort, :text
      add :codex_light_model, :text
      add :codex_light_effort, :text
    end
  end
end
