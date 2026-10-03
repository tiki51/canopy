defmodule Canopy.Repo.Migrations.CorrectClaudeCodeCosts do
  use Ecto.Migration

  # Claude Code turns used to record the result's `total_cost_usd`, which is
  # the session's running total (the CLI restores it on every resume), not
  # the turn's cost: the Costs page, spend limits, and the cost auditor added
  # up running totals. From this version a turn records its own cost
  # (`Canopy.ClaudeCode.Cost`), and `agent_sessions.cost_total` keeps the last
  # total seen so the next turn of the session can count from it.
  #
  # The backfill recomputes the cost of past Claude Code turns from the stored
  # sequence of each session (one `agent_sessions` row is one engine session;
  # a reset starts a new row): a turn's cost is its total minus the largest of
  # the session's last three totals that is not above it, or the whole total
  # when none is (a process that started over). Turns with no total (failed
  # before a result) stay at zero. A corrected turn keeps the reported total
  # as `cost_reported` and is marked `cost_corrected: true`; turns recorded by
  # this version carry `cost_scope: "turn"` and are never touched, so the
  # backfill is safe to run again. Each Claude Code session's `cost_total` is
  # seeded with its last reported total. Plain SQL, so later schema changes
  # cannot break it.

  @window 3

  def up do
    alter table(:agent_sessions) do
      add :cost_total, :float
    end

    flush()
    backfill(repo())
  end

  def down do
    repo().query!("""
    UPDATE timeline_events
    SET payload = json_remove(
          json_set(payload, '$.cost', json_extract(payload, '$.cost_reported')),
          '$.cost_reported', '$.cost_corrected', '$.cost_scope')
    WHERE event_type = 'agent_turn_completed'
      AND json_extract(payload, '$.cost_corrected') = 1
    """)

    alter table(:agent_sessions) do
      remove :cost_total
    end
  end

  @doc false
  def backfill(repo) do
    engines = engines(repo)

    %{rows: rows} =
      repo.query!("""
      SELECT id, ref_id,
             json_extract(payload, '$.cost'),
             json_extract(payload, '$.cost_reported'),
             json_extract(payload, '$.cost_corrected'),
             json_extract(payload, '$.cost_scope'),
             json_extract(payload, '$.engine_session_id'),
             json_extract(payload, '$.model')
      FROM timeline_events
      WHERE event_type = 'agent_turn_completed' AND ref_id IS NOT NULL
      ORDER BY ref_id, inserted_at, id
      """)

    rows
    |> Enum.map(fn [id, ref, cost, reported, corrected, scope, sid, model] ->
      %{
        id: id,
        ref: ref,
        cost: cost,
        reported: reported,
        corrected?: corrected in [1, true],
        scope: scope,
        sid: sid,
        model: model
      }
    end)
    |> Enum.filter(&claude_code?(&1, engines))
    |> Enum.chunk_by(& &1.ref)
    |> Enum.each(&correct_session(repo, &1))
  end

  # The engine of each session id: the row's own, else what its reset or
  # start lines recorded.
  defp engines(repo) do
    %{rows: lines} =
      repo.query!("""
      SELECT ref_id, json_extract(payload, '$.engine')
      FROM timeline_events
      WHERE event_type IN ('session_reset', 'agent_started')
        AND ref_id IS NOT NULL AND json_extract(payload, '$.engine') IS NOT NULL
      """)

    %{rows: sessions} = repo.query!("SELECT id, engine FROM agent_sessions")

    Map.merge(
      Map.new(lines, fn [ref, engine] -> {ref, engine} end),
      Map.new(sessions, &List.to_tuple/1)
    )
  end

  # With no engine on record, the model label tells: OpenCode's are
  # "provider/model" or "opencode default".
  defp claude_code?(row, engines) do
    case Map.get(engines, row.ref) do
      nil ->
        is_binary(row.model) and not String.contains?(row.model, "/") and
          row.model != "opencode default"

      engine ->
        engine == "claude_code"
    end
  end

  defp correct_session(repo, rows) do
    {_window, _sid, last} =
      Enum.reduce(rows, {[], nil, nil}, fn row, {window, sid, last} ->
        # a turn recorded with its own cost: nothing before it is a base
        if row.scope == "turn" and not row.corrected? do
          {[], sid, last}
        else
          window = if row.sid && sid && row.sid != sid, do: [], else: window
          total = number(if(row.corrected?, do: row.reported, else: row.cost))

          {cost, window} =
            if total > 0 do
              base = [0 | window] |> Enum.filter(&(&1 <= total)) |> Enum.max()
              {Float.round((total - base) / 1, 10), Enum.take([total | window], @window)}
            else
              {0.0, window}
            end

          unless row.corrected?, do: mark(repo, row.id, cost, total)
          {window, row.sid || sid, if(total > 0, do: total, else: last)}
        end
      end)

    if last do
      repo.query!(
        "UPDATE agent_sessions SET cost_total = ?1 WHERE id = ?2 AND cost_total IS NULL",
        [last / 1, hd(rows).ref]
      )
    end
  end

  defp mark(repo, id, cost, total) do
    repo.query!(
      """
      UPDATE timeline_events
      SET payload = json_set(payload,
            '$.cost', ?1,
            '$.cost_reported', ?2,
            '$.cost_corrected', json('true'),
            '$.cost_scope', 'turn')
      WHERE id = ?3
      """,
      [cost, total / 1, id]
    )
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0
end
