defmodule Canopy.Costs do
  @moduledoc """
  Spend, from the cost recorded for every finished turn (kept on the
  `agent_turn_completed` timeline event). Everything here is a query over
  those events: totals by period, and breakdowns by agent, channel, model,
  engine, and day. Costs are in US dollars: what Claude Code and the
  providers behind OpenCode report, and for Codex, which reports only
  tokens, an estimate from list prices (`Canopy.Codex.Pricing`; the payload
  says `"cost_estimated" => true`). Every aggregate with a `cost` also has
  `estimated`, the dollars within it that are estimates. Turns whose
  provider reports nothing count as zero.
  """

  import Ecto.Query

  alias Canopy.Repo
  alias Canopy.Schedules.When
  alias Canopy.Timeline.Event

  @type row :: %{
          key: term,
          label: String.t(),
          cost: float,
          estimated: float,
          turns: non_neg_integer,
          tools: non_neg_integer,
          duration_ms: non_neg_integer
        }

  # SQL for the turn's cost, and for the part of it that is an estimate.
  defmacrop cost(payload) do
    quote do: fragment("COALESCE(json_extract(?, '$.cost'), 0)", unquote(payload))
  end

  defmacrop estimated(payload) do
    quote do
      fragment(
        "CASE WHEN json_extract(?, '$.cost_estimated') THEN COALESCE(json_extract(?, '$.cost'), 0) ELSE 0 END",
        unquote(payload),
        unquote(payload)
      )
    end
  end

  # A breakdown row's sums: {cost, estimated, turns, tools, duration_ms}.
  defmacrop sums(e) do
    quote do
      {sum(cost(unquote(e).payload)), sum(estimated(unquote(e).payload)), count(unquote(e).id),
       sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", unquote(e).payload)),
       sum(fragment("COALESCE(json_extract(?, '$.duration_ms'), 0)", unquote(e).payload))}
    end
  end

  # The engine a turn ran on: the summary's own "engine", else its session's
  # (the row, or for a session since dropped, the engine its reset or start
  # lines recorded). Nil when none is known; see `engine_by_model/1`.
  defmacrop engine(e, s) do
    quote do
      fragment(
        "COALESCE(json_extract(?, '$.engine'), ?, (SELECT json_extract(r.payload, '$.engine') FROM timeline_events AS r WHERE r.ref_id = ? AND r.event_type IN ('session_reset', 'agent_started') AND json_extract(r.payload, '$.engine') IS NOT NULL LIMIT 1))",
        unquote(e).payload,
        unquote(s).engine,
        unquote(e).ref_id
      )
    end
  end

  @doc "Total cost (and its estimated part), turn count, and tool calls since `since` (nil for all time)."
  def total(since \\ nil) do
    base(since)
    |> select([e], %{
      cost: sum(cost(e.payload)),
      estimated: sum(estimated(e.payload)),
      turns: count(e.id),
      tools: sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload))
    })
    |> Repo.one()
    |> then(fn r ->
      %{
        cost: (r.cost || 0) / 1,
        estimated: (r.estimated || 0) / 1,
        turns: r.turns || 0,
        tools: r.tools || 0
      }
    end)
  end

  @doc "Spend per agent since `since`, highest first."
  def by_agent(since \\ nil) do
    base(since)
    |> join(:left, [e], a in Canopy.Agents.Agent, on: a.id == e.agent_id)
    |> group_by([e, a], [e.agent_id, a.name])
    |> select([e, a], {e.agent_id, a.name, sums(e)})
    |> Repo.all()
    |> rows(fn id, name -> {id, if(name, do: "@" <> name, else: "removed agent")} end)
  end

  @doc "Spend per channel since `since`, highest first."
  def by_channel(since \\ nil) do
    base(since)
    |> join(:left, [e], c in Canopy.Channels.Channel, on: c.id == e.channel_id)
    |> group_by([e, c], [e.channel_id, c.name, c.kind])
    |> select(
      [e, c],
      {e.channel_id, fragment("? || '|' || COALESCE(?, '')", c.name, c.kind), sums(e)}
    )
    |> Repo.all()
    |> rows(fn id, name_kind ->
      case String.split(name_kind || "|", "|", parts: 2) do
        [_name, "dm"] -> {id, dm_label(id)}
        [name, _] when name != "" -> {id, "#" <> name}
        _ -> {id, "removed channel"}
      end
    end)
  end

  @doc "Spend per model since `since`, highest first. Turns before models were recorded show as unknown."
  def by_model(since \\ nil) do
    base(since)
    |> group_by([e], fragment("COALESCE(json_extract(?, '$.model'), 'unknown')", e.payload))
    |> select(
      [e],
      {fragment("COALESCE(json_extract(?, '$.model'), 'unknown')", e.payload), nil, sums(e)}
    )
    |> Repo.all()
    |> rows(fn model, _ -> {model, model} end)
  end

  @doc """
  Spend per engine since `since`, in `Canopy.Engine.names/0` order (engines
  with no turns in the period left out; an engine no longer configured comes
  last). Rows are `t:row/0`, keyed by engine name and labelled as people read
  it. A turn's engine is the one its summary recorded; turns from before
  summaries recorded it take their session's, and with the session gone
  Claude Code for a Claude model name, else OpenCode (the only engine before
  sessions had one).
  """
  def by_engine(since \\ nil) do
    found =
      since
      |> engine_groups()
      |> Enum.group_by(& &1.engine)
      |> Map.new(fn {engine, groups} ->
        sums = Enum.map(groups, &{&1.cost, &1.estimated, &1.turns, &1.tools, &1.duration_ms})

        [row] =
          rows([{engine, nil, merge_sums(sums)}], fn e, _ -> {e, Canopy.Engine.label(e)} end)

        {engine, row}
      end)

    known = Canopy.Engine.names()

    (known ++ Enum.sort(Map.keys(found) -- known))
    |> Enum.flat_map(&List.wrap(Map.get(found, &1)))
  end

  @doc """
  The model labels that ran on `engine` since `since` (`"unknown"` for
  turns that recorded none), the engine decided as in `by_engine/1`.
  """
  def models_on(engine, since \\ nil) when is_binary(engine) do
    since
    |> engine_groups()
    |> Enum.filter(&(&1.engine == engine))
    |> Enum.map(&(&1.model || "unknown"))
    |> Enum.uniq()
  end

  # Turns since `since` summed per (engine, model), the engine resolved.
  defp engine_groups(since) do
    base(since)
    |> join(:left, [e], s in Canopy.AgentSessions.AgentSession, on: s.id == e.ref_id)
    |> group_by([e, s], [engine(e, s), fragment("json_extract(?, '$.model')", e.payload)])
    |> select([e, s], {engine(e, s), fragment("json_extract(?, '$.model')", e.payload), sums(e)})
    |> Repo.all()
    |> Enum.map(fn {engine, model, {cost, estimated, turns, tools, duration}} ->
      %{
        engine: engine || engine_by_model(model),
        model: model,
        cost: cost || 0,
        estimated: estimated || 0,
        turns: turns || 0,
        tools: tools || 0,
        duration_ms: duration || 0
      }
    end)
  end

  defp merge_sums(sums) do
    Enum.reduce(sums, {0, 0, 0, 0, 0}, fn {c, e, n, t, d}, {c0, e0, n0, t0, d0} ->
      {c0 + c, e0 + e, n0 + n, t0 + t, d0 + d}
    end)
  end

  # A turn with no engine on record, nor a session that knows it: Claude
  # Code's model labels are its aliases (`sonnet`), `claude-…` ids, or
  # "claude default"; anything else ran on OpenCode, the first engine.
  defp engine_by_model(model) when is_binary(model) do
    aliases = :canopy |> Application.get_env(:claude_list_prices, %{}) |> Map.keys()

    if model == "claude default" or String.starts_with?(model, ["claude" | aliases]),
      do: "claude_code",
      else: "opencode"
  end

  defp engine_by_model(_model), do: "opencode"

  @doc "Spend per local day for the last `days` days, oldest first, with empty days filled in."
  def by_day(days \\ 14) do
    today = local_today()
    since = today |> Date.add(-(days - 1)) |> local_midnight()
    shift = "#{When.local_offset_seconds()} seconds"

    found =
      base(since)
      |> group_by([e], fragment("date(?, ?)", e.inserted_at, ^shift))
      |> select(
        [e],
        {fragment("date(?, ?)", e.inserted_at, ^shift), sum(cost(e.payload)),
         sum(estimated(e.payload)), count(e.id)}
      )
      |> Repo.all()
      |> Map.new(fn {day, cost, estimated, turns} ->
        {day, %{cost: (cost || 0) / 1, estimated: (estimated || 0) / 1, turns: turns}}
      end)

    for offset <- (days - 1)..0//-1 do
      day = Date.add(today, -offset)

      Map.merge(
        %{day: day, cost: 0.0, estimated: 0.0, turns: 0},
        Map.get(found, Date.to_iso8601(day), %{})
      )
    end
  end

  @doc """
  What one channel has spent, all time, estimates included. The spend limit
  is checked against this.
  """
  def channel_total(channel_id) when is_binary(channel_id),
    do: channel_spend(channel_id).cost

  @doc "What one channel has spent, all time, and the estimated part of it (for the ≈ on its meter)."
  def channel_spend(channel_id) when is_binary(channel_id) do
    from(e in Event,
      where: e.event_type == "agent_turn_completed" and e.channel_id == ^channel_id,
      select: {sum(cost(e.payload)), sum(estimated(e.payload))}
    )
    |> Repo.one()
    |> then(fn {cost, estimated} -> %{cost: (cost || 0) / 1, estimated: (estimated || 0) / 1} end)
  end

  # Model routing's numbers live in `Canopy.Costs.Routing`.
  defdelegate wake_profile(since), to: Canopy.Costs.Routing
  defdelegate by_route(since), to: Canopy.Costs.Routing
  defdelegate routing_savings(since), to: Canopy.Costs.Routing
  defdelegate rule_stats(agent_id), to: Canopy.Costs.Routing

  @doc "Spend per wake trigger (user, agent, delegation, handoff, scheduled, …) since `since`."
  def by_trigger(since \\ nil) do
    base(since)
    |> group_by([e], fragment("COALESCE(json_extract(?, '$.trigger'), 'unknown')", e.payload))
    |> select(
      [e],
      {fragment("COALESCE(json_extract(?, '$.trigger'), 'unknown')", e.payload), nil, sums(e)}
    )
    |> Repo.all()
    |> rows(fn trigger, _ -> {trigger, trigger_label(trigger)} end)
  end

  defp trigger_label("user"), do: "your messages"
  defp trigger_label("agent"), do: "agent messages"
  defp trigger_label("delegation"), do: "delegations"
  defp trigger_label("handoff"), do: "handoffs"
  defp trigger_label("scheduled"), do: "scheduled tasks"
  defp trigger_label("watch"), do: "GitHub watches"
  defp trigger_label("playbook"), do: "playbook runs"
  defp trigger_label("playbook_nudge"), do: "playbook stall nudges"
  defp trigger_label(_), do: "not recorded"

  @doc """
  How the money is spent since `since`: model calls, tokens, context, cache
  hits, and the turns that bought nothing (passed, errored). Token fields are
  zero for turns recorded before they were kept. `estimated` and
  `avg_estimated` are the parts of `cost` and `avg_cost` that are estimates.
  """
  def efficiency(since \\ nil) do
    row =
      base(since)
      |> select([e], %{
        turns: count(e.id),
        cost: sum(cost(e.payload)),
        estimated: sum(estimated(e.payload)),
        tools: sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload)),
        steps: sum(fragment("COALESCE(json_extract(?, '$.steps'), 0)", e.payload)),
        context: sum(fragment("COALESCE(json_extract(?, '$.context'), 0)", e.payload)),
        with_context:
          sum(fragment("CASE WHEN json_extract(?, '$.context') > 0 THEN 1 ELSE 0 END", e.payload)),
        input: sum(fragment("COALESCE(json_extract(?, '$.tokens.input'), 0)", e.payload)),
        output: sum(fragment("COALESCE(json_extract(?, '$.tokens.output'), 0)", e.payload)),
        reasoning: sum(fragment("COALESCE(json_extract(?, '$.tokens.reasoning'), 0)", e.payload)),
        cache_read:
          sum(fragment("COALESCE(json_extract(?, '$.tokens.cache_read'), 0)", e.payload)),
        cache_write:
          sum(fragment("COALESCE(json_extract(?, '$.tokens.cache_write'), 0)", e.payload)),
        passed:
          sum(fragment("CASE WHEN json_extract(?, '$.passed') THEN 1 ELSE 0 END", e.payload)),
        passed_cost:
          sum(
            fragment(
              "CASE WHEN json_extract(?, '$.passed') THEN COALESCE(json_extract(?, '$.cost'), 0) ELSE 0 END",
              e.payload,
              e.payload
            )
          ),
        passed_estimated:
          sum(
            fragment(
              "CASE WHEN json_extract(?, '$.passed') AND json_extract(?, '$.cost_estimated') THEN COALESCE(json_extract(?, '$.cost'), 0) ELSE 0 END",
              e.payload,
              e.payload,
              e.payload
            )
          ),
        errors:
          sum(
            fragment(
              "CASE WHEN json_extract(?, '$.outcome') = 'error' THEN 1 ELSE 0 END",
              e.payload
            )
          ),
        error_cost:
          sum(
            fragment(
              "CASE WHEN json_extract(?, '$.outcome') = 'error' THEN COALESCE(json_extract(?, '$.cost'), 0) ELSE 0 END",
              e.payload,
              e.payload
            )
          ),
        error_estimated:
          sum(
            fragment(
              "CASE WHEN json_extract(?, '$.outcome') = 'error' AND json_extract(?, '$.cost_estimated') THEN COALESCE(json_extract(?, '$.cost'), 0) ELSE 0 END",
              e.payload,
              e.payload,
              e.payload
            )
          )
      })
      |> Repo.one()

    row = Map.new(row, fn {k, v} -> {k, v || 0} end)
    prompt_tokens = row.input + row.cache_read

    %{
      turns: row.turns,
      cost: row.cost / 1,
      estimated: row.estimated / 1,
      tools: row.tools,
      steps: row.steps,
      avg_cost: if(row.turns > 0, do: row.cost / row.turns, else: 0.0),
      avg_estimated: if(row.turns > 0, do: row.estimated / row.turns, else: 0.0),
      avg_context: if(row.with_context > 0, do: div(row.context, row.with_context), else: 0),
      tokens: %{
        input: row.input,
        output: row.output,
        reasoning: row.reasoning,
        cache_read: row.cache_read,
        cache_write: row.cache_write
      },
      cache_rate: if(prompt_tokens > 0, do: row.cache_read / prompt_tokens, else: nil),
      passed: %{turns: row.passed, cost: row.passed_cost / 1, estimated: row.passed_estimated / 1},
      errors: %{turns: row.errors, cost: row.error_cost / 1, estimated: row.error_estimated / 1},
      compactions: compactions(since)
    }
  end

  defp compactions(since) do
    query = from(e in Event, where: e.event_type == "session_compacted", select: count(e.id))

    query =
      if since, do: from(e in query, where: e.inserted_at >= ^since), else: query

    Repo.one(query) || 0
  end

  @doc """
  The costliest turns since `since`, with who, where, and what they did.
  `cost_estimated` marks a turn whose cost is an estimate (Codex).
  """
  def top_turns(since \\ nil, limit \\ 6) do
    base(since)
    |> order_by([e], desc: fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload))
    |> limit(^limit)
    |> preload([:agent, :channel])
    |> Repo.all()
    |> Enum.reject(&(number(&1.payload["cost"]) <= 0))
    |> Enum.map(fn e ->
      p = e.payload

      %{
        id: e.id,
        agent: if(e.agent, do: "@" <> e.agent.name, else: "removed agent"),
        channel_id: e.channel_id,
        # the thread the turn worked for, if any
        thread_id: e.thread_id,
        channel: channel_label(e.channel),
        cost: number(p["cost"]) / 1,
        cost_estimated: p["cost_estimated"] == true,
        tools: number(p["tools"]),
        steps: number(p["steps"]),
        context: number(p["context"]),
        duration_ms: number(p["duration_ms"]),
        trigger: p["trigger"],
        outcome: p["outcome"],
        passed: p["passed"] == true,
        model: p["model"],
        # model routing: a turn on the light model, and one that escalated
        profile: p["profile"],
        escalated: p["escalated"] == true,
        at: e.inserted_at
      }
    end)
  end

  defp channel_label(nil), do: "removed channel"
  defp channel_label(%{kind: "dm", id: id}), do: dm_label(id)
  defp channel_label(%{name: name}), do: "#" <> name

  @doc "Channels with a spend limit, with what each has spent (and the estimated part of it)."
  def channel_budgets do
    from(c in Canopy.Channels.Channel, where: not is_nil(c.spend_limit), order_by: c.name)
    |> Repo.all()
    |> Enum.map(fn c ->
      spend = channel_spend(c.id)

      %{
        channel_id: c.id,
        label: channel_label(c),
        limit: c.spend_limit,
        spent: spend.cost,
        estimated: spend.estimated,
        reached?: spend.cost >= c.spend_limit
      }
    end)
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0

  defp local_today, do: NaiveDateTime.local_now() |> NaiveDateTime.to_date()

  defp local_midnight(%Date{} = day),
    do: day |> NaiveDateTime.new!(~T[00:00:00]) |> When.from_local_naive()

  @doc "The start of today (local time), and `days` days ago, as `since` values."
  def since(:today), do: local_midnight(local_today())

  def since(:week), do: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
  def since(:month), do: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
  def since(:all), do: nil

  defp base(nil), do: from(e in Event, where: e.event_type == "agent_turn_completed")

  defp base(%DateTime{} = since),
    do:
      from(e in Event, where: e.event_type == "agent_turn_completed" and e.inserted_at >= ^since)

  # `{key, label_source, {cost, estimated, turns, tools, duration_ms}}` rows
  # to `t:row/0`s, highest cost first; `keyer` turns the first two into the
  # row's key and label.
  defp rows(list, keyer) do
    list
    |> Enum.map(fn {a, b, {cost, estimated, turns, tools, duration}} ->
      {key, label} = keyer.(a, b)

      %{
        key: key,
        label: label,
        cost: (cost || 0) / 1,
        estimated: (estimated || 0) / 1,
        turns: turns || 0,
        tools: tools || 0,
        duration_ms: duration || 0
      }
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  defp dm_label(channel_id) do
    case Canopy.Channels.get(channel_id) do
      nil -> "removed DM"
      channel -> "DM " <> Canopy.Channels.dm_label(channel)
    end
  end

  @doc """
  Fills in `model` on past turn summaries from each agent's configured model
  (turns before 2026-09-10 did not record it). An approximation: the agent's
  model may have changed since. Returns the number of events updated.
  """
  def backfill_models do
    agents = Canopy.Agents.list() |> Map.new(&{&1.id, &1})

    from(e in Event,
      where: e.event_type == "agent_turn_completed",
      where: is_nil(fragment("json_extract(?, '$.model')", e.payload))
    )
    |> Repo.all()
    |> Enum.reduce(0, fn event, n ->
      model =
        case Map.get(agents, event.agent_id) do
          %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) -> p <> "/" <> m
          _ -> "opencode default"
        end

      {1, _} =
        Repo.update_all(from(x in Event, where: x.id == ^event.id),
          set: [payload: Map.put(event.payload, "model", model)]
        )

      n + 1
    end)
  end

  @doc """
  Dollars with two decimals, or four when under a cent matters. A negative
  amount (an estimated saving that turned out a loss) reads `−$0.01`, with a
  minus sign before the dollar; one that rounds to nothing is `$0.00`, never a
  negative zero.
  """
  def money(cost) when is_number(cost) do
    size = abs(cost)
    decimals = if size > 0 and size < 0.01, do: 4, else: 2
    digits = :erlang.float_to_binary(size / 1, decimals: decimals)

    cond do
      cost >= 0 -> "$" <> digits
      zero_digits?(digits) -> "$0.00"
      true -> "−$" <> digits
    end
  end

  def money(_), do: "$0.00"

  defp zero_digits?(digits), do: String.trim(digits, "0") in [".", ""]
end
