defmodule Canopy.RuntimeHelpers do
  @moduledoc """
  Helpers for tests that drive `Canopy.Runtime.ChannelServer`s.
  """

  @doc """
  Returns once every running channel server has handled what is already in its
  mailbox. Two passes over all of them: handling a message can send another (a
  quiet check re-enqueues itself with `send_after(0)`, one server can post into
  another's channel), and the second pass catches those.

  Use it before a short `refute_receive` instead of a long fixed wait: anything
  the servers were going to send has been sent by then.
  """
  def settle do
    pids =
      for id <- Canopy.Runtime.Supervisor.running_channel_ids(),
          [{pid, _}] <- [Registry.lookup(Canopy.Runtime.ChannelRegistry, id)],
          do: pid

    for _ <- 1..2, pid <- pids, do: drain(pid)
    :ok
  end

  # a server that stopped meanwhile has nothing left to send
  defp drain(pid) do
    :sys.get_state(pid)
  catch
    :exit, _ -> :ok
  end
end
