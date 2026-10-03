defmodule Canopy.Costs.Routing do
  @moduledoc """
  Model routing in numbers (experimental; routing is off until the Phase 0
  spike). Everything here reads the `agent_turn_completed` summaries:

    * `wake_profile/1` — what each kind of wake costs and how often it buys
      nothing, from turns recorded before routing existed (Phase 1). Turns
      without a recorded `wake_kind` get one from their trigger, with
      delegations split into the task and the report by `delegation_ids`.
    * `candidates/1` — what routing the light kinds would have saved: each
      candidate turn re-priced on the light model. **Estimates**: Claude
      Code prices come from `config :canopy, :claude_list_prices`, OpenCode
      prices from its catalogue, and cache warmth is guessed from how soon a
      session's turn followed its previous one.
    * `by_route/1`, `routing_savings/1`, `rule_stats/1` — light turns once
      routing runs, their escalations, and the net saving (an estimate
      against a baseline of the agent's main turns of the same kind).
    * `check_pause/2` — the auto-disable: a rule pauses for an agent when
      at least 10 of its last 20 light turns of a kind exist and 35% or more
      escalated (each escalation pays for a light turn and a main turn).
  """

  import Ecto.Query

  alias Canopy.{Agents, Repo, Settings}
  alias Canopy.Agents.Agent
  alias Canopy.OpenCode.Providers
  alias Canopy.Runtime.Routing
  alias Canopy.Timeline.Event

  @window 20
  @min_turns 10
  @pause_rate 0.35
  # a turn with nothing to show: no files, no reply of its own, a few tool calls
  @quiet_tools 3
  # the cache-warmth guard's floor, as in `Canopy.Runtime.Routing`
  @warm_context 20_000
  @baseline_days 14

  @doc "The auto-disable thresholds: `{window, min_turns, rate}`."
  def pause_thresholds, do: {@window, @min_turns, @pause_rate}

  # -- Turn rows ------------------------------------------------------------------

  @doc """
  The turn summaries since `since` (nil: all time), oldest first, as plain
  maps of the fields routing reads. `:kind` is the recorded wake kind, else
  one derived from the trigger.
  """
  def turns(since, extra \\ fn q -> q end) do
    from(e in Event, where: e.event_type == "agent_turn_completed", order_by: [asc: e.id])
    |> then(&if since, do: from(e in &1, where: e.inserted_at >= ^since), else: &1)
    |> extra.()
    |> select([e], %{
      id: e.id,
      agent_id: e.agent_id,
      session: e.ref_id,
      at: e.inserted_at,
      trigger: fragment("json_extract(?, '$.trigger')", e.payload),
      wake_kind: fragment("json_extract(?, '$.wake_kind')", e.payload),
      ack: fragment("json_extract(?, '$.ack')", e.payload),
      delegations:
        fragment("COALESCE(json_array_length(json_extract(?, '$.delegation_ids')), 0)", e.payload),
      passed: fragment("COALESCE(json_extract(?, '$.passed'), 0)", e.payload),
      files: fragment("COALESCE(json_array_length(json_extract(?, '$.files')), 0)", e.payload),
      final_text: fragment("json_extract(?, '$.final_text') IS NOT NULL", e.payload),
      reacted:
        fragment("COALESCE(json_extract(?, '$.activity'), '') LIKE '%\"canopy react%'", e.payload),
      tools: fragment("COALESCE(json_extract(?, '$.tools'), 0)", e.payload),
      cost: fragment("COALESCE(json_extract(?, '$.cost'), 0)", e.payload),
      duration_ms: fragment("COALESCE(json_extract(?, '$.duration_ms'), 0)", e.payload),
      context: fragment("COALESCE(json_extract(?, '$.context'), 0)", e.payload),
      input: fragment("COALESCE(json_extract(?, '$.tokens.input'), 0)", e.payload),
      output: fragment("COALESCE(json_extract(?, '$.tokens.output'), 0)", e.payload),
      reasoning: fragment("COALESCE(json_extract(?, '$.tokens.reasoning'), 0)", e.payload),
      cache_read: fragment("COALESCE(json_extract(?, '$.tokens.cache_read'), 0)", e.payload),
      cache_write: fragment("COALESCE(json_extract(?, '$.tokens.cache_write'), 0)", e.payload),
      model: fragment("json_extract(?, '$.model')", e.payload),
      profile: fragment("json_extract(?, '$.profile')", e.payload),
      escalated: fragment("COALESCE(json_extract(?, '$.escalated'), 0)", e.payload),
      model_switch: fragment("COALESCE(json_extract(?, '$.model_switch'), 0)", e.payload)
    })
    |> Repo.all()
    |> Enum.map(&normalize/1)
  end

  defp normalize(row) do
    row = %{
      row
      | passed: truthy?(row.passed),
        final_text: truthy?(row.final_text),
        reacted: truthy?(row.reacted),
        escalated: truthy?(row.escalated),
        model_switch: truthy?(row.model_switch),
        ack: if(is_nil(row.ack), do: nil, else: truthy?(row.ack)),
        cost: (row.cost || 0) / 1
    }

    Map.put(row, :kind, row.wake_kind || derived_kind(row))
  end

  defp truthy?(v), do: v in [true, 1, "1", "true"]

  # Phase 1: turns from before wake kinds were recorded.
  defp derived_kind(%{trigger: "delegation", delegations: n}) when n > 0, do: "delegation_task"
  defp derived_kind(%{trigger: "delegation"}), do: "delegation_report"
  # the router's reason was not recorded: mention, thread, and owner fallback
  # stay together
  defp derived_kind(%{trigger: "agent"}), do: "agent_message"
  defp derived_kind(%{trigger: "handoff"}), do: "handoff"
  defp derived_kind(%{trigger: nil}), do: "unknown"
  defp derived_kind(%{trigger: trigger}), do: Routing.kind_for_trigger(trigger)

  # A turn that bought nothing visible: it passed, or changed no file, wrote
  # no reply through the tools, and made a few tool calls at most.
  defp quiet?(t), do: t.passed or (t.files == 0 and not t.final_text and t.tools <= @quiet_tools)

  # -- Phase 1: what each kind of wake costs ----------------------------------------

  @doc """
  Per wake kind since `since`, costliest first: turns, cost, average cost,
  pass rate, quiet rate (passed, or no files, no reply of its own, at most
  #{@quiet_tools} tool calls), reactions, average context, average output
  (plus reasoning) tokens, and the share whose session's previous turn ended
  within the cache window (warm). `light?` marks the kinds the rules may send
  to the light model.
  """
  def wake_profile(since) do
    rows = since |> turns() |> with_warmth()

    rows
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, ts} ->
      n = length(ts)
      cost = sum(ts, & &1.cost)

      %{
        kind: kind,
        turns: n,
        cost: cost,
        avg_cost: cost / n,
        passed: Enum.count(ts, & &1.passed),
        pass_rate: Enum.count(ts, & &1.passed) / n,
        quiet_rate: Enum.count(ts, &quiet?/1) / n,
        reacted: Enum.count(ts, & &1.reacted),
        avg_context: div(round(sum(ts, & &1.context)), n),
        avg_output: div(round(sum(ts, &(&1.output + &1.reasoning))), n),
        warm_share: Enum.count(ts, & &1.warm?) / n,
        light?: kind in Routing.light_kinds() or kind == "agent_message"
      }
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  # Each turn learns whether its session's previous turn ended within the
  # cache window before it started (start = end - duration).
  defp with_warmth(rows) do
    ttl = Routing.cache_ttl_ms()

    {rows, _last} =
      Enum.map_reduce(rows, %{}, fn t, last ->
        start = DateTime.add(t.at, -round(t.duration_ms), :millisecond)

        warm? =
          case Map.get(last, t.session) do
            nil -> false
            ended -> DateTime.diff(start, ended, :millisecond) < ttl
          end

        {Map.put(t, :warm?, warm?), Map.put(last, t.session, t.at)}
      end)

    rows
  end

  @doc """
  What routing the light kinds would have saved since `since`, per kind:
  candidate turns, what they cost (as recorded; a Claude Code turn with no
  recorded cost is priced from its tokens at list price), what they would have cost on the light
  model, and the turns the cache-warmth guard would have kept on main.
  **Estimates.** A candidate is a turn of a light kind (an agent mention or
  thread reply only when recorded as an acknowledgement; an agent message
  from before kinds were recorded only when it was quiet). The light model
  is the engine's light model from Settings, else `haiku` for Claude Code
  (assumed); OpenCode turns with no light model set are left out. A warm
  turn's light call re-reads the context as a cache write.
  """
  def candidates(since, opts \\ []) do
    setting = Settings.get()
    claude = Application.get_env(:canopy, :claude_list_prices, %{})

    light =
      Map.new(Canopy.Engine.names(), fn engine ->
        {engine, light_model(engine, setting)}
      end)

    # OpenCode is asked for prices only when an OpenCode light model is set
    catalog =
      Keyword.get_lazy(opts, :catalog, fn ->
        if Map.get(light, "opencode"), do: opencode_catalog(), else: %{}
      end)

    rows =
      since
      |> turns()
      |> with_warmth()
      |> Enum.filter(&candidate?/1)
      |> Enum.map(fn t ->
        engine = engine_of(t.model, claude)
        model = Map.get(light, engine)

        cond do
          t.warm? and t.context >= @warm_context ->
            Map.put(t, :fate, :kept_main)

          is_nil(model) or model.label == t.model ->
            Map.put(t, :fate, :no_estimate)

          price = price_of(model.label, claude, catalog) ->
            t
            |> Map.put(:fate, :light)
            |> Map.put(:cost, main_cost(t, claude))
            |> Map.put(:light_cost, token_cost(t, price, t.warm?))

          true ->
            Map.put(t, :fate, :no_estimate)
        end
      end)

    by_kind =
      rows
      |> Enum.group_by(& &1.kind)
      |> Enum.map(fn {kind, ts} ->
        routed = Enum.filter(ts, &(&1.fate == :light))
        cost = sum(routed, & &1.cost)
        light_cost = sum(routed, & &1.light_cost)

        %{
          kind: kind,
          candidates: length(ts),
          routed: length(routed),
          kept_main: Enum.count(ts, &(&1.fate == :kept_main)),
          no_estimate: Enum.count(ts, &(&1.fate == :no_estimate)),
          cost: cost,
          light_cost: light_cost,
          saving: cost - light_cost
        }
      end)
      |> Enum.sort_by(& &1.saving, :desc)

    %{
      rows: by_kind,
      saving: sum(by_kind, & &1.saving),
      light_models: Map.new(light, fn {engine, m} -> {engine, m && m.label} end),
      assumed: Map.new(light, fn {engine, m} -> {engine, m != nil and m.assumed?} end)
    }
  end

  defp candidate?(%{kind: "agent_message"} = t), do: quiet?(t)

  defp candidate?(%{kind: kind, ack: ack}) do
    if kind in Routing.ack_kinds(), do: ack == true, else: kind in Routing.light_kinds()
  end

  defp light_model(engine, setting) do
    case Settings.light_profile(engine, setting) do
      %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) ->
        %{label: p <> "/" <> m, assumed?: false}

      %{model_id: m} when is_binary(m) and engine == "claude_code" ->
        %{label: m, assumed?: false}

      _ when engine == "claude_code" ->
        %{label: "haiku", assumed?: true}

      _ ->
        nil
    end
  end

  defp engine_of(model, claude) do
    cond do
      Map.has_key?(claude, model) or model == "claude default" -> "claude_code"
      true -> "opencode"
    end
  end

  defp price_of(label, claude, catalog) do
    case Map.get(claude, label) || Map.get(catalog || %{}, label) do
      %{input: i} = p when is_number(i) and i > 0 -> Map.put_new(p, :cache_write, i * 1.25)
      _ -> nil
    end
  end

  # What the turn cost on main: what it recorded. A Claude Code turn with no
  # recorded cost (it failed before its result) is priced from its tokens at
  # list price instead. (Claude Code turns once recorded the session's running
  # total; the upgrade that fixed it corrected the old turns too.)
  defp main_cost(%{cost: cost}, _claude) when cost > 0, do: cost

  defp main_cost(t, claude) do
    case price_of(t.model, claude, %{}) do
      nil -> t.cost
      price -> token_cost(t, price, false)
    end
  end

  # Dollars for the turn's tokens at `price`. On a light model, a warm turn's
  # main cache is no use: its first call writes the context.
  defp token_cost(t, price, cold_light?) do
    {reads, writes} =
      if cold_light?,
        do: {max(t.cache_read - t.context, 0), t.cache_write + t.context},
        else: {t.cache_read, t.cache_write}

    (t.input * price.input + reads * Map.get(price, :cache_read, 0) +
       writes * price.cache_write + (t.output + t.reasoning) * price.output) / 1_000_000
  end

  # "provider/model" => pricing, from OpenCode's catalogue when it answers.
  defp opencode_catalog do
    case Providers.list() do
      {:ok, %{providers: providers}} ->
        for %{id: pid, pricing: pricing} <- providers,
            {mid, price} <- pricing,
            price,
            into: %{} do
          {pid <> "/" <> mid, price}
        end

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # -- Once routing runs ------------------------------------------------------------

  @doc """
  Turns since `since` by how they ran: `main` (everything not light, the
  re-runs aside), `light` (kept), `escalated` (light turns that escalated),
  and `rerun` (the main re-runs after an escalation or a light failure),
  each with turns, cost, prompt and output tokens, and cache writes.
  """
  def by_route(since) do
    rows = turns(since)

    groups = [
      {"main", "main model", &(&1.profile != "light" and &1.kind != "escalation")},
      {"light", "light model (kept)", &(&1.profile == "light" and not &1.escalated)},
      {"escalated", "light model (escalated)", &(&1.profile == "light" and &1.escalated)},
      {"rerun", "re-runs on main", &(&1.kind == "escalation")}
    ]

    for {key, label, pick} <- groups do
      ts = Enum.filter(rows, pick)

      %{
        key: key,
        label: label,
        turns: length(ts),
        cost: sum(ts, & &1.cost),
        tokens: round(sum(ts, &(&1.input + &1.cache_read + &1.output + &1.reasoning))),
        cache_write: round(sum(ts, & &1.cache_write))
      }
    end
  end

  @doc """
  The estimated net saving of routing since `since`:

    * `gross` — over kept light turns, the agent's average main-model cost
      for the same wake kind (its main turns from #{@baseline_days} days before
      `since` onwards; turns with no baseline are left out) minus what the
      light turn cost
    * `waste` — what escalated light turns cost (their wake was paid twice)
    * `penalty` — over main turns right after a switch, what they cost above
      the agent's average main turn of that kind (the cold cache re-read)
    * `net` — gross minus waste minus penalty
  """
  def routing_savings(since) do
    from = if since, do: DateTime.add(since, -@baseline_days * 86_400, :second)
    rows = turns(from)

    in_period =
      if since, do: Enum.filter(rows, &(DateTime.compare(&1.at, since) != :lt)), else: rows

    baseline =
      rows
      |> Enum.filter(&(&1.profile != "light" and &1.kind != "escalation" and not &1.model_switch))
      |> Enum.group_by(&{&1.agent_id, &1.kind})
      |> Map.new(fn {key, ts} -> {key, sum(ts, & &1.cost) / length(ts)} end)

    kept = Enum.filter(in_period, &(&1.profile == "light" and not &1.escalated))

    gross =
      kept
      |> Enum.flat_map(fn t ->
        case Map.get(baseline, {t.agent_id, t.kind}) do
          nil -> []
          avg -> [avg - t.cost]
        end
      end)
      |> Enum.sum()

    waste = in_period |> Enum.filter(&(&1.profile == "light" and &1.escalated)) |> sum(& &1.cost)

    penalty =
      in_period
      |> Enum.filter(&(&1.profile != "light" and &1.model_switch))
      |> Enum.map(fn t -> max(t.cost - Map.get(baseline, {t.agent_id, t.kind}, t.cost), 0) end)
      |> Enum.sum()

    %{
      light_turns:
        length(kept) + Enum.count(in_period, &(&1.profile == "light" and &1.escalated)),
      gross: gross / 1,
      waste: waste,
      penalty: penalty / 1,
      net: (gross - waste - penalty) / 1
    }
  end

  @doc """
  An agent's last #{@window} light turns per wake kind, with how many
  escalated: `[%{kind, turns, escalated, rate}]`, the window starting when
  the kind's rule was last resumed.
  """
  def rule_stats(agent_id) do
    agent_id
    |> light_turns(nil)
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, ts} ->
      ts =
        case Agents.routing_window_start(agent_id, kind) do
          nil -> ts
          start -> Enum.filter(ts, &(DateTime.compare(&1.at, start) == :gt))
        end
        |> Enum.take(-@window)

      stats(kind, ts)
    end)
    |> Enum.reject(&(&1.turns == 0))
    |> Enum.sort_by(& &1.kind)
  end

  defp stats(kind, ts) do
    n = length(ts)
    escalated = Enum.count(ts, & &1.escalated)
    %{kind: kind, turns: n, escalated: escalated, rate: if(n > 0, do: escalated / n, else: 0.0)}
  end

  @doc "The escalation rate per wake kind over every routed agent's recent light turns, since `since`."
  def escalation_by_kind(since) do
    since
    |> turns(&from(e in &1, where: fragment("json_extract(?, '$.profile') = 'light'", e.payload)))
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, ts} -> stats(kind, ts) end)
    |> Enum.sort_by(& &1.kind)
  end

  defp light_turns(agent_id, since) do
    turns(
      since,
      &from(e in &1,
        where:
          e.agent_id == ^agent_id and
            fragment("json_extract(?, '$.profile') = 'light'", e.payload)
      )
    )
  end

  @doc """
  The auto-disable, run after each light turn: pauses `wake_kind` for the
  agent when at least #{@min_turns} of its last #{@window} light turns of that
  kind (since the rule was last resumed) exist and #{round(@pause_rate * 100)}% or
  more escalated. Returns `{:paused, reason}` or `:ok`.
  """
  def check_pause(agent_id, wake_kind) do
    start = Agents.routing_window_start(agent_id, wake_kind)

    ts =
      turns(
        start,
        &from(e in &1,
          where:
            e.agent_id == ^agent_id and
              fragment("json_extract(?, '$.profile') = 'light'", e.payload) and
              fragment("json_extract(?, '$.wake_kind') = ?", e.payload, ^wake_kind)
        )
      )
      |> Enum.reject(&(start && DateTime.compare(&1.at, start) != :gt))
      |> Enum.take(-@window)

    %{turns: n, escalated: escalated, rate: rate} = stats(wake_kind, ts)

    if n >= @min_turns and rate >= @pause_rate and
         not MapSet.member?(Agents.paused_kinds(agent_id), wake_kind) do
      reason = "#{escalated} of #{n} escalated"
      {:ok, _} = Agents.pause_routing(agent_id, wake_kind, reason)
      {:paused, reason}
    else
      :ok
    end
  end

  @doc "Agents with routing on, by name."
  def routed_agents do
    Repo.all(from a in Agent, where: a.routing_enabled == true, order_by: a.name)
  end

  @doc "Every paused rule, with its agent, newest first."
  def paused_rules do
    Repo.all(
      from p in Agents.RoutingPause,
        where: not is_nil(p.paused_at),
        order_by: [desc: p.paused_at],
        preload: :agent
    )
  end

  defp sum(list, fun), do: Enum.reduce(list, 0.0, &(fun.(&1) + &2))
end
