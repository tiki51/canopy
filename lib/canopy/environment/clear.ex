defmodule Canopy.Environment.Clear do
  @moduledoc """
  What a reset deletes and what it keeps.

  Every table is in exactly one list (a test reads `sqlite_master` and fails
  on one in neither, so the next migration decides whether a reset keeps its
  table). Kept: the settings row, the local user, repositories, and the
  bookkeeping tables. Everything else is deleted in one `IMMEDIATE`
  transaction, so until it commits nothing is gone. The `AFTER DELETE`
  triggers keep `messages_fts` and `search_fts` in step.

  After the commit, `sweep/0` deletes the documents' bytes (`doc_*` files in
  `Canopy.Documents.Store.dir/0`), and nothing else in that directory.
  """

  import Ecto.Query

  alias Canopy.Repo

  # oban_jobs is kept as a table; its jobs are deleted below, apart from any
  # still executing
  @kept ~w(settings users repositories schema_migrations oban_jobs oban_peers)

  # Children before their parents (foreign keys are deferred to the commit anyway).
  @cleared ~w(message_attachments message_reactions message_reads thread_reads channel_reads
              search_entries timeline_events turn_activity_details permission_requests
              question_requests signoff_requests lock_claims routing_pauses watch_items schedules tasks
              delegations handoffs playbook_steps playbook_runs playbooks documents messages
              channel_agents agent_memories agent_sessions team_members teams channels agents)

  @doc "The tables a reset keeps."
  def kept_tables, do: @kept

  @doc "The tables a reset empties, in the order it empties them."
  def cleared_tables, do: @cleared

  @doc """
  Empties every cleared table in one `IMMEDIATE` transaction. `before_commit`
  runs inside it, last (tests use it to fail the step and see the rollback).
  """
  def run(before_commit \\ fn -> :ok end) do
    Repo.transaction(
      fn ->
        Repo.query!("PRAGMA defer_foreign_keys = ON")
        Repo.update_all(from(s in "settings"), set: [auditor_agent_id: nil])
        Enum.each(@cleared, &Repo.query!("DELETE FROM #{&1}"))
        Repo.delete_all(from(j in "oban_jobs", where: j.state != "executing"))
        before_commit.()
      end,
      mode: :immediate,
      timeout: :infinity
    )
  end

  @doc "Deletes the documents' bytes: `:ok` or `{:error, reason}` naming what was left."
  def sweep do
    dir = Canopy.Documents.Store.dir()

    failed =
      dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "doc_"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        case File.rm(path) do
          :ok -> []
          {:error, :enoent} -> []
          {:error, reason} -> [{Path.basename(path), reason}]
        end
      end)

    case failed do
      [] ->
        :ok

      [{name, reason} | _] ->
        {:error,
         "#{length(failed)} #{if length(failed) == 1, do: "file", else: "files"} " <>
           "couldn't be deleted (#{name}: #{:file.format_error(reason)})"}
    end
  end

  @doc "Tables in neither list (FTS shadow tables and SQLite's own excluded)."
  def unclassified_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )

    virtual =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL%'"
      ).rows
      |> List.flatten()

    names = List.flatten(rows)

    names
    |> Enum.reject(fn name ->
      name in @kept or name in @cleared or name in virtual or
        Enum.any?(virtual, &String.starts_with?(name, &1 <> "_"))
    end)
    |> Enum.sort()
  end
end
