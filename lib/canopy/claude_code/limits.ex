defmodule Canopy.ClaudeCode.Limits do
  @moduledoc """
  Reads a Claude Code usage or billing limit from what the CLI reports
  (2.1.283): the stream's rejected `rate_limit_event.rate_limit_info`
  (`%{"status" => "rejected", "resetsAt" => epoch_s, "rateLimitType" =>
  "five_hour"}`, the transcript's `quotaLimits`), and the result's text
  (`"You've hit your session limit · resets 4:50am (America/Los_Angeles)"`).

  Pure: `now` makes the "next 4:50am" reading deterministic. The text's
  clock time is read in the machine's local zone (there is no tz database
  in deps), so a named zone other than the local one gives no reset time.
  """

  alias Canopy.EnginePauses

  @type limit :: %{
          kind: String.t(),
          reason: String.t(),
          resets_at: DateTime.t() | nil,
          detail: String.t() | nil
        }

  @doc """
  The limit the error `text` stands for, with the reset time and type
  from `rate_limit` (a rejected `rate_limit_info`, or nil) when given; nil
  when the text isn't one (the per-turn budget, the fast-mode limit, a full
  context and other errors are not, even after a rejected window).
  """
  @spec from(map() | nil, String.t() | nil, DateTime.t()) :: limit | nil
  def from(rate_limit, text, %DateTime{} = now) do
    # The error's text decides: a rejected window can precede an unrelated
    # error (max turns, an API 500), and only lends the reset and its type.
    if EnginePauses.limit_error?(text || "") do
      rate_limit = if match?(%{"status" => "rejected"}, rate_limit), do: rate_limit, else: %{}

      resets_at =
        EnginePauses.epoch(rate_limit["resetsAt"]) || suffix_epoch(text) || clock_time(text, now)

      {kind, reason} = kind(rate_limit["rateLimitType"], text, resets_at)
      %{kind: kind, reason: reason, resets_at: resets_at, detail: text}
    end
  end

  # -- Reset time ---------------------------------------------------------------

  # "Claude AI usage limit reached|1759683600"
  defp suffix_epoch(text) when is_binary(text) do
    case Regex.run(~r/\|(\d{9,13})\s*$/, text) do
      [_, digits] -> EnginePauses.epoch(digits)
      _ -> nil
    end
  end

  defp suffix_epoch(_), do: nil

  # "resets 4:50am (America/Los_Angeles)", "resets 3pm": the next such time
  # after now, in the machine's local zone
  defp clock_time(text, now) when is_binary(text) do
    with [_, h, m, ampm | rest] <-
           Regex.run(~r/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?/i, text),
         true <- local_zone?(List.first(rest)),
         {hour, minute} when hour in 0..23 and minute in 0..59 <- clock(h, m, ampm) do
      next_local(now, hour, minute)
    else
      _ -> nil
    end
  end

  defp clock_time(_text, _now), do: nil

  defp clock(h, m, ampm) do
    hour = String.to_integer(h)
    minute = if m in [nil, ""], do: 0, else: String.to_integer(m)

    if hour in 1..12 do
      hour =
        case String.downcase(ampm) do
          "am" -> rem(hour, 12)
          "pm" -> rem(hour, 12) + 12
        end

      {hour, minute}
    else
      :error
    end
  end

  defp next_local(now, hour, minute) do
    {local_date, _} =
      now
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    Enum.find_value(0..1, fn days ->
      date = local_date |> Date.from_erl!() |> Date.add(days) |> Date.to_erl()

      with [utc | _] <- :calendar.local_time_to_universal_time_dst({date, {hour, minute, 0}}),
           at = utc |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC"),
           :gt <- DateTime.compare(at, now) do
        DateTime.add(at, 0, :microsecond)
      else
        _ -> nil
      end
    end)
  end

  @doc false
  # No zone named, or the machine's own (TZ, else /etc/localtime's target).
  def local_zone?(nil), do: true
  def local_zone?(""), do: true
  def local_zone?(zone), do: String.trim(zone) == local_zone()

  @doc false
  def local_zone do
    case System.get_env("TZ") do
      ":" <> zone when zone != "" ->
        zone

      zone when is_binary(zone) and zone != "" ->
        zone

      _ ->
        case File.read_link("/etc/localtime") do
          {:ok, target} ->
            case String.split(target, "zoneinfo/", parts: 2) do
              [_, zone] -> zone
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  # -- Kind and reason -------------------------------------------------------------

  defp kind(type, text, resets_at) do
    text = text || ""

    cond do
      type == "five_hour" ->
        {"usage", "usage limit"}

      is_binary(type) and String.starts_with?(type, "seven_day") ->
        {"usage", "weekly usage limit"}

      type == "overage" ->
        {"usage", "usage limit"}

      Regex.match?(~r/out of extra usage/i, text) ->
        {"usage", "usage limit"}

      Regex.match?(~r/monthly spend limit/i, text) ->
        {"billing", "monthly spend limit"}

      Regex.match?(~r/credit balance (is )?too low/i, text) ->
        {"billing", "insufficient balance"}

      Regex.match?(~r/weekly/i, text) ->
        {"usage", "weekly usage limit"}

      resets_at != nil ->
        {"usage", "usage limit"}

      true ->
        {"billing", "usage limit"}
    end
  end
end
