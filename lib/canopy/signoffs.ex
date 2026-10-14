defmodule Canopy.Signoffs do
  @moduledoc """
  Sign-off cards: an agent asks the user to accept its work, or to pick one
  of several options, and the user answers with one press.

  A card is either freestanding (the `canopy_signoff_request` tool) or tied
  to a playbook step held for the user's approval. Answering a run-linked
  card goes through `Canopy.Playbooks.Runs.approve/3` or `request_changes/3`,
  which resolve the card in the run's own transaction, so the run and the
  card never disagree. A freestanding answer is posted to the channel as a
  message from the user mentioning the asker, which wakes it through the
  router like any message.

  A card never holds an engine call open, so there is no `ChannelServer`
  hop: nothing waits for the answer except the agent's next turn.
  """

  import Ecto.Query, warn: false

  alias Canopy.{Agents, Channels, Repo, Runtime, Timeline}
  alias Canopy.Documents.Document
  alias Canopy.Playbooks.{Run, Runs}
  alias Canopy.Runtime.Prompts
  alias Canopy.Signoffs.SignoffRequest
  alias Ecto.Multi

  @preloads [:agent, :step, run: [:steps]]
  @stale "the run changed meanwhile, try again"

  # -- Reading ------------------------------------------------------------------

  def get!(id), do: SignoffRequest |> Repo.get!(id) |> with_preloads()

  def get(id) when is_binary(id), do: SignoffRequest |> Repo.get(id) |> with_preloads()
  def get(_), do: nil

  @doc "The channel's pending cards, oldest first."
  def pending_for_channel(channel_id) do
    from(s in SignoffRequest,
      where: s.channel_id == ^channel_id and s.status == "pending",
      order_by: [asc: s.id]
    )
    |> Repo.all()
    |> with_preloads()
  end

  @doc "The run's pending card (the step held for approval), or nil."
  def pending_for_run(run_id) do
    from(s in SignoffRequest,
      where: s.run_id == ^run_id and s.status == "pending",
      order_by: [desc: s.id],
      limit: 1
    )
    |> Repo.one()
    |> with_preloads()
  end

  @doc "The step's pending card, read as it is now (no preloads); used inside `Runs`' transitions."
  def pending_for_step(playbook_step_id) do
    Repo.one(
      from s in SignoffRequest,
        where: s.playbook_step_id == ^playbook_step_id and s.status == "pending"
    )
  end

  @doc "Pending cards per open channel id, for the sidebar."
  def pending_counts do
    from(s in SignoffRequest,
      join: c in assoc(s, :channel),
      where: s.status == "pending" and c.status != "archived",
      group_by: s.channel_id,
      select: {s.channel_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "`\"feature-build · step 4 of 7\"` for a run-linked card, else nil."
  def badge(%SignoffRequest{run: %Run{steps: steps} = run, step: %{position: position}})
      when is_list(steps),
      do: "#{run.playbook_name} · step #{position} of #{length(steps)}"

  def badge(_signoff), do: nil

  defp with_preloads(nil), do: nil

  defp with_preloads(list) when is_list(list),
    do: list |> Repo.preload(@preloads) |> Enum.map(&put_documents/1)

  defp with_preloads(%SignoffRequest{} = signoff),
    do: signoff |> Repo.preload(@preloads, force: true) |> put_documents()

  # in `document_ids` order; deleted documents are dropped
  defp put_documents(%SignoffRequest{document_ids: []} = signoff), do: %{signoff | documents: []}

  defp put_documents(%SignoffRequest{document_ids: ids} = signoff) do
    by_id = from(d in Document, where: d.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
    %{signoff | documents: ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)}
  end

  # -- Asking -------------------------------------------------------------------

  @doc """
  A freestanding card (the MCP tool). Attrs: `:channel_id`, `:agent_id`,
  `:title`, `:question`, `:summary`, `:options`, `:document_ids`. Records
  and broadcasts `signoff_requested`.
  """
  def request(attrs) do
    Multi.new()
    |> multi_request(Map.new(attrs), nil)
    |> Repo.transaction()
    |> case do
      {:ok, %{signoff: signoff, signoff_event: event}} ->
        Timeline.broadcast(event)
        {:ok, get!(signoff.id)}

      {:error, _step, %Ecto.Changeset{} = changeset, _} ->
        {:error, Canopy.MCP.Tool.changeset_reason(changeset)}
    end
  end

  @doc """
  Adds a new card (`:signoff`) and its `signoff_requested` line
  (`:signoff_event`) to a multi. `run` is the run it belongs to, or nil.
  """
  def multi_request(%Multi{} = multi, attrs, run) do
    multi
    |> Multi.insert(:signoff, SignoffRequest.changeset(%SignoffRequest{}, attrs))
    |> Timeline.multi_record(:signoff_event, fn %{signoff: s} ->
      event(s, "signoff_requested", run, %{
        "question" => s.question,
        "options_count" => length(s.options)
      })
    end)
  end

  @doc """
  Adds the answer to a pending card (`:signoff`) and its `signoff_resolved`
  line (`:signoff_event`) to a multi. `attrs`: `:status`, `:choice`,
  `:choice_index`, `:note`.
  """
  def multi_resolve(%Multi{} = multi, %SignoffRequest{} = signoff, attrs, run) do
    multi
    |> Multi.update(:signoff, resolve_changeset(signoff, attrs))
    |> Timeline.multi_record(:signoff_event, fn %{signoff: s} -> resolved_event(s, run, %{}) end)
  end

  @doc "Withdraws every pending card of the run (it was cancelled), each with a `signoff_withdrawn` line."
  def multi_withdraw_for_run(%Multi{} = multi, %Run{} = run, reason \\ "run cancelled") do
    Multi.merge(multi, fn _changes ->
      from(s in SignoffRequest, where: s.run_id == ^run.id and s.status == "pending")
      |> Repo.all()
      |> Enum.reduce(Multi.new(), fn s, acc ->
        acc
        |> Multi.update(
          {:signoff_withdrawn, s.id},
          resolve_changeset(s, %{status: "withdrawn", resolved_by: "system"})
        )
        |> Timeline.multi_record({:signoff_withdrawn_event, s.id}, fn _ ->
          event(s, "signoff_withdrawn", run, %{
            "agent" => agent_name(s.agent_id),
            "reason" => reason
          })
        end)
      end)
    end)
  end

  defp resolve_changeset(signoff, attrs) do
    signoff
    |> Ecto.Changeset.change(
      Map.merge(%{resolved_by: "user", resolved_at: DateTime.utc_now()}, Map.new(attrs))
    )
    |> Ecto.Changeset.validate_inclusion(:status, SignoffRequest.statuses())
  end

  # -- Answering -----------------------------------------------------------------

  @doc """
  The user accepts a pending card: `option_index` (0-based) picks an option,
  and is required on a card with options and nil on a plain one. Returns
  `{:ok, card}` or `{:error, reason}` with a reason to show the user.
  """
  def accept(signoff_or_id, option_index, note) do
    with {:ok, signoff} <- fetch_pending(signoff_or_id),
         {:ok, note} <- check_note(note),
         {:ok, choice} <- choice(signoff, option_index) do
      if signoff.run_id,
        do: answer_run(signoff, :accept, choice, option_index, note),
        else: answer_freestanding(signoff, "accepted", choice, option_index, note)
    end
  end

  @doc "The user rejects a pending card (all its options, when it has some). The note is optional."
  def reject(signoff_or_id, note) do
    with {:ok, signoff} <- fetch_pending(signoff_or_id),
         {:ok, note} <- check_note(note) do
      if signoff.run_id,
        do: answer_run(signoff, :reject, nil, nil, note),
        else: answer_freestanding(signoff, "rejected", nil, nil, note)
    end
  end

  # A fast path for the flash only: the answer is made single by the run's
  # transaction (run-linked) or by the claim (freestanding).
  defp fetch_pending(%SignoffRequest{id: id}), do: fetch_pending(id)

  defp fetch_pending(id) when is_binary(id) do
    case get(id) do
      %SignoffRequest{status: "pending"} = signoff -> {:ok, signoff}
      %SignoffRequest{} -> {:error, "already answered"}
      nil -> {:error, "already answered"}
    end
  end

  defp check_note(note) do
    note = if is_binary(note), do: String.trim(note), else: nil

    cond do
      note in [nil, ""] -> {:ok, nil}
      String.length(note) > SignoffRequest.max_note() -> {:error, "the note is too long"}
      true -> {:ok, note}
    end
  end

  defp choice(%SignoffRequest{options: []}, nil), do: {:ok, nil}
  defp choice(%SignoffRequest{options: []}, _index), do: {:error, "this card has no options"}
  defp choice(%SignoffRequest{}, nil), do: {:error, "pick an option"}

  defp choice(%SignoffRequest{options: options}, index)
       when is_integer(index) and index >= 0 and index < length(options),
       do: {:ok, Enum.at(options, index)}

  defp choice(_signoff, _index), do: {:error, "pick an option"}

  defp answer_run(signoff, verdict, choice, index, note) do
    case Runs.get(signoff.run_id) do
      nil ->
        {:error, @stale}

      run ->
        result =
          case verdict do
            :accept ->
              Runs.approve(run, note, signoff: signoff, choice: choice, choice_index: index)

            :reject ->
              Runs.request_changes(run, note, signoff: signoff)
          end

        case result do
          {:ok, _run, _what} -> {:ok, get!(signoff.id)}
          {:error, "already answered"} -> {:error, "already answered"}
          {:error, _reason} -> {:error, @stale}
        end
    end
  end

  # Claim, post, finish. The claim is the lock: of two presses (two tabs),
  # exactly one moves the card off pending, so only one message is posted.
  # The claim comes before the post on purpose: if the process dies in
  # between, the card stays answered and the agent is never woken. That is
  # accepted for v1; posting first would wake the agent twice on a race.
  defp answer_freestanding(signoff, status, choice, index, note) do
    channel = Channels.get!(signoff.channel_id)
    archived? = Channels.archived?(channel)
    agent = signoff.agent_id && Agents.get(signoff.agent_id)

    cond do
      status == "accepted" and archived? ->
        {:error, "the channel is archived"}

      true ->
        attrs = %{
          status: status,
          choice: choice && choice["label"],
          choice_index: index,
          note: note
        }

        with :ok <- claim(signoff, attrs) do
          # nobody to tell: an archived channel's reject, or an asker that is gone
          if archived? or is_nil(agent),
            do: finish(signoff.id, nil),
            else: post_and_finish(signoff, agent, attrs)
        end
    end
  end

  defp claim(signoff, attrs) do
    now = DateTime.utc_now()

    set = [
      status: attrs.status,
      choice: attrs.choice,
      choice_index: attrs.choice_index,
      note: attrs.note,
      resolved_by: "user",
      resolved_at: now,
      updated_at: now
    ]

    Repo.transaction(
      fn ->
        case Repo.update_all(
               from(s in SignoffRequest, where: s.id == ^signoff.id and s.status == "pending"),
               set: set
             ) do
          {1, _} -> :ok
          _ -> Repo.rollback(:taken)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, :ok} -> :ok
      {:error, :taken} -> {:error, "already answered"}
    end
  end

  defp post_and_finish(signoff, agent, attrs) do
    body = Prompts.signoff_answer_message(agent.name, signoff, attrs)

    # only the asker wakes: the title, labels and note may name other agents
    case Runtime.post_user_message(signoff.channel_id, body, mentions: [agent.id]) do
      {:ok, %Canopy.Messages.Message{id: message_id}} ->
        finish(signoff.id, message_id)

      {:ok, _other} ->
        finish(signoff.id, nil)

      {:error, reason} ->
        unclaim(signoff, attrs.status)
        {:error, if(is_binary(reason), do: reason, else: "could not post the answer")}
    end
  end

  # the post failed: the card is pending again, and nothing was broadcast
  defp unclaim(signoff, status) do
    Repo.update_all(
      from(s in SignoffRequest,
        where: s.id == ^signoff.id and s.status == ^status and is_nil(s.message_id)
      ),
      set: [
        status: "pending",
        choice: nil,
        choice_index: nil,
        note: nil,
        resolved_by: nil,
        resolved_at: nil
      ]
    )
  end

  defp finish(id, message_id) do
    signoff = Repo.get!(SignoffRequest, id)
    extra = if message_id, do: %{"delivered" => "message", "message_id" => message_id}, else: %{}

    Multi.new()
    |> Multi.update(:signoff, Ecto.Changeset.change(signoff, message_id: message_id))
    |> Timeline.multi_record(:signoff_event, fn %{signoff: s} -> resolved_event(s, nil, extra) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{signoff: s, signoff_event: event}} ->
        Timeline.broadcast(event)
        {:ok, get!(s.id)}

      {:error, _step, changeset, _} ->
        {:error, Canopy.MCP.Tool.changeset_reason(changeset)}
    end
  end

  # -- Timeline -------------------------------------------------------------------

  defp resolved_event(%SignoffRequest{} = s, run, extra) do
    event(
      s,
      "signoff_resolved",
      run,
      Map.merge(
        %{
          "status" => s.status,
          "agent" => agent_name(s.agent_id),
          "choice" => s.choice,
          "choice_index" => s.choice_index,
          "options_count" => length(s.options),
          "note" => s.note,
          "by" => "user"
        },
        extra
      )
    )
  end

  defp event(%SignoffRequest{} = s, type, run, payload) do
    %{
      channel_id: s.channel_id,
      agent_id: s.agent_id,
      event_type: type,
      ref_id: s.id,
      payload:
        Map.merge(
          %{
            "title" => s.title,
            "playbook" => playbook_name(s, run),
            "run_id" => s.run_id,
            "step" => s.step_id
          },
          payload
        )
    }
  end

  defp playbook_name(_s, %Run{playbook_name: name}), do: name
  defp playbook_name(%SignoffRequest{run_id: nil}, _run), do: nil

  defp playbook_name(%SignoffRequest{run_id: run_id}, _run),
    do: Repo.one(from r in Run, where: r.id == ^run_id, select: r.playbook_name)

  defp agent_name(nil), do: nil

  defp agent_name(agent_id) do
    case Agents.get(agent_id) do
      nil -> nil
      agent -> agent.name
    end
  end
end
