defmodule Canopy.Runtime.Prompts do
  @moduledoc """
  Text Canopy sends to agents: the per-prompt system preamble and the small wake
  prompts that tell an agent something happened and which ids to look up. Wake
  prompts never include message bodies; agents fetch context through Canopy tools.
  """

  @preamble_path Application.app_dir(:canopy, "priv/prompts/collaboration.md")
  @external_resource @preamble_path
  @preamble File.read!(@preamble_path)

  @doc "System text appended after the OpenCode agent prompt: preamble plus the agent's role prompt."
  def system(agent, channel, repository) do
    vars = %{
      "display_name" => agent.display_name || agent.name,
      "name" => agent.name,
      "role" => agent.role || "",
      "channel" => channel.name,
      "repository_path" => repository.path
    }

    preamble =
      Enum.reduce(vars, @preamble, fn {k, v}, acc -> String.replace(acc, "{{#{k}}}", v) end)

    case agent.system_prompt do
      nil -> preamble
      "" -> preamble
      role_prompt -> preamble <> "\n\n" <> String.trim(role_prompt)
    end
  end

  def new_message(%{channel: channel, sender: sender, message_id: message_id, thread?: thread?}) do
    thread_hint =
      if thread?,
        do: " The message is part of a thread; answer with canopy_thread_reply on that thread.",
        else: ""

    """
    You have a new Canopy message in ##{channel} from #{sender}.
    Message ID: #{message_id}

    Read it and any context you need with canopy_messages_read (use around: "#{message_id}") or canopy_messages_search, do the work, then post your findings with canopy_message_send.#{thread_hint}
    """
  end

  def delegation(%{channel: channel, from: from, delegation_id: delegation_id, task: task}) do
    """
    #{from} delegated a subtask to you in ##{channel}.
    Delegation ID: #{delegation_id}
    Task: #{task}

    Use the Canopy tools for any context you need. When done, call canopy_task_update with status "completed" and a concise result so #{from} can continue.
    """
  end

  def delegation_completed(%{
        channel: channel,
        to: to,
        delegation_id: delegation_id,
        result: result,
        status: status
      }) do
    """
    Your delegated subtask #{delegation_id} in ##{channel} was #{status} by #{to}.
    Result: #{result || "(no result given)"}

    Continue your work.
    """
  end

  def handoff(%{channel: channel, from: from, handoff_id: handoff_id}) do
    """
    You have received a task handoff from #{from} in ##{channel}.
    Handoff ID: #{handoff_id}

    Call canopy_handoff_get to read the handoff packet, inspect the repository (git status, git diff), then call canopy_handoff_accept or canopy_handoff_reject. If you accept, you own the task; continue the work and post updates with canopy_message_send.
    """
  end

  def handoff_accepted(%{channel: channel, to: to, handoff_id: handoff_id}) do
    "#{to} accepted your handoff #{handoff_id} in ##{channel}. You no longer own the task; no action is needed unless you are asked."
  end

  def handoff_rejected(%{channel: channel, to: to, handoff_id: handoff_id, reason: reason}) do
    """
    #{to} rejected your handoff #{handoff_id} in ##{channel}.
    Reason: #{reason || "(none given)"}

    You still own the task. Decide how to proceed and post an update with canopy_message_send.
    """
  end
end
