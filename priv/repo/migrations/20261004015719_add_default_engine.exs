defmodule Canopy.Repo.Migrations.AddDefaultEngine do
  use Ecto.Migration

  # A default engine, like the default model: `settings.default_engine` names
  # the engine agents without one of their own run on (nil: OpenCode, as
  # before), and `agents.engine` becomes nullable, nil meaning "use the
  # default". Every existing agent keeps the engine it has, written out
  # explicitly; only agents created from now on can follow the default.
  #
  # SQLite cannot drop a NOT NULL constraint in place, so the column is
  # swapped: a nullable copy is added and filled, the old one dropped, and the
  # copy renamed. `agents.engine` has no index, trigger or foreign key that
  # would stop the drop.
  def up do
    alter table(:settings) do
      add :default_engine, :text
    end

    flush()
    make_nullable(repo())
  end

  def down do
    restore_not_null(repo())

    alter table(:settings) do
      remove :default_engine
    end
  end

  @doc false
  def make_nullable(repo) do
    repo.query!("ALTER TABLE agents ADD COLUMN engine_choice TEXT")
    repo.query!("UPDATE agents SET engine_choice = engine")
    repo.query!("ALTER TABLE agents DROP COLUMN engine")
    repo.query!("ALTER TABLE agents RENAME COLUMN engine_choice TO engine")
  end

  # Agents on the default get the default's engine written out (OpenCode, the
  # old schema default, when none was chosen). Runs before `default_engine`
  # is removed.
  @doc false
  def restore_not_null(repo) do
    repo.query!("ALTER TABLE agents ADD COLUMN engine_required TEXT NOT NULL DEFAULT 'opencode'")

    repo.query!(
      "UPDATE agents SET engine_required = COALESCE(engine, (SELECT default_engine FROM settings WHERE id = 'default'), 'opencode')"
    )

    repo.query!("ALTER TABLE agents DROP COLUMN engine")
    repo.query!("ALTER TABLE agents RENAME COLUMN engine_required TO engine")
  end
end
