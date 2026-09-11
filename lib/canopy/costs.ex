defmodule Canopy.Costs do
  @moduledoc """
  Spend, from the cost OpenCode reports for every finished turn (kept on the
  `agent_turn_completed` timeline event). Everything here is a query over
  those events: totals by period, and breakdowns by agent, channel, model, and
  day. Costs are in US dollars as reported by the provider through OpenCode;
  turns whose provider reports nothing count as zero.
  """

  import Ecto.Query

  alias Canopy.Repo
  alias Canopy.Schedules.When
  alias Canopy.Timeline.Event

  @type row :: %{
          key: term,
          label: String.t(),
          cost: float,
          turns: non_neg_integer,
          tools: non_neg_integer,
          duration_ms: non_neg_integer
        }

  @doc "Total cost and turn count since `since` (nil for all time)."
  def total(since \\ nil) do
    base(since)
    |> select([e], %{
      cost: sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)),
      turns: count(e.id),
      tools: sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload))
    })
    |> Repo.one()
    |> then(fn r -> %{cost: (r.cost || 0) / 1, turns: r.turns || 0, tools: r.tools || 0} end)
  end

  @doc "Spend per agent since `since`, highest first."
  def by_agent(since \\ nil) do
    base(since)
    |> join(:left, [e], a in Canopy.Agents.Agent, on: a.id == e.agent_id)
    |> group_by([e, a], [e.agent_id, a.name])
    |> select(
      [e, a],
      {e.agent_id, a.name, sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)),
       count(e.id), sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload)),
       sum(fragment("COALESCE(json_extract(?, '$.duration_ms'), 0)", e.payload))}
    )
    |> Repo.all()
    |> rows(fn {id, name, _, _, _, _} ->
      {id, if(name, do: "@" <> name, else: "removed agent")}
    end)
  end

  @doc "Spend per channel since `since`, highest first."
  def by_channel(since \\ nil) do
    base(since)
    |> join(:left, [e], c in Canopy.Channels.Channel, on: c.id == e.channel_id)
    |> group_by([e, c], [e.channel_id, c.name, c.kind])
    |> select(
      [e, c],
      {e.channel_id, fragment("? || '|' || COALESCE(?, '')", c.name, c.kind),
       sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)), count(e.id),
       sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload)),
       sum(fragment("COALESCE(json_extract(?, '$.duration_ms'), 0)", e.payload))}
    )
    |> Repo.all()
    |> rows(fn {id, name_kind, _, _, _, _} ->
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
      {fragment("COALESCE(json_extract(?, '$.model'), 'unknown')", e.payload),
       fragment("COALESCE(json_extract(?, '$.model'), 'unknown')", e.payload),
       sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)), count(e.id),
       sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload)),
       sum(fragment("COALESCE(json_extract(?, '$.duration_ms'), 0)", e.payload))}
    )
    |> Repo.all()
    |> rows(fn {model, _, _, _, _, _} -> {model, model} end)
  end

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
        {fragment("date(?, ?)", e.inserted_at, ^shift),
         sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)), count(e.id)}
      )
      |> Repo.all()
      |> Map.new(fn {day, cost, turns} -> {day, %{cost: (cost || 0) / 1, turns: turns}} end)

    for offset <- (days - 1)..0//-1 do
      day = Date.add(today, -offset)
      Map.merge(%{day: day, cost: 0.0, turns: 0}, Map.get(found, Date.to_iso8601(day), %{}))
    end
  end

  @doc "What one channel has spent, all time. The spend limit is checked against this."
  def channel_total(channel_id) when is_binary(channel_id) do
    from(e in Event,
      where: e.event_type == "agent_turn_completed" and e.channel_id == ^channel_id,
      select: sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload))
    )
    |> Repo.one()
    |> then(&((&1 || 0) / 1))
  end

  @doc "Spend per wake trigger (user, agent, delegation, handoff, scheduled) since `since`."
  def by_trigger(since \\ nil) do
    base(since)
    |> group_by([e], fragment("COALESCE(json_extract(?, '$.trigger'), 'unknown')", e.payload))
    |> select(
      [e],
      {fragment("COALESCE(json_extract(?, '$.trigger'), 'unknown')", e.payload),
       fragment("COALESCE(json_extract(?, '$.trigger'), 'unknown')", e.payload),
       sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)), count(e.id),
       sum(fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload)),
       sum(fragment("COALESCE(json_extract(?, '$.duration_ms'), 0)", e.payload))}
    )
    |> Repo.all()
    |> rows(fn {trigger, _, _, _, _, _} -> {trigger, trigger_label(trigger)} end)
  end

  defp trigger_label("user"), do: "your messages"
  defp trigger_label("agent"), do: "agent messages"
  defp trigger_label("delegation"), do: "delegations"
  defp trigger_label("handoff"), do: "handoffs"
  defp trigger_label("scheduled"), do: "scheduled tasks"
  defp trigger_label(_), do: "not recorded"

  @doc """
  How the money is spent since `since`: model calls, tokens, context, cache
  hits, and the turns that bought nothing (passed, errored). Token fields are
  zero for turns recorded before they were kept.
  """
  def efficiency(since \\ nil) do
    row =
      base(since)
      |> select([e], %{
        turns: count(e.id),
        cost: sum(fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload)),
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
          )
      })
      |> Repo.one()

    row = Map.new(row, fn {k, v} -> {k, v || 0} end)
    prompt_tokens = row.input + row.cache_read

    %{
      turns: row.turns,
      cost: row.cost / 1,
      tools: row.tools,
      steps: row.steps,
      avg_cost: if(row.turns > 0, do: row.cost / row.turns, else: 0.0),
      avg_context: if(row.with_context > 0, do: div(row.context, row.with_context), else: 0),
      tokens: %{
        input: row.input,
        output: row.output,
        reasoning: row.reasoning,
        cache_read: row.cache_read,
        cache_write: row.cache_write
      },
      cache_rate: if(prompt_tokens > 0, do: row.cache_read / prompt_tokens, else: nil),
      passed: %{turns: row.passed, cost: row.passed_cost / 1},
      errors: %{turns: row.errors, cost: row.error_cost / 1},
      compactions: compactions(since)
    }
  end

  defp compactions(since) do
    query = from(e in Event, where: e.event_type == "session_compacted", select: count(e.id))

    query =
      if since, do: from(e in query, where: e.inserted_at >= ^since), else: query

    Repo.one(query) || 0
  end

  @doc "The costliest turns since `since`, with who, where, and what they did."
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
        channel: channel_label(e.channel),
        cost: number(p["cost"]) / 1,
        tools: number(p["tools"]),
        steps: number(p["steps"]),
        context: number(p["context"]),
        duration_ms: number(p["duration_ms"]),
        trigger: p["trigger"],
        outcome: p["outcome"],
        passed: p["passed"] == true,
        model: p["model"],
        at: e.inserted_at
      }
    end)
  end

  defp channel_label(nil), do: "removed channel"
  defp channel_label(%{kind: "dm", id: id}), do: dm_label(id)
  defp channel_label(%{name: name}), do: "#" <> name

  @doc "Channels with a spend limit, with what each has spent."
  def channel_budgets do
    from(c in Canopy.Channels.Channel, where: not is_nil(c.spend_limit), order_by: c.name)
    |> Repo.all()
    |> Enum.map(fn c ->
      spent = channel_total(c.id)

      %{
        channel_id: c.id,
        label: channel_label(c),
        limit: c.spend_limit,
        spent: spent,
        reached?: spent >= c.spend_limit
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

  defp rows(list, keyer) do
    list
    |> Enum.map(fn {_, _, cost, turns, tools, duration} = row ->
      {key, label} = keyer.(row)

      %{
        key: key,
        label: label,
        cost: (cost || 0) / 1,
        turns: turns,
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

  @doc "Dollars with two decimals, or four when under a cent matters."
  def money(cost) when is_number(cost) do
    if cost > 0 and cost < 0.01,
      do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 4),
      else: "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)
  end

  def money(_), do: "$0.00"
end
