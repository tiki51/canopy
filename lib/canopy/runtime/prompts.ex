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
  def system(agent, channel, repository, others \\ []) do
    vars = %{
      "other_repositories" => other_repositories(others, repository),
      "memory" => Canopy.Memory.for_prompt(Map.get(agent, :id)),
      # the clock lives in wake prompts (below), so the system text stays
      # byte-identical between prompts and caches as a stable prefix
      "display_name" => agent.display_name || agent.name,
      "name" => agent.name,
      "role" => agent.role || "",
      "channel" => channel.name,
      "repository_path" => repository.path,
      "notes_path" => Canopy.Notes.agent_path(repository.path, agent),
      "shared_notes_path" => Canopy.Notes.shared_path(repository.path)
    }

    preamble =
      Enum.reduce(vars, @preamble, fn {k, v}, acc -> String.replace(acc, "{{#{k}}}", v) end)

    case agent.system_prompt do
      nil -> preamble
      "" -> preamble
      role_prompt -> preamble <> "\n\n" <> String.trim(role_prompt)
    end
  end

  defp other_repositories(others, %{id: current_id}) do
    case Enum.reject(others, &(&1.id == current_id)) do
      [] ->
        "This is the only repository registered in Canopy."

      list ->
        names = Enum.map_join(list, "; ", &"#{&1.name} (#{&1.path})")

        "Other repositories registered in Canopy: #{names}. Your session is bound to this repository. In a DM, move to another one with canopy_dm_switch_repository; otherwise start a channel or DM there with canopy_channel_create or canopy_dm_start and repository: \"<name>\"."
    end
  end

  defp other_repositories(_others, _repository), do: ""

  # Local wall-clock time, so agents can date their notes and read timestamps.
  defp now do
    NaiveDateTime.local_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
  end

  @doc "The line every wake prompt ends with: the current local time."
  def time_line, do: "The time now is #{now()}."

  @inline_body_chars 1_200

  # A short message rides along in the wake prompt, so a simple turn needs no
  # read (each tool call is another full-context model request).
  defp inline_body(%{body: body}) when is_binary(body) and body != "" do
    if String.length(body) <= @inline_body_chars,
      do: "Message text:\n#{body}\n",
      else: "The message is long (#{String.length(body)} chars): read it with canopy_message_get."
  end

  defp inline_body(_args), do: "Read it with canopy_message_get."

  def new_message(
        %{channel: channel, sender: sender, message_id: message_id, thread?: thread?} = args
      ) do
    thread_hint =
      if thread?,
        do: " The message is part of a thread; answer with canopy_thread_reply on that thread.",
        else: ""

    members_line =
      case Map.get(args, :members, []) do
        [] -> ""
        names -> "Members of ##{channel}: " <> Enum.map_join(names, ", ", &("@" <> &1)) <> "\n"
      end

    """
    You have a new Canopy message in ##{channel} from #{sender}.
    Message ID: #{message_id}
    #{members_line}
    #{inline_body(args)}
    canopy_messages_read returns what is new since you last read this channel; canopy_message_get returns one message in full; canopy_messages_search finds older ones. Do the work, then post your findings with canopy_message_send.#{thread_hint}
    Your post wakes only the agents you @mention, plus the channel owner. If you need an answer from someone, mention them.
    If this message needs nothing from you (an acknowledgement, a confirmation, a closing note, something already handled), call canopy_pass and stop. Never post an acknowledgement.
    #{time_line()}
    """
  end

  def delegation(%{channel: channel, from: from, delegation_id: delegation_id, task: task}) do
    """
    #{from} delegated a subtask to you in ##{channel}.
    Delegation ID: #{delegation_id}
    Task: #{task}

    Use the Canopy tools for any context you need. When done, call canopy_task_update with status "completed" and a concise result so #{from} can continue.
    #{time_line()}
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
    #{time_line()}
    """
  end

  def scheduled(%{channel: channel, schedule_id: id, instruction: instruction, kind: kind}) do
    stop =
      if kind == "recurring",
        do: " This repeats; if it should stop, call canopy_schedule_cancel with the id.",
        else: ""

    """
    A scheduled task of yours is due in ##{channel}.
    Schedule ID: #{id}
    Instruction (written by you or the channel owner when it was scheduled):
    #{instruction}

    Do it now. Post the result with canopy_message_send only if there is something worth saying; otherwise call canopy_pass.#{stop}
    If this task is waiting on the user (a decision, an answer, an account), do not keep checking: ask once if you have not, cancel this schedule with canopy_schedule_cancel, and stop. The user's reply wakes you.
    #{time_line()}
    """
  end

  def handoff(%{channel: channel, from: from, handoff_id: handoff_id}) do
    """
    You have received a task handoff from #{from} in ##{channel}.
    Handoff ID: #{handoff_id}

    Call canopy_handoff_get to read the handoff packet, inspect the repository (git status, git diff), then call canopy_handoff_accept or canopy_handoff_reject. If you accept, you own the task; continue the work and post updates with canopy_message_send.
    #{time_line()}
    """
  end

  def handoff_accepted(%{channel: channel, to: to, handoff_id: handoff_id}) do
    "#{to} accepted your handoff #{handoff_id} in ##{channel}. You no longer own the task; no action is needed unless you are asked. #{time_line()}"
  end

  def handoff_rejected(%{channel: channel, to: to, handoff_id: handoff_id, reason: reason}) do
    """
    #{to} rejected your handoff #{handoff_id} in ##{channel}.
    Reason: #{reason || "(none given)"}

    You still own the task. Decide how to proceed and post an update with canopy_message_send.
    """
  end
end
