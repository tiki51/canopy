defmodule Canopy.Repo.Migrations.CreateLockClaims do
  use Ecto.Migration

  def change do
    # A lock is the set of its claims: one `held`, the rest `waiting` in
    # insertion order. Keyed by repository, since what it guards (the working
    # tree, the test database, fixed ports) belongs to the repository.
    create table(:lock_claims, primary_key: false) do
      add :id, :string, primary_key: true

      add :repository_id, references(:repositories, type: :string, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      # the holder is an agent's session, or the user for a lock taken by hand
      add :session_id, references(:agent_sessions, type: :string, on_delete: :delete_all)
      add :user_id, references(:users, type: :string, on_delete: :delete_all)
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all)
      # where the claim was made: its timeline lines and its wake go there
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false
      add :reason, :text
      add :status, :string, null: false
      add :hold_across_turns, :boolean, null: false, default: false
      # the turn that owns a held claim; nil until a granted waiter's turn starts
      add :turn_ref, :string
      add :granted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # At most one holder per lock: granting is atomic without a process.
    # SQLite reports unique violations by column list, so the indexes keep
    # their default names for Ecto to match.
    create unique_index(:lock_claims, [:repository_id, :name], where: "status = 'held'")
    # a session (or the user) is in a lock's line at most once
    create unique_index(:lock_claims, [:repository_id, :name, :session_id])
    create unique_index(:lock_claims, [:repository_id, :name, :user_id])
    create index(:lock_claims, [:repository_id, :name, :status, :inserted_at])
    create index(:lock_claims, [:session_id])
    create index(:lock_claims, [:channel_id])
    create index(:lock_claims, [:agent_id])
  end
end
