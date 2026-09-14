defmodule Canopy.Runtime.Prompts do
  @moduledoc """
  Text Canopy sends to agents: the per-prompt system preamble and the small wake
  prompts that tell an agent something happened and which ids to look up. Wake
  prompts never include message bodies; agents fetch context through Canopy tools.
  """

  @preamble_path Application.app_dir(:canopy, "priv/prompts/collaboration.md")
  @external_resource @preamble_path
  @default_preamble File.read!(@preamble_path)

  @doc """
  The collaboration preamble Canopy ships. Settings may override it; this is
  what the Settings page offers as the starting point and the reset.
  """
  def default_preamble, do: @default_preamble

  @doc "The variables a preamble may use, for the Settings page to list."
  def preamble_variables,
    do: ~w(display_name name role channel repository_path notes_path shared_notes_path
           execution_mode other_repositories memory)

  # The user's text when Settings carries one, otherwise what Canopy ships.
  defp preamble do
    case Canopy.Settings.get().collaboration_prompt do
      text when is_binary(text) and text != "" -> text
      _ -> @default_preamble
    end
  end

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
      "execution_mode" => execution_mode(agent),
      "channel" => channel.name,
      "repository_path" => repository.path,
      "notes_path" => Canopy.Notes.agent_path(repository.path, agent),
      "shared_notes_path" => Canopy.Notes.shared_path(repository.path)
    }

    preamble =
      Enum.reduce(vars, preamble(), fn {k, v}, acc -> String.replace(acc, "{{#{k}}}", v) end)

    case agent.system_prompt do
      nil -> preamble
      "" -> preamble
      role_prompt -> preamble <> "\n\n" <> String.trim(role_prompt)
    end
  end

  # An agent is never told what its own OpenCode agent can do, so when a
  # read-only teammate reports "blocked by plan mode" a writer has no reason to
  # read that as someone else's limit — it takes it as a fact about the channel
  # and stops working. Each agent is told its own reach, in the first person.
  @contagion "A teammate's limits are their own. If someone reports that work is blocked by plan mode or that they cannot execute, that describes their session, not yours."

  defp execution_mode(agent) do
    case Map.get(agent, :opencode_agent) do
      "plan" ->
        "Your session is read-only: you can read, inspect, and plan, but you cannot edit files. That is a limit of your own session, not of this channel or this team. Say it in the first person (\"I can't make that edit from here\") and hand the work to a teammate who can; never tell the channel that execution is blocked, because for them it is not."

      "build" ->
        "Your session can edit files in this repository: you have write access and are expected to do the work yourself. " <>
          @contagion

      _ ->
        @contagion
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

  # One line per attached document, saying how the agent gets at it. `plan` is
  # `Canopy.Documents.prompt_plan/1` output; the parts themselves are added to
  # the OpenCode prompt by the channel server.
  defp attachments_block([]), do: ""

  defp attachments_block(plan) when is_list(plan) do
    lines =
      Enum.map_join(plan, "\n", fn {document, mode} -> "- " <> attachment_line(document, mode) end)

    "Attachments on this message:\n" <>
      lines <>
      "\nEvery attachment is also a file under .canopy/files/ in the repository, readable with your own tools; canopy_document_get returns one by id (images included) and canopy_documents_list finds files shared anywhere in Canopy.\n"
  end

  @doc """
  Appended to a wake when the same agent posted several messages in one turn:
  the earlier ones, with their attachments and how each arrives. `plan` is the
  merged `Canopy.Documents.prompt_plan/1` for every document in the turn.
  """
  def earlier_posts([], _plan), do: ""

  def earlier_posts(messages, plan) do
    modes = Map.new(plan, fn {document, mode} -> {document.id, mode} end)

    lines =
      Enum.map_join(messages, "\n", fn message ->
        docs =
          message
          |> Map.get(:documents)
          |> List.wrap()
          |> Enum.reject(&(&1 == %Ecto.Association.NotLoaded{}))

        doc_lines =
          Enum.map_join(docs, "", fn document ->
            "\n  - " <> attachment_line(document, Map.get(modes, document.id, :path))
          end)

        "- [#{message.id}]: #{Canopy.MCP.Format.truncate(Canopy.MCP.Format.single_line(message.body), 200)}" <>
          doc_lines
      end)

    "\nEarlier in the same turn the sender also posted:\n" <>
      lines <> "\ncanopy_messages_read returns all of them in full.\n"
  end

  defp attachment_line(document, mode) do
    ref = Canopy.MCP.Format.document_ref(document)
    path = Canopy.Documents.materialized_relative_path(document)

    case {mode, document.kind} do
      {:part, "image"} -> "#{ref} — attached to this prompt as an image; also at #{path}"
      {:part, _} -> "#{ref} — attached to this prompt as text; also at #{path}"
      {:path, "image"} -> "#{ref} — too large to attach; at #{path}"
      {:path, "text"} -> "#{ref} — not attached; read it at #{path} or with canopy_document_get"
      {:path, _} -> "#{ref} — at #{path}"
    end
  end

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
    #{inline_body(args)}#{attachments_block(Map.get(args, :attachments, []))}
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
