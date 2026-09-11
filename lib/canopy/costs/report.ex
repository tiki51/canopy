defmodule Canopy.Costs.Report do
  @moduledoc """
  The spend report as text: what the `costs_report` tool returns and what the
  auditor reads. Everything in it comes from `Canopy.Costs`, plus the settings
  that shape spend and, when OpenCode answers, the prices of the models in use.
  """

  alias Canopy.{Costs, Settings}
  alias Canopy.OpenCode.Client
  alias Canopy.Runtime.ChannelServer
  alias Canopy.Schedules.When

  @periods %{"today" => :today, "week" => :week, "month" => :month, "all" => :all}
  @labels %{today: "today", week: "the last 7 days", month: "the last 30 days", all: "all time"}

  @doc "The period names the report accepts."
  def periods, do: Map.keys(@periods) |> Enum.sort()

  @doc "Parses a period name; `week` when nil, an error for anything unknown."
  def period(nil), do: {:ok, :week}
  def period(""), do: {:ok, :week}

  def period(name) when is_binary(name) do
    case Map.fetch(@periods, String.downcase(String.trim(name))) do
      {:ok, period} ->
        {:ok, period}

      :error ->
        {:error, "unknown period #{inspect(name)}; use one of #{Enum.join(periods(), ", ")}"}
    end
  end

  @doc "The full report for a period atom (`:today`, `:week`, `:month`, `:all`)."
  def render(period) when is_atom(period) do
    since = Costs.since(period)
    total = Costs.total(since)
    eff = Costs.efficiency(since)

    [
      "Canopy spend report for #{@labels[period]}#{since_line(since)}. Generated #{now()} local time. Costs are what providers report through OpenCode; unpriced (subscription) models count as $0.",
      "Total: #{Costs.money(total.cost)} over #{total.turns} turns, #{total.tools} tool calls; #{Costs.money(eff.avg_cost)} per turn on average.",
      "Today #{Costs.money(Costs.total(Costs.since(:today)).cost)} · last 7 days #{Costs.money(Costs.total(Costs.since(:week)).cost)} · all time #{Costs.money(Costs.total(nil).cost)}.",
      "",
      breakdown("By agent", Costs.by_agent(since), total.cost),
      breakdown("By channel", Costs.by_channel(since), total.cost),
      breakdown("By model", Costs.by_model(since), total.cost),
      breakdown("By trigger (what woke the agent)", Costs.by_trigger(since), total.cost),
      efficiency(eff),
      top_turns(Costs.top_turns(since, 6)),
      budgets(Costs.channel_budgets()),
      settings(),
      prices(since)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp since_line(nil), do: ""
  defp since_line(since), do: " (since #{local(since)})"

  defp breakdown(title, [], _total), do: ["#{title}: nothing in this period.", ""]

  defp breakdown(title, rows, total) do
    lines =
      Enum.map(rows, fn row ->
        "- #{row.label}: #{Costs.money(row.cost)} (#{share(row.cost, total)}%), #{row.turns} turns, #{row.tools} tool calls, #{duration(row.duration_ms)}"
      end)

    ["#{title}:" | lines] ++ [""]
  end

  defp efficiency(eff) do
    t = eff.tokens

    [
      "Efficiency:",
      "- #{eff.steps} model calls across #{eff.turns} turns; average context #{tokens(eff.avg_context)} tokens per call (compaction cap #{tokens(ChannelServer.context_cap())})",
      "- tokens: #{tokens(t.input + t.cache_read)} prompt (#{tokens(t.cache_read)} read from cache, #{tokens(t.cache_write)} written), #{tokens(t.output)} output, #{tokens(t.reasoning)} reasoning; cache hit rate #{rate(eff.cache_rate)}",
      "- #{eff.passed.turns} turns passed without replying (#{Costs.money(eff.passed.cost)}); #{eff.errors.turns} turns ended in an error (#{Costs.money(eff.errors.cost)}); #{eff.compactions} session compactions",
      ""
    ]
  end

  defp top_turns([]), do: ["Costliest turns: none with a cost.", ""]

  defp top_turns(turns) do
    lines =
      Enum.map(turns, fn t ->
        "- #{Costs.money(t.cost)} #{t.agent} in #{t.channel}, #{local(t.at)}, woken by #{t.trigger || "unknown"}, #{t.tools} tool calls, #{t.steps} model calls, context #{tokens(t.context)}, #{duration(t.duration_ms)}#{turn_flags(t)}"
      end)

    ["Costliest turns:" | lines] ++ [""]
  end

  defp turn_flags(%{passed: true}), do: ", passed (no reply)"
  defp turn_flags(%{outcome: "error"}), do: ", ended in error"
  defp turn_flags(_), do: ""

  defp budgets([]),
    do: [
      "Channel spend limits: none set. The user sets them on a channel's Budget panel; agents may set one when creating a channel.",
      ""
    ]

  defp budgets(rows) do
    lines =
      Enum.map(rows, fn b ->
        "- #{b.label}: #{Costs.money(b.spent)} of #{Costs.money(b.limit)}#{if b.reached?, do: " (reached; agents are held there)", else: ""}"
      end)

    ["Channel spend limits (only the user changes them):" | lines] ++ [""]
  end

  defp settings do
    s = Settings.get()

    pause =
      if s.chatter_pause,
        do: "pause after #{s.chatter_limit} agent turns without the user",
        else: "no pause on agent-to-agent chatter"

    [
      "Settings that shape spend: #{pause}; one turn at a time per channel #{if s.serialize_turns, do: "on", else: "off"}; sessions compact above #{tokens(ChannelServer.context_cap())} tokens of context.",
      ""
    ]
  end

  # Prices for the models that appear in the period, when OpenCode answers.
  defp prices(since) do
    models = since |> Costs.by_model() |> Enum.map(& &1.label)

    case models != [] && providers() do
      %{} = catalog ->
        lines =
          Enum.map(models, fn model ->
            case Map.get(catalog, model) do
              %{input: i, output: o, cache_read: c} when i > 0 or o > 0 ->
                "- #{model}: $#{fmt(i)} in / $#{fmt(o)} out / $#{fmt(c)} cached, per million tokens"

              %{} ->
                "- #{model}: no per-token price reported (usually a subscription plan)"

              nil ->
                "- #{model}: price unknown"
            end
          end)

        ["Model prices:" | lines]

      _ ->
        ["Model prices: unavailable (OpenCode did not answer)."]
    end
  end

  defp providers do
    case Client.impl().providers([]) do
      {:ok, %{"providers" => list}} when is_list(list) ->
        for %{"id" => pid, "models" => models} <- list,
            is_binary(pid) and is_map(models),
            {mid, m} <- models,
            into: %{} do
          cost = Map.get(m, "cost") || %{}

          {pid <> "/" <> mid,
           %{
             input: num(cost["input"]),
             output: num(cost["output"]),
             cache_read: num(get_in(cost, ["cache", "read"]))
           }}
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: 0.0

  defp fmt(n) when n < 0.1, do: :erlang.float_to_binary(n / 1, decimals: 3)
  defp fmt(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp share(cost, total) when is_number(total) and total > 0, do: round(cost / total * 100)
  defp share(_, _), do: 0

  defp rate(nil), do: "n/a"
  defp rate(r), do: "#{round(r * 100)}%"

  defp tokens(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp tokens(n) when is_number(n), do: to_string(round(n))
  defp tokens(_), do: "0"

  defp duration(ms) when is_integer(ms) and ms >= 3_600_000,
    do: "#{Float.round(ms / 3_600_000, 1)}h"

  defp duration(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)}m"
  defp duration(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp duration(_), do: "0s"

  defp now, do: NaiveDateTime.local_now() |> Calendar.strftime("%Y-%m-%d %H:%M")

  defp local(%DateTime{} = at),
    do: at |> When.to_local_naive() |> Calendar.strftime("%Y-%m-%d %H:%M")
end
