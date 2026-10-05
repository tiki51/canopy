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
  exhausted balance or quota, a payment-required response, or (Claude Code)
  a low credit balance or a reached subscription usage or spend limit.
  Claude Code's per-turn budget cap and fast-mode limit are not holds.
  """
  def billing_error?(reason) when is_binary(reason) do
    opencode_billing?(reason) or claude_code_billing?(reason)
  end

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

  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp broadcast(what), do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:hold, what})
end
