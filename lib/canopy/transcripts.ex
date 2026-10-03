defmodule Canopy.Transcripts do
  @moduledoc """
  An agent's engine sessions in a channel, read back as transcripts: every
  prompt Canopy sent, the model's text, tool calls, steps and compactions,
  from the engine's own store (`Canopy.Engine.transcript/4`). Canopy keeps no
  copy: a session the engine has dropped can no longer be read.

  Sessions (`list_sessions/2`): the agent's current root session, the ones
  reset since (from `session_reset` lines), ones only `agent_started` lines
  still name, and the child sessions left from before Single Agent Session.
  `agent_started` and `session_reset` record the engine and repository path;
  older lines fall back to the agent's engine and the channel's repository.

  Pages (`page/2`) are engine-neutral from here on: every string goes
  through `Canopy.MCP.Redact.secrets/2` (Canopy's own tokens by value, and
  common credential shapes) before anything shows it, steered prompts are
  marked, and the channel's turn summaries are placed as `:turn` dividers
  where each turn began, found by the engine message ids the summary
  recorded (or, for older turns, by time).
  """

  import Ecto.Query, warn: false

  alias Canopy.{Agents, Channels, Engine, Repo, Settings}
  alias Canopy.AgentSessions.AgentSession
  alias Canopy.Delegations.Delegation
  alias Canopy.Engine.TranscriptEntry
  alias Canopy.MCP.Redact
  alias Canopy.Runtime.Prompts
  alias Canopy.Timeline.Event

  @typedoc """
  A session that may have a transcript. `kind`: `:current` (the agent's root
  session now), `:reset` (dropped by a reset), `:earlier` (named only by
  older turns), `:delegated` (a child session from before Single Agent
  Session). `ref_id` is its `agent_sessions` row id (the row may be gone),
  which the channel's turn summaries name.
  """
  @type session :: %{
          channel_id: String.t(),
          agent_id: String.t(),
          engine_session_id: String.t(),
          engine: String.t(),
          directory: String.t() | nil,
          kind: :current | :reset | :earlier | :delegated,
          at: DateTime.t() | nil,
          ref_id: String.t() | nil,
          delegation_id: String.t() | nil
        }

  @doc "The agent's sessions in the channel: the current one first, then the rest, newest first."
  def list_sessions(channel_id, agent_id) do
    channel = Channels.get!(channel_id)
    directory = channel.repository && channel.repository.path

    agent_engine =
      case Agents.get(agent_id) do
        nil -> "opencode"
        agent -> agent.engine
      end

    base = %{channel_id: channel_id, agent_id: agent_id, delegation_id: nil}

    rows =
      Repo.all(
        from s in AgentSession,
          where: s.channel_id == ^channel_id and s.agent_id == ^agent_id,
          order_by: [desc: s.inserted_at]
      )

    {roots, children} = Enum.split_with(rows, &is_nil(&1.parent_session_id))
    child_ids = Enum.map(children, & &1.id)

    delegations =
      Repo.all(
        from d in Delegation,
          where: d.child_session_id in ^child_ids,
          select: {d.child_session_id, d.id}
      )
      |> Map.new()

    from_row = fn row, kind ->
      Map.merge(base, %{
        engine_session_id: row.engine_session_id,
        engine: row.engine,
        directory: directory,
        kind: kind,
        at: row.inserted_at,
        ref_id: row.id,
        delegation_id: Map.get(delegations, row.id)
      })
    end

    lines =
      Repo.all(
        from e in Event,
          where:
            e.channel_id == ^channel_id and e.agent_id == ^agent_id and
              e.event_type in ["session_reset", "agent_started"],
          order_by: [desc: e.inserted_at, desc: e.id],
          select: %{type: e.event_type, payload: e.payload, ref_id: e.ref_id, at: e.inserted_at}
      )

    from_line = fn line, kind ->
      Map.merge(base, %{
        engine_session_id: line.payload["engine_session_id"],
        engine: line.payload["engine"] || agent_engine,
        directory: line.payload["directory"] || directory,
        kind: kind,
        at: line.at,
        ref_id: line.ref_id
      })
    end

    current = Enum.map(roots, &from_row.(&1, :current))
    delegated = Enum.map(children, &from_row.(&1, :delegated))

    {resets, started} = Enum.split_with(lines, &(&1.type == "session_reset"))
    reset = Enum.map(resets, &from_line.(&1, :reset))
    earlier = Enum.map(started, &from_line.(&1, :earlier))

    older =
      (delegated ++ reset ++ earlier)
      |> Enum.filter(&is_binary(&1.engine_session_id))
      |> Enum.uniq_by(& &1.engine_session_id)
      |> Enum.reject(fn s ->
        Enum.any?(current, &(&1.engine_session_id == s.engine_session_id))
      end)
      |> Enum.sort_by(& &1.at, {:desc, DateTime})

    current ++ older
  end

  @doc """
  Where a turn summary (`agent_turn_completed`) sits: its session among
  `sessions` and the page options that land on it. `nil` when none of the
  sessions is the turn's.
  """
  def locate_turn(sessions, %Event{event_type: "agent_turn_completed"} = event) do
    p = event.payload

    session =
      Enum.find(
        sessions,
        &(is_binary(p["engine_session_id"]) and &1.engine_session_id == p["engine_session_id"])
      ) ||
        Enum.find(sessions, &(&1.ref_id == event.ref_id))

    if session do
      at = DateTime.add(started_at(event), -2, :second)

      around =
        case get_in(p, ["engine_message_ids", "first"]) do
          id when is_binary(id) -> {:message_id, id}
          _ -> {:at, at}
        end

      {session, [around: around, fallback_at: at]}
    end
  end

  def locate_turn(_sessions, _event), do: nil

  @doc """
  A page of the session's transcript (options as `Canopy.Engine.transcript/4`),
  redacted, with steered prompts marked, `:system_changed` entries where the
  system text changed, and `:turn` dividers.
  """
  def page(%{engine_session_id: sid, engine: engine} = session, opts \\ []) do
    ref = %{engine_session_id: sid, directory: session.directory}

    case Engine.transcript(engine, nil, ref, opts) do
      {:ok, page} ->
        known = known_tokens()
        system_prompts = Enum.map(page.system_prompts, &redact_system(&1, known))

        entries =
          page.entries
          |> Enum.map(&(&1 |> redact(known) |> mark_steered()))
          |> with_system_changes(system_prompts)
          |> with_turns(session)

        {:ok, %{page | entries: entries, system_prompts: system_prompts}}

      {:error, _} = error ->
        error
    end
  end

  # -- Redaction --------------------------------------------------------------------

  # Every MCP token a session holds now, and the settings token.
  defp known_tokens do
    sessions =
      Repo.all(from s in AgentSession, where: not is_nil(s.mcp_token), select: s.mcp_token)

    Enum.reject([Settings.mcp_token() | sessions], &is_nil/1)
  end

  defp redact(%TranscriptEntry{} = entry, known) do
    {text, text?} = Redact.secrets(entry.text, known)
    {tool, tool?} = redact_tool(entry.tool, known)
    {compaction, compaction?} = redact_compaction(entry.compaction, known)

    %{
      entry
      | text: text,
        tool: tool,
        compaction: compaction,
        redacted?: entry.redacted? or text? or tool? or compaction?
    }
  end

  defp redact_tool(nil, _known), do: {nil, false}

  defp redact_tool(tool, known) do
    {title, a} = Redact.secrets(tool.title, known)
    {input, b} = Redact.secrets(tool.input, known)
    {output, c} = Redact.secrets(tool.output, known)
    {%{tool | title: title, input: input, output: output}, a or b or c}
  end

  defp redact_compaction(nil, _known), do: {nil, false}

  defp redact_compaction(compaction, known) do
    {summary, redacted?} = Redact.secrets(compaction.summary, known)
    {%{compaction | summary: summary}, redacted?}
  end

  defp redact_system(prompt, known) do
    {canopy, _} = Redact.secrets(prompt.canopy, known)
    engine = if prompt.engine, do: Enum.map(prompt.engine, &elem(Redact.secrets(&1, known), 0))
    %{prompt | canopy: canopy, engine: engine}
  end

  # -- Marks ------------------------------------------------------------------------

  # A message steered into a running turn starts with Canopy's steer preface.
  defp mark_steered(%TranscriptEntry{kind: :prompt, text: text} = entry) when is_binary(text) do
    preface = String.trim(Prompts.steer_preface())
    %{entry | steered?: String.starts_with?(String.trim_leading(text), preface)}
  end

  defp mark_steered(entry), do: entry

  # Each later system text that differs from the one before it shows where
  # it took effect, when that falls inside the page.
  defp with_system_changes(entries, prompts) do
    changes =
      prompts
      |> Enum.with_index()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [{prev, _}, {next, _}] -> next.at && prev.canopy != next.canopy end)
      |> Enum.map(fn [_, {next, i}] ->
        %TranscriptEntry{id: "system-#{i}", kind: :system_changed, at: next.at, text: next.canopy}
      end)

    Enum.reduce(changes, entries, fn change, entries ->
      case Enum.find_index(entries, &(&1.at && DateTime.compare(&1.at, change.at) != :lt)) do
        nil -> entries
        0 -> entries
        i -> List.insert_at(entries, i, change)
      end
    end)
  end

  # -- Turn dividers ----------------------------------------------------------------

  defp with_turns([], _session), do: []

  defp with_turns(entries, session) do
    tuple = List.to_tuple(entries)
    times = for %{at: %DateTime{} = at} <- entries, do: at

    dividers =
      case times do
        [] ->
          %{}

        _ ->
          {first, last} = {Enum.min(times, DateTime), Enum.max(times, DateTime)}

          session
          |> turns()
          |> Enum.filter(fn turn ->
            DateTime.compare(turn.inserted_at, DateTime.add(first, -5, :second)) != :lt and
              DateTime.compare(started_at(turn), DateTime.add(last, 5, :second)) != :gt
          end)
          |> Enum.reduce(%{}, fn turn, acc ->
            case anchor(tuple, turn, acc) do
              nil -> acc
              i -> Map.put(acc, i, divider(turn))
            end
          end)
      end

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, i} ->
      case Map.fetch(dividers, i) do
        {:ok, divider} -> [divider, entry]
        :error -> [entry]
      end
    end)
  end

  # The session's turns: by its row id (every turn names it), or by the
  # engine session id newer summaries record.
  defp turns(%{channel_id: channel_id, agent_id: agent_id, engine_session_id: sid} = session) do
    same_session =
      case session.ref_id do
        nil ->
          dynamic([e], fragment("json_extract(?, '$.engine_session_id') = ?", e.payload, ^sid))

        ref_id ->
          dynamic(
            [e],
            e.ref_id == ^ref_id or
              fragment("json_extract(?, '$.engine_session_id') = ?", e.payload, ^sid)
          )
      end

    Repo.all(
      from e in Event,
        where:
          e.channel_id == ^channel_id and e.agent_id == ^agent_id and
            e.event_type == "agent_turn_completed",
        where: ^same_session,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  # The turn begins at its prompt: the nearest prompt before the entry of its
  # first model call, or (older turns, without ids) the prompt of its time
  # span closest to its start, else its span's first entry. A place another
  # turn took (`taken`) is not used twice.
  defp anchor(tuple, turn, taken) do
    indexes = 0..(tuple_size(tuple) - 1)//1
    first_id = get_in(turn.payload, ["engine_message_ids", "first"])
    prompt? = fn i -> match?(%{kind: :prompt, steered?: false}, elem(tuple, i)) end

    case first_id && Enum.find(indexes, &(elem(tuple, &1).message_id == first_id)) do
      i when is_integer(i) ->
        Enum.find(i..0//-1, i, prompt?)

      _ ->
        started = started_at(turn)
        from = DateTime.add(started, -2, :second)

        within =
          Enum.filter(indexes, fn i ->
            at = elem(tuple, i).at

            ((not Map.has_key?(taken, i) and at) && DateTime.compare(at, from) != :lt) and
              DateTime.compare(at, turn.inserted_at) != :gt
          end)

        case Enum.filter(within, prompt?) do
          [] ->
            List.first(within)

          prompts ->
            Enum.min_by(prompts, &abs(DateTime.diff(elem(tuple, &1).at, started, :millisecond)))
        end
    end
  end

  defp divider(%Event{payload: p} = turn) do
    %TranscriptEntry{
      id: "turn-" <> turn.id,
      kind: :turn,
      at: started_at(turn),
      turn: %{
        event_id: turn.id,
        trigger: p["trigger"],
        tools: p["tools"],
        cost: p["cost"],
        duration_ms: p["duration_ms"],
        outcome: p["outcome"],
        passed?: p["passed"] == true,
        steered: length(List.wrap(p["interrupted_by"]))
      }
    }
  end

  defp started_at(%Event{inserted_at: at, payload: p}) do
    case p["duration_ms"] do
      ms when is_integer(ms) -> DateTime.add(at, -ms, :millisecond)
      _ -> at
    end
  end
end
