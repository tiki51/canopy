defmodule Canopy.Hold do
  @moduledoc """
  A global stop on agent activity. Engaged automatically when OpenCode reports
  a billing problem (no balance, quota exhausted): every schedule pauses, every
  wake is dropped with a note in its channel, and a banner shows the reason on
  every page until you release it. Releasing resumes the schedules the hold
  paused; your next message in a channel wakes its agents as usual.
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
  Whether an OpenCode error is a billing problem worth stopping for: an
  exhausted balance or quota, or a payment-required response.
  """
  def billing_error?(reason) when is_binary(reason) do
    Regex.match?(
      ~r/insufficient[ _](balance|quota|credit|funds)|credit_balance_exhausted|no credits remaining|payment required|billing|out of credits|\b402\b/i,
      reason
    )
  end

  def billing_error?(_), do: false

  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp broadcast(what), do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:hold, what})
end
