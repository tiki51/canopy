defmodule Canopy.Hold do
  @moduledoc """
  A global stop on agent activity. Engaged automatically when an engine reports
  a billing problem (no balance, quota or usage limit exhausted): every schedule
  pauses, every wake is dropped with a note in its channel, and a banner shows
  the reason on every page until you release it. Releasing resumes the schedules
  the hold paused; your next message in a channel wakes its agents as usual.
  """

  alias Canopy.{Schedules, Settings}

  @topic "hold"
  @schedule_reason_prefix "on hold: "

  @doc "The reason agent activity is held, or nil."
  def reason do
    case Settings.get() do
      %{hold_reason: reason} when is_binary(reason) and reason != "" -> reason
      _ -> nil
    end
  end

  def active?, do: not is_nil(reason())

  def since, do: Settings.get().hold_at

  @doc "Stops everything with a reason. Idempotent while already held."
  def engage(reason) when is_binary(reason) do
    if active?() do
      :ok
    else
      {:ok, _} = Settings.update(%{hold_reason: reason, hold_at: DateTime.utc_now()})
      Schedules.pause_all(@schedule_reason_prefix <> reason)
      broadcast(:engaged)
      :ok
    end
  end

  @doc "Lifts the hold and resumes the schedules it paused."
  def release do
    if active?() do
      {:ok, _} = Settings.update(%{hold_reason: nil, hold_at: nil})
      Schedules.resume_where_reason_starts(@schedule_reason_prefix)
      broadcast(:released)
    end

    :ok
  end

  @doc """
  Whether an engine error is a billing problem worth stopping for: an
  exhausted balance or quota, a payment-required response, (Claude Code)
  a low credit balance or a reached subscription usage or spend limit, or
  (Codex) a reached ChatGPT plan usage limit or API quota. Claude Code's
  per-turn budget cap and fast-mode limit are not holds, nor are Codex's
  rate limits, overload and sign-in errors.

  Takes the error's message, or the engine's error map
  (`%{"name" => n, "data" => %{"message" => m}}`), whose Codex error name
  decides when it is one Canopy knows.
  """
  def billing_error?(reason) when is_binary(reason) do
    opencode_billing?(reason) or claude_code_billing?(reason) or codex_billing?(reason)
  end

  # Only a Codex error name decides on an error map. Any other map (Claude
  # Code's, OpenCode's, an unknown Codex name) is false here, and its message
  # is checked as text by the caller's first-line check, as before.
  def billing_error?(%{} = error), do: codex_billing?(error) == true

  def billing_error?(_), do: false

  defp opencode_billing?(reason) do
    Regex.match?(
      ~r/insufficient[ _](balance|quota|credit|funds)|credit_balance_exhausted|no credits remaining|payment required|billing|out of credits|\b402\b/i,
      reason
    )
  end

  # wording from the claude CLI (2.1.x)
  defp claude_code_billing?(reason) do
    Regex.match?(
      ~r/credit balance (is )?too low|usage limit reached|hit your (limit|monthly spend limit)|reached your (weekly )?usage limit|out of extra usage/i,
      reason
    )
  end

  # Codex (0.163 `CodexErrorInfo`): the plan's usage limit or the API quota
  # is a hold; rate limits and overload are retried by Codex, and a signed-out
  # Codex is a turn error, so those are not. Other names are `:unknown`, and
  # the message decides through the caller's text check.
  @codex_holds ~w(usageLimitExceeded insufficient_quota)
  @codex_not_holds ~w(rateLimitExceeded serverOverloaded unauthorized)

  defp codex_billing?(%{"name" => name}) when name in @codex_holds, do: true
  defp codex_billing?(%{"name" => name}) when name in @codex_not_holds, do: false

  defp codex_billing?(%{"name" => name}) when is_binary(name) do
    if String.ends_with?(name, "ConnectionFailed"), do: false, else: :unknown
  end

  defp codex_billing?(%{}), do: :unknown

  defp codex_billing?(reason) when is_binary(reason),
    do: Regex.match?(~r/hit your usage limit|\busageLimitExceeded\b/i, reason)

  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp broadcast(what), do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:hold, what})
end
