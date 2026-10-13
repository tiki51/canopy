defmodule Canopy.EnvironmentHelpers do
  @moduledoc """
  Helpers for tests around `Canopy.Environment`'s reset.

  Every test that starts a reset (directly or through a LiveView) calls
  `await_reset/0` before it ends, so the worker never outlives the test's
  sandbox owner and the next test doesn't get `{:error, :already_running}`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Canopy.Environment.Resetter

  @doc "Returns once no reset is running and its worker has exited. Needs no subscription."
  def await_reset(timeout \\ 5_000), do: Resetter.await_idle(timeout)

  @doc "Raises the reset gate without starting a reset; lowered again on exit."
  def raise_gate do
    on_exit(&Resetter.reopen/0)
    Canopy.Environment.raise_gate()
  end

  @doc """
  Injects a failure into the next resets (`fail_at:` a step, `:sweeping`, or
  a list), as the UI can't pass `reset/1` opts. Restored on exit.
  """
  def fail_reset_at(fail_at) do
    previous = Application.get_env(:canopy, :environment_reset_opts)
    on_exit(fn -> restore(:environment_reset_opts, previous) end)
    Application.put_env(:canopy, :environment_reset_opts, fail_at: fail_at)
  end

  @doc "Clears the injected failure (\"Try again\" with the seam cleared)."
  def clear_reset_failure, do: Application.delete_env(:canopy, :environment_reset_opts)

  defp restore(key, nil), do: Application.delete_env(:canopy, key)
  defp restore(key, value), do: Application.put_env(:canopy, key, value)
end
