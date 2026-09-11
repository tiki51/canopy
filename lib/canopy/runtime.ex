defmodule Canopy.Runtime do
  @moduledoc """
  Facade over the per-channel runtime. LiveViews call this; MCP tools do not.
  """

  alias Canopy.{Agents, AgentSessions, Channels, Delegations, Handoffs, Messages, Tasks, Users}
  alias Canopy.Runtime.{ChannelServer, Commands, Supervisor}

  @doc "Makes sure the channel's process is running and returns its pid."
  defdelegate ensure_channel(channel_id, opts \\ []), to: Supervisor
  defdelegate stop_channel(channel_id), to: Supervisor

  @doc """
  Posts a message from the local user; the channel process wakes the right agents.

  Slash commands are handled here so every composer gets them:

    * `/handoff @agent reason` → `{:ok, {:handoff, %Handoff{}}}`
    * `/delegate @agent task`  → `{:ok, {:delegation, %Delegation{}}}`

  Plain text returns `{:ok, %Message{}}`. A malformed or impossible command returns
  `{:error, reason}` with a one-line reason; nothing is written in that case.
  """
  def post_user_message(channel_id, body, opts \\ []) do
    if Channels.archived?(Channels.get!(channel_id)) do
      {:error, "this channel is archived; reopen it to post"}
    else
      do_post_user_message(channel_id, body, opts)
    end
  end

  defp do_post_user_message(channel_id, body, opts) do
    {:ok, _pid} = ensure_channel(channel_id)

    case Commands.parse(body) do
      :text -> Messages.post_user_message(channel_id, Users.local().id, body, opts)
      {:command, :handoff, target, reason} -> user_handoff(channel_id, target, reason)
      {:command, :delegate, target, task} -> user_delegation(channel_id, target, task)
      {:error, reason} -> {:error, reason}
    end
  end

  # The user hands the task to an agent. The current owner (if any) is recorded as
  # the previous owner; the target must accept, exactly like an agent-initiated handoff.
  defp user_handoff(channel_id, target_name, reason) do
    channel = Channels.get!(channel_id)

    with {:ok, target} <- member_named(channel, target_name),
         :ok <- not_current_owner(channel, target),
         {:ok, _} <-
           Messages.post_user_note(
             channel_id,
             Users.local().id,
             "Handing this task to @#{target.name}: #{reason}"
           ) do
      task = Tasks.for_channel(channel.id)
      target_session = AgentSessions.get_root(channel.id, target.id)

      attrs = %{
        channel_id: channel.id,
        task_id: task && task.id,
        from_agent_id: channel.owner_agent_id,
        to_agent_id: target.id,
        target_session_id: target_session && target_session.id,
        summary: reason,
        reason: reason,
        packet: Canopy.MCP.Tools.HandoffTask.build_packet(channel, task)
      }

      case Handoffs.request(attrs) do
        {:ok, handoff} -> {:ok, {:handoff, handoff}}
        {:error, changeset} -> {:error, "could not hand off: " <> changeset_reason(changeset)}
      end
    end
  end

  # The user asks an agent for a bounded subtask. The current owner stays
  # responsible and is notified when it completes; with no owner, only the timeline is.
  defp user_delegation(channel_id, target_name, description) do
    channel = Channels.get!(channel_id)

    with {:ok, target} <- member_named(channel, target_name),
         {:ok, _} <-
           Messages.post_user_note(
             channel_id,
             Users.local().id,
             "Delegated to @#{target.name}: #{description}"
           ) do
      task = Tasks.for_channel(channel.id)

      attrs = %{
        channel_id: channel.id,
        task_id: task && task.id,
        from_agent_id: channel.owner_agent_id,
        to_agent_id: target.id,
        description: description
      }

      case Delegations.create(attrs) do
        {:ok, delegation} -> {:ok, {:delegation, delegation}}
        {:error, changeset} -> {:error, "could not delegate: " <> changeset_reason(changeset)}
      end
    end
  end

  defp member_named(channel, name) do
    case Agents.get_by_name(name) do
      nil ->
        {:error, "no agent named @#{name}"}

      agent ->
        if Channels.member?(channel, agent),
          do: {:ok, agent},
          else: {:error, "@#{agent.name} is not a member of ##{channel.name}"}
    end
  end

  defp not_current_owner(%{owner_agent_id: id}, %{id: id, name: name}),
    do: {:error, "@#{name} already owns this task"}

  defp not_current_owner(_channel, _target), do: :ok

  defp changeset_reason(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  def respond_permission(channel_id, permission_request_id, reply) do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.respond_permission(pid, permission_request_id, reply)
  end

  @doc "Moves a DM to another repository; agents continue there on their next turn."
  def switch_dm_repository(channel_id, repository_id, by \\ "user") do
    Channels.switch_repository(Channels.get!(channel_id), repository_id, by)
  end

  @doc """
  Forgets an agent's session in a channel; its next wake starts a fresh
  OpenCode session. `{:error, :busy}` while a turn is in flight.
  """
  def reset_session(channel_id, agent_id, by \\ "user") do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.reset_session(pid, agent_id, by)
  end

  def abort(channel_id, agent_id) do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.abort(pid, agent_id)
  end

  def telemetry(channel_id, agent_id) do
    case Supervisor.whereis(channel_id) do
      nil -> []
      pid -> ChannelServer.telemetry(pid, agent_id)
    end
  end

  @doc """
  The agent in `opencode_session_id` declines to respond this turn: its final
  text is not posted as a reply. `{:error, :no_turn}` when nothing is in flight.
  """
  def pass(channel_id, opencode_session_id, reason \\ nil) do
    case Supervisor.whereis(channel_id) do
      nil -> {:error, :no_turn}
      pid -> ChannelServer.pass(pid, opencode_session_id, reason)
    end
  end

  @doc """
  Wakes an agent because one of its schedules fired. Like a user action, this
  resets the channel's chatter budget: the user asked for it.
  """
  def wake_scheduled(channel_id, agent_id, text) do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.wake(pid, agent_id, text)
  end

  @doc "True when the channel has hit its chatter budget and is holding wakeups."
  def paused?(channel_id) do
    case Supervisor.whereis(channel_id) do
      nil -> false
      pid -> ChannelServer.paused?(pid)
    end
  end

  @doc "Lets a paused channel run its held wakeups against a fresh budget."
  def continue(channel_id) do
    {:ok, pid} = ensure_channel(channel_id)
    ChannelServer.continue(pid)
  end

  def status(channel_id) do
    case Supervisor.whereis(channel_id) do
      nil -> %{}
      pid -> ChannelServer.status(pid)
    end
  end
end
