defmodule Canopy.Schedules.When do
  @moduledoc """
  Parses the `when` an agent gives a schedule. Three forms:

    * an ISO 8601 datetime, with an offset (`2026-09-10T14:00:00-07:00`) or
      without (`2026-09-10T14:00`, taken as local time);
    * a relative duration: `30m`, `2h`, `1d`, `90s`, or `in 45 minutes`;
    * a five-field cron expression (`0 9 * * 1-5`), evaluated in local time.

  Returns `{:once, %DateTime{}}` (UTC), `{:recurring, cron, %DateTime{}}` with
  the first run, or `{:error, reason}`. Guardrails: nothing in the past, one-offs
  at most a year out, recurring at least five minutes apart.
  """

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @min_interval_s 5 * 60
  @max_horizon_s 366 * 24 * 60 * 60

  @units %{
    "s" => 1,
    "sec" => 1,
    "secs" => 1,
    "second" => 1,
    "seconds" => 1,
    "m" => 60,
    "min" => 60,
    "mins" => 60,
    "minute" => 60,
    "minutes" => 60,
    "h" => 3600,
    "hr" => 3600,
    "hrs" => 3600,
    "hour" => 3600,
    "hours" => 3600,
    "d" => 86_400,
    "day" => 86_400,
    "days" => 86_400,
    "w" => 604_800,
    "week" => 604_800,
    "weeks" => 604_800
  }

  @spec parse(String.t() | nil, DateTime.t()) ::
          {:once, DateTime.t()} | {:recurring, String.t(), DateTime.t()} | {:error, String.t()}
  def parse(value, now \\ DateTime.utc_now())

  def parse(value, now) when is_binary(value) do
    text = value |> String.trim() |> String.replace(~r/^(in|at)\s+/i, "")

    cond do
      text == "" -> {:error, "when is empty"}
      relative?(text) -> relative(text, now)
      cron?(text) -> recurring(text, now)
      true -> absolute(text, now)
    end
  end

  def parse(_, _now), do: {:error, "when is empty"}

  @doc "The next occurrence of a cron expression after `after`, in UTC."
  @spec next_run(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def next_run(cron, after_dt) do
    with {:ok, expr} <- parse_cron(cron) do
      local = to_local_naive(after_dt) |> NaiveDateTime.add(1, :second)

      case Scheduler.get_next_run_date(expr, local) do
        {:ok, next} -> {:ok, from_local_naive(next)}
        {:error, reason} -> {:error, "cron has no next run: #{inspect(reason)}"}
      end
    end
  end

  @doc "Seconds between the machine's local clock and UTC right now."
  def local_offset_seconds do
    utc = DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
    local = NaiveDateTime.local_now()
    # round to the minute: the two clocks are read a moment apart
    div(NaiveDateTime.diff(local, utc, :second) + 30, 60) * 60
  end

  def to_local_naive(%DateTime{} = dt),
    do: dt |> DateTime.to_naive() |> NaiveDateTime.add(local_offset_seconds(), :second)

  def from_local_naive(%NaiveDateTime{} = naive) do
    naive
    |> NaiveDateTime.add(-local_offset_seconds(), :second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  # -- forms --------------------------------------------------------------------

  defp relative?(text), do: Regex.match?(~r/^\d+\s*[a-z]+$/i, text)

  defp relative(text, now) do
    [_, n, unit] = Regex.run(~r/^(\d+)\s*([a-z]+)$/i, text)

    case Map.fetch(@units, String.downcase(unit)) do
      {:ok, seconds} -> once(DateTime.add(now, String.to_integer(n) * seconds, :second), now)
      :error -> {:error, "unknown unit #{inspect(unit)}; use s, m, h, d, or w"}
    end
  end

  defp cron?(text), do: length(String.split(text)) == 5

  defp recurring(text, now) do
    with {:ok, expr} <- parse_cron(text),
         :ok <- check_interval(expr, now),
         {:ok, first} <- next_run(text, now) do
      {:recurring, text, first}
    end
  end

  defp absolute(text, now) do
    text = text |> String.replace(" ", "T", global: false) |> pad_seconds()

    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} ->
        once(dt, now)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, naive} ->
            once(from_local_naive(naive), now)

          {:error, _} ->
            {:error,
             "could not read #{inspect(text)}: use an ISO datetime, a duration like 2h, or a cron line"}
        end
    end
  end

  # "T14:00" and "T14:00-07:00" both get their seconds
  defp pad_seconds(text), do: Regex.replace(~r/(T\d{2}:\d{2})(?=$|[Zz+-])/, text, "\\1:00")

  defp once(%DateTime{} = at, now) do
    diff = DateTime.diff(at, now, :second)

    cond do
      diff < 0 -> {:error, "that time is in the past"}
      diff > @max_horizon_s -> {:error, "that is more than a year away"}
      true -> {:once, DateTime.truncate(at, :second)}
    end
  end

  defp parse_cron(text) do
    case Parser.parse(text) do
      {:ok, %CronExpression{} = expr} -> {:ok, expr}
      {:error, reason} -> {:error, "bad cron expression: #{reason}"}
    end
  end

  # two consecutive runs must be at least five minutes apart
  defp check_interval(expr, now) do
    local = to_local_naive(now)

    with {:ok, a} <- Scheduler.get_next_run_date(expr, local),
         {:ok, b} <- Scheduler.get_next_run_date(expr, NaiveDateTime.add(a, 1, :second)) do
      if NaiveDateTime.diff(b, a, :second) < @min_interval_s,
        do: {:error, "recurring schedules must be at least 5 minutes apart"},
        else: :ok
    else
      _ -> {:error, "cron has no next run"}
    end
  end
end
