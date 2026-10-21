defmodule Canopy.Repo.Migrations.CreateEnginePauses do
  use Ecto.Migration

  # Engine pauses replace the global hold (`settings.hold_reason`): an engine
  # that reports a usage or billing limit pauses on its own, its agents move
  # to a fallback model or wait for the reset, and a nudge wakes them after.
  #
  # An active hold carries over as a pause of the default engine, with the
  # schedule reason the hold gave its schedules, so Release resumes them.
  def up do
    create table(:engine_pauses, primary_key: false) do
      add :id, :string, primary_key: true
      add :engine, :string, null: false
      add :kind, :string, null: false
      add :reason, :string, null: false
      add :detail, :text
      add :resets_at, :utc_datetime_usec
      add :schedule_reason, :string, null: false
      add :paused_at, :utc_datetime_usec, null: false
      add :lifted_at, :utc_datetime_usec
      add :lifted_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    # one active pause per engine; lifted rows are kept as history
    create unique_index(:engine_pauses, [:engine],
             where: "lifted_at IS NULL",
             name: :engine_pauses_active_engine_index
           )

    create table(:engine_pause_agents, primary_key: false) do
      add :id, :string, primary_key: true

      add :pause_id, references(:engine_pauses, type: :string, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false
      add :state, :string, null: false
      add :schedule_id, references(:schedules, type: :string, on_delete: :nilify_all)
      # the timeline line for this state (engine_fallback / engine_wake_dropped) is written
      add :noted, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:engine_pause_agents, [:pause_id, :agent_id, :channel_id])
    create index(:engine_pause_agents, [:agent_id])
    create index(:engine_pause_agents, [:channel_id])

    alter table(:settings) do
      add :claude_fallback, :string
      add :codex_fallback, :string
      add :opencode_fallback, :string
    end

    alter table(:agents) do
      add :fallback, :string
    end

    alter table(:schedules) do
      add :source, :string
      add :source_ref, :string
    end

    alter table(:messages) do
      add :fallback, :map
    end

    alter table(:agent_sessions) do
      add :fallback_of, :string
    end

    # One primary root and at most one fallback root per (channel, agent).
    # SQLite reports unique violations by column list, so the primary index
    # keeps its default name for Ecto to match.
    drop unique_index(:agent_sessions, [:channel_id, :agent_id])

    create unique_index(:agent_sessions, [:channel_id, :agent_id],
             where: "parent_session_id IS NULL AND fallback_of IS NULL"
           )

    create unique_index(:agent_sessions, [:channel_id, :agent_id],
             where: "parent_session_id IS NULL AND fallback_of IS NOT NULL",
             name: :agent_sessions_fallback_root_index
           )

    flush()

    carry_over_hold()

    alter table(:settings) do
      remove :hold_reason
      remove :hold_at
    end
  end

  def down do
    alter table(:settings) do
      add :hold_reason, :string
      add :hold_at, :utc_datetime_usec
    end

    drop index(:agent_sessions, [:channel_id, :agent_id],
           name: :agent_sessions_fallback_root_index
         )

    drop unique_index(:agent_sessions, [:channel_id, :agent_id])
    repo().query!("DELETE FROM agent_sessions WHERE fallback_of IS NOT NULL")

    create unique_index(:agent_sessions, [:channel_id, :agent_id],
             where: "parent_session_id IS NULL"
           )

    alter table(:agent_sessions), do: remove(:fallback_of)
    alter table(:messages), do: remove(:fallback)

    alter table(:schedules) do
      remove :source
      remove :source_ref
    end

    alter table(:agents), do: remove(:fallback)

    alter table(:settings) do
      remove :claude_fallback
      remove :codex_fallback
      remove :opencode_fallback
    end

    drop table(:engine_pause_agents)
    drop table(:engine_pauses)
  end

  defp carry_over_hold do
    %{rows: rows} =
      repo().query!(
        "SELECT hold_reason, hold_at, default_engine FROM settings " <>
          "WHERE hold_reason IS NOT NULL AND hold_reason != ''"
      )

    for [reason, hold_at, default_engine] <- rows do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      id = Canopy.ID.generate("ep")

      repo().query!(
        "INSERT INTO engine_pauses " <>
          "(id, engine, kind, reason, detail, resets_at, schedule_reason, paused_at, inserted_at, updated_at) " <>
          "VALUES (?1, ?2, 'billing', 'usage limit', ?3, NULL, ?4, ?5, ?6, ?6)",
        [id, default_engine || "opencode", reason, "on hold: " <> reason, hold_at || now, now]
      )
    end
  end
end
