defmodule Canopy.Locks do
  @moduledoc """
  Named locks on a repository's shared resources (the test database, e2e
  ports, a screenshot run), kept by Canopy rather than agreed in chat.

  A lock is keyed by `(repository_id, name)` and is the set of its claims
  (`Canopy.Locks.Claim`): at most one holder, then waiters in the order they
  asked. It appears with the first acquire and disappears with its last claim.
  The holder is a session, so two sessions can never both believe they hold
  it. A partial unique index allows one holder, which makes granting atomic
  without a process: SQLite serialises writes and rejects a second holder.

  A held claim belongs to the turn that holds it (`turn_ref`) and is released
  when that turn ends (`release_turn/2`), unless it was taken with
  `hold_across_turns`. A waiter promoted when the lock frees has no turn yet:
  `{:lock_granted, claim}` goes out on `"locks:<repository_id>"`, the channel
  server of the claim's channel wakes that session, and the turn the wake
  starts takes ownership (`stamp_turn/3`). `expire/2` is the backstop for a
  grant nobody used and a hold kept too long.

  Every change records `lock_granted`, `lock_queued` or `lock_released` on the
  claim's channel (those never wake an agent) and sends `{:locks_changed,
  repository_id}` on the repository's topic, after the transaction commits.
  """

  import Ecto.Query, warn: false

  alias Canopy.AgentSessions.AgentSession
  alias Canopy.Locks.Claim
  alias Canopy.PermissionRequests.PermissionRequest
  alias Canopy.QuestionRequests.QuestionRequest
  alias Canopy.{Repo, Settings, Timeline}
  alias Ecto.Multi

  @pubsub Canopy.PubSub
  @preloads [:agent, :user, :channel, :session]
  @name_format ~r/^[a-z0-9][a-z0-9._:\/-]{0,63}$/

  # A waiter granted the lock whose wake never started a turn (held by the
  # chatter budget, dropped by a hold or the spend limit) gives it up after this.
  @grant_grace_ms :timer.minutes(3)

  @doc "The suggested lock name for the test suite and anything that runs it."
  def default_name, do: "tests"

  @doc "How long a granted lock may go unused before it passes on, in milliseconds."
  def grant_grace_ms, do: @grant_grace_ms

  @doc "PubSub topic for a repository's locks."
  def topic(repository_id) when is_binary(repository_id), do: "locks:#{repository_id}"

  @doc """
  Subscribes the caller to `{:locks_changed, repository_id}` (any change) and
  `{:lock_granted, %Claim{}}` (a waiter promoted to holder).
  """
  def subscribe(repository_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(repository_id))

  def unsubscribe(repository_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(repository_id))

  @doc """
  A lock name as stored: trimmed and lower-cased; letters, digits and
  `. _ : / -`, up to 64 characters (`"tests"`, `"e2e"`, `"ports:4100"`).
  """
  def normalize_name(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()

    if Regex.match?(@name_format, name),
      do: {:ok, name},
      else:
        {:error,
         "a lock name is letters, digits and . _ : / - (up to 64), for example \"tests\" or \"ports:4100\""}
  end

  def normalize_name(_name), do: {:error, "missing lock name"}

  # -- Acquiring --------------------------------------------------------------

  @doc """
  The session asks for the lock. In one transaction: a held claim when nobody
  holds it, otherwise a place at the back of the line.

  Options: `:hold_across_turns` (not released at turn end), `:turn_ref` (the
  turn in flight, which then owns the claim).

  Returns `{:granted, claim}`, `{:queued, claim, position, holder}` (position
  1 is next), `{:already_held, claim}`, or `{:error, reason}`. Asking again
  while waiting changes nothing and reports the place in line.
  """
  def acquire(%AgentSession{} = session, repository_id, name, reason, opts \\ []) do
    with {:ok, name} <- normalize_name(name) do
      attrs = %{
        repository_id: repository_id,
        name: name,
        session_id: session.id,
        agent_id: session.agent_id,
        channel_id: session.channel_id,
        reason: blank_to_nil(reason),
        hold_across_turns: Keyword.get(opts, :hold_across_turns, false) == true,
        turn_ref: Keyword.get(opts, :turn_ref)
      }

      own = from c in Claim, where: c.session_id == ^session.id

      # a lost race for the holder's place (another session's insert won)
      # rolls back; asking again queues behind the winner
      case commit(fn repo -> do_acquire(repo, own, attrs) end) do
        {:error, %Ecto.Changeset{} = changeset} ->
          if holder_taken?(changeset),
            do: commit(fn repo -> do_acquire(repo, own, attrs) end),
            else: {:error, changeset}

        result ->
          result
      end
    end
  end

  @doc """
  The user takes a free lock by hand ("don't touch the tree, I'm testing").
  It has no turn, so only Release or Force release frees it. Returns
  `{:granted, claim}`, `{:already_held, claim}`, `{:error, {:held, holder}}`
  when someone else has it, or `{:error, reason}`.
  """
  def acquire_for_user(user, channel, name, reason) do
    with {:ok, name} <- normalize_name(name) do
      attrs = %{
        repository_id: channel.repository_id,
        name: name,
        user_id: user.id,
        channel_id: channel.id,
        reason: blank_to_nil(reason)
      }

      commit(fn repo ->
        case holder(repo, attrs.repository_id, name) do
          nil ->
            grant_new(repo, attrs)

          %Claim{user_id: id} = claim when id == user.id ->
            {{:already_held, claim}, [], []}

          claim ->
            {{:error, {:held, claim}}, [], []}
        end
      end)
    end
  end

  defp do_acquire(repo, own, %{repository_id: repository_id, name: name} = attrs) do
    mine = repo.one(from c in own, where: c.repository_id == ^repository_id and c.name == ^name)

    case {mine, holder(repo, repository_id, name)} do
      {%Claim{status: "held"} = claim, _} ->
        {{:already_held, adopt(repo, claim, attrs)}, [], []}

      {%Claim{status: "waiting"} = claim, holder} ->
        {{:queued, claim, position(repo, claim), holder}, [], []}

      {nil, nil} ->
        grant_new(repo, attrs)

      {nil, holder} ->
        claim = repo.insert!(Claim.changeset(%Claim{}, Map.put(attrs, :status, "waiting")))
        position = position(repo, claim)

        event =
          event(claim, "lock_queued", %{
            "position" => position,
            "holder_agent_id" => holder.agent_id,
            "holder_user" => is_binary(holder.user_id)
          })

        {{:queued, claim, position, holder}, [event], []}
    end
  end

  defp grant_new(repo, attrs) do
    changeset =
      Claim.changeset(
        %Claim{},
        Map.merge(attrs, %{status: "held", granted_at: DateTime.utc_now()})
      )

    case repo.insert(changeset) do
      {:ok, claim} ->
        {{:granted, claim}, [event(claim, "lock_granted", %{"promoted" => false})], []}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Asking again for a lock already held: a claim granted from the line and
  # not yet owned by a turn is taken over by the turn asking now, and a hold
  # across turns once asked for is kept.
  defp adopt(repo, claim, attrs) do
    changes =
      [
        (is_nil(claim.turn_ref) and is_binary(attrs.turn_ref)) && {:turn_ref, attrs.turn_ref},
        (attrs.hold_across_turns and not claim.hold_across_turns) && {:hold_across_turns, true}
      ]
      |> Enum.filter(& &1)
      |> Map.new()

    if changes == %{}, do: claim, else: repo.update!(Claim.changeset(claim, changes))
  end

  defp holder_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      opts[:constraint] == :unique and
        opts[:constraint_name] == "lock_claims_repository_id_name_index"
    end)
  end

  # -- Releasing --------------------------------------------------------------

  @doc """
  The session lets go of the lock: a held claim is released and the next in
  line promoted, a waiting one leaves the line. `note` goes on the
  `lock_released` event. Returns `{:ok, :released, promoted | nil}`,
  `{:ok, :left_queue, nil}`, or `{:error, :not_found}`.
  """
  def release(%AgentSession{id: session_id}, repository_id, name, note \\ nil) do
    with {:ok, name} <- normalize_name(name) do
      commit(fn repo ->
        query =
          from c in Claim,
            where:
              c.session_id == ^session_id and c.repository_id == ^repository_id and
                c.name == ^name

        case repo.one(query) do
          nil ->
            {{:error, :not_found}, [], []}

          %Claim{status: "held"} = claim ->
            {events, promoted} = remove(repo, claim, "agent", note)
            {{:ok, :released, List.first(promoted)}, events, promoted}

          claim ->
            {events, []} = remove(repo, claim, "agent", note)
            {{:ok, :left_queue, nil}, events, []}
        end
      end)
    end
  end

  @doc """
  Releases what the turn `turn_ref` of the session holds, except claims held
  across turns. Called by the channel server whenever a turn ends: done,
  errored, stopped, or ended by the watchdog. Returns the promoted claims.
  """
  def release_turn(_session_id, nil), do: []

  def release_turn(session_id, turn_ref) when is_binary(session_id) do
    query =
      from c in Claim,
        where:
          c.session_id == ^session_id and c.status == "held" and c.turn_ref == ^turn_ref and
            c.hold_across_turns == false

    release_all(query, "turn_end", nil)
  end

  @doc """
  Drops every claim of the session, held or waiting: on a session reset or
  delete, Stop all, and when its agent leaves the channel or is deactivated.
  `by` is the `released_by` of the events (`"reset"`, `"user"`).
  """
  def release_session(session_id, by \\ "reset", note \\ nil) when is_binary(session_id),
    do: release_all(from(c in Claim, where: c.session_id == ^session_id), by, note)

  @doc "Drops the claims of an agent's sessions in one channel (it was removed from it)."
  def release_agent_in_channel(channel_id, agent_id, note \\ nil) do
    query =
      from c in Claim,
        where:
          c.channel_id == ^channel_id and c.agent_id == ^agent_id and not is_nil(c.session_id)

    release_all(query, "reset", note)
  end

  @doc "Drops every claim of an agent's sessions (it was deactivated)."
  def release_agent(agent_id, note \\ nil) do
    query = from c in Claim, where: c.agent_id == ^agent_id and not is_nil(c.session_id)
    release_all(query, "reset", note)
  end

  @doc """
  The user's Force release (or Release, for a lock they hold themselves):
  the holder is dropped, whoever it is, and the next in line promoted.
  Returns `{:ok, promoted | nil}` or `{:error, :not_found}`.
  """
  def force_release(repository_id, name, user) do
    with {:ok, name} <- normalize_name(name) do
      commit(fn repo ->
        case holder(repo, repository_id, name) do
          nil ->
            {{:error, :not_found}, [], []}

          claim ->
            note =
              if claim.user_id == user.id,
                do: nil,
                else: "force-released by #{user.display_name}"

            {events, promoted} = remove(repo, claim, "user", note)
            {{:ok, List.first(promoted)}, events, promoted}
        end
      end)
    end
  end

  @doc """
  The backstop, run by each channel server's watchdog for its own channel
  (`channel_id:`), with the sessions that are working or have a wake on its
  way (`active_session_ids:`):

    * a held claim of an idle session, granted more than #{div(@grant_grace_ms, 60_000)}
      minutes ago, passes on: its grant wake never started (the chatter budget,
      a hold or the spend limit stopped it), or its turn vanished;
    * a claim held across turns longer than the `lock_hold_minutes` setting
      is released;
    * a line on the repository with waiters and no holder (its holder's row
      went with a deleted channel or agent) promotes its first waiter.

  Returns the promoted claims.
  """
  def expire(now \\ DateTime.utc_now(), opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    active = Keyword.get(opts, :active_session_ids, [])
    unused_since = DateTime.add(now, -@grant_grace_ms, :millisecond)
    held_since = DateTime.add(now, -Settings.lock_hold_ms(), :millisecond)

    unused =
      from c in Claim,
        where:
          c.channel_id == ^channel_id and c.status == "held" and not is_nil(c.session_id) and
            c.hold_across_turns == false and c.session_id not in ^active and
            c.granted_at < ^unused_since

    held_long =
      from c in Claim,
        where:
          c.channel_id == ^channel_id and c.status == "held" and not is_nil(c.session_id) and
            c.hold_across_turns == true and c.granted_at < ^held_since

    minutes = div(Settings.lock_hold_ms(), 60_000)

    release_all(unused, "lease", "not used within #{div(@grant_grace_ms, 60_000)} minutes") ++
      release_all(held_long, "lease", "held across turns for over #{minutes} minutes") ++
      promote_orphans(channel_id)
  end

  @doc """
  At boot no turn survives, so no turn can own a claim: every held claim not
  held across turns is released, and its waiters promoted. Returns the
  channel ids that still have claims, so their channel servers can be
  started to wake the new holders.
  """
  def release_on_boot do
    query = from c in Claim, where: c.status == "held" and c.hold_across_turns == false
    release_all(query, "restart", "Canopy restarted")
    Repo.all(from c in Claim, distinct: true, select: c.channel_id)
  end

  defp release_all(query, by, note) do
    claims = Repo.all(from c in query, order_by: [asc: c.inserted_at, asc: c.id])

    Enum.flat_map(claims, fn claim ->
      result =
        commit(fn repo ->
          {events, promoted} = remove(repo, claim, by, note)
          {{:ok, promoted}, events, promoted}
        end)

      case result do
        {:ok, promoted} -> promoted
        _ -> []
      end
    end)
  end

  # Deletes the claim (unless it is already gone) and, when it was the
  # holder, promotes the oldest waiter in the same transaction. The claim is
  # read again first: a waiter may have been promoted since it was listed.
  defp remove(repo, %Claim{id: id}, by, note) do
    case repo.get(Claim, id) do
      nil ->
        {[], []}

      claim ->
        {1, _} = repo.delete_all(from c in Claim, where: c.id == ^id)
        promoted = if claim.status == "held", do: promote(repo, claim), else: nil

        released =
          event(claim, "lock_released", %{
            "released_by" => by,
            "note" => note,
            "was" => claim.status,
            "next_agent_id" => promoted && promoted.agent_id
          })

        granted =
          if promoted, do: [event(promoted, "lock_granted", %{"promoted" => true})], else: []

        {[released | granted], List.wrap(promoted)}
    end
  end

  defp promote(repo, %Claim{repository_id: repository_id, name: name}) do
    case next_waiter(repo, repository_id, name) do
      nil ->
        nil

      waiter ->
        waiter
        |> Claim.changeset(%{status: "held", granted_at: DateTime.utc_now(), turn_ref: nil})
        |> repo.update!()
    end
  end

  defp promote_orphans(channel_id) do
    case Repo.one(
           from ch in Canopy.Channels.Channel,
             where: ch.id == ^channel_id,
             select: ch.repository_id
         ) do
      nil ->
        []

      repository_id ->
        held =
          from h in Claim,
            where: h.repository_id == ^repository_id and h.status == "held",
            select: h.name

        names =
          Repo.all(
            from c in Claim,
              where:
                c.repository_id == ^repository_id and c.status == "waiting" and
                  c.name not in subquery(held),
              distinct: true,
              select: c.name
          )

        Enum.flat_map(names, fn name ->
          case commit(fn repo -> orphan_promotion(repo, repository_id, name) end) do
            {:ok, promoted} -> promoted
            _ -> []
          end
        end)
    end
  end

  defp orphan_promotion(repo, repository_id, name) do
    case {holder(repo, repository_id, name), next_waiter(repo, repository_id, name)} do
      {nil, %Claim{} = waiter} ->
        promoted =
          waiter
          |> Claim.changeset(%{status: "held", granted_at: DateTime.utc_now(), turn_ref: nil})
          |> repo.update!()

        {{:ok, [promoted]}, [event(promoted, "lock_granted", %{"promoted" => true})], [promoted]}

      _ ->
        {{:ok, []}, [], []}
    end
  end

  # -- Turns ------------------------------------------------------------------

  @doc """
  The claims among `claim_ids` the session was granted from the line and no
  turn owns yet: what a grant wake can still hand over.
  """
  def pending_grants(_session_id, []), do: []

  def pending_grants(session_id, claim_ids) do
    Repo.all(
      from c in Claim,
        where:
          c.id in ^claim_ids and c.session_id == ^session_id and c.status == "held" and
            is_nil(c.turn_ref),
        order_by: [asc: c.name],
        preload: [:repository]
    )
  end

  @doc """
  Granted claims in the channel whose wake has not started a turn yet; a
  channel server that starts (after a restart, or late) wakes their sessions.
  """
  def pending_grants_in_channel(channel_id) do
    Repo.all(
      from c in Claim,
        where:
          c.channel_id == ^channel_id and c.status == "held" and not is_nil(c.session_id) and
            is_nil(c.turn_ref)
    )
  end

  @doc "The turn that starts for a grant wake takes ownership of the claims it hands over."
  def stamp_turn(_session_id, [], _turn_ref), do: :ok

  def stamp_turn(session_id, claim_ids, turn_ref) do
    Repo.update_all(
      from(c in Claim,
        where:
          c.id in ^claim_ids and c.session_id == ^session_id and c.status == "held" and
            is_nil(c.turn_ref)
      ),
      set: [turn_ref: turn_ref, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  Tells the repository's lock views that something about the session changed
  (it started or stopped waiting on the user), when it holds or waits for a lock.
  """
  def touch(repository_id, session_id) do
    if Repo.exists?(from c in Claim, where: c.session_id == ^session_id),
      do: broadcast(repository_id, {:locks_changed, repository_id})

    :ok
  end

  # -- Reading ----------------------------------------------------------------

  @doc """
  The locks on a repository, by name: `%{name, holder, queue, awaiting_user?}`
  with `holder` a claim (or nil, briefly) and `queue` the waiters in order.
  `awaiting_user?` is true when the holder's turn is blocked on a question or
  permission card, which is usually why a lock is taking long.
  """
  def list(repository_id) do
    claims =
      Repo.all(
        from c in Claim,
          where: c.repository_id == ^repository_id,
          order_by: [asc: c.name, asc: c.inserted_at, asc: c.id],
          preload: ^@preloads
      )

    awaiting =
      claims
      |> Enum.filter(&(&1.status == "held" and is_binary(&1.session_id)))
      |> Enum.map(& &1.session_id)
      |> awaiting_user()

    claims
    |> Enum.chunk_by(& &1.name)
    |> Enum.map(fn [%{name: name} | _] = group ->
      holder = Enum.find(group, &(&1.status == "held"))

      %{
        name: name,
        holder: holder,
        queue: Enum.filter(group, &(&1.status == "waiting")),
        awaiting_user?: holder != nil and MapSet.member?(awaiting, holder.session_id)
      }
    end)
  end

  @doc "One lock on a repository as `list/1` describes it, or nil."
  def get(repository_id, name) do
    with {:ok, name} <- normalize_name(name) do
      Enum.find(list(repository_id), &(&1.name == name))
    else
      _ -> nil
    end
  end

  @doc "What a session holds or waits for."
  def for_session(session_id) do
    Repo.all(
      from c in Claim,
        where: c.session_id == ^session_id,
        order_by: [asc: c.name],
        preload: ^@preloads
    )
  end

  @doc "The 1-based place of a waiting claim in its line."
  def position(%Claim{} = claim), do: position(Repo, claim)

  defp position(repo, %Claim{repository_id: repository_id, name: name} = claim) do
    repo.aggregate(
      from(c in Claim,
        where:
          c.repository_id == ^repository_id and c.name == ^name and c.status == "waiting" and
            (c.inserted_at < ^claim.inserted_at or
               (c.inserted_at == ^claim.inserted_at and c.id <= ^claim.id))
      ),
      :count
    )
  end

  @doc "Who a claim belongs to, for display: `@agent`, or the user's name."
  def holder_name(%Claim{user: %{display_name: name}}) when is_binary(name), do: name
  def holder_name(%Claim{agent: %{name: name}}) when is_binary(name), do: "@" <> name
  def holder_name(%Claim{user_id: id}) when is_binary(id), do: "the user"
  def holder_name(_claim), do: "an agent"

  @doc "How long a holder has had the lock (or a waiter has waited): `<1m`, `6m`, `2h 5m`."
  def age(%Claim{} = claim, now \\ DateTime.utc_now()) do
    minutes =
      max(DateTime.diff(now, claim.granted_at || claim.inserted_at, :second), 0) |> div(60)

    cond do
      minutes < 1 -> "<1m"
      minutes < 60 -> "#{minutes}m"
      true -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
    end
  end

  # sessions with a card still waiting on the user (not detached)
  defp awaiting_user([]), do: MapSet.new()

  defp awaiting_user(session_ids) do
    questions =
      from q in QuestionRequest,
        where:
          q.agent_session_id in ^session_ids and q.status == "pending" and is_nil(q.detached_at),
        select: q.agent_session_id

    permissions =
      from p in PermissionRequest,
        where:
          p.agent_session_id in ^session_ids and p.status == "pending" and is_nil(p.detached_at),
        select: p.agent_session_id

    MapSet.new(Repo.all(questions) ++ Repo.all(permissions))
  end

  defp holder(repo, repository_id, name),
    do:
      repo.one(
        from c in Claim,
          where: c.repository_id == ^repository_id and c.name == ^name and c.status == "held"
      )

  defp next_waiter(repo, repository_id, name) do
    repo.one(
      from c in Claim,
        where: c.repository_id == ^repository_id and c.name == ^name and c.status == "waiting",
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: 1
    )
  end

  # -- Plumbing ---------------------------------------------------------------

  defp event(claim, type, extra) do
    %{
      channel_id: claim.channel_id,
      agent_id: claim.agent_id,
      event_type: type,
      ref_id: claim.id,
      payload:
        Map.merge(
          %{
            "name" => claim.name,
            "repository_id" => claim.repository_id,
            "reason" => claim.reason,
            "user" => is_binary(claim.user_id),
            "hold_across_turns" => claim.hold_across_turns
          },
          extra
        )
    }
  end

  # Runs `fun.(repo)`, which returns `{result, event_attrs, promoted}` (or
  # `{:error, reason}` to roll back), in a transaction with its timeline events; after the commit the events are
  # broadcast, the repository's lock views told, and each promoted claim
  # announced so its channel server wakes the new holder.
  defp commit(fun) do
    multi =
      Multi.new()
      |> Multi.run(:locks, fn repo, _ ->
        case fun.(repo) do
          {:error, reason} -> {:error, reason}
          {_result, _events, _promoted} = done -> {:ok, done}
        end
      end)
      |> Multi.run(:events, fn repo, %{locks: {_result, events, _promoted}} ->
        Enum.reduce_while(events, {:ok, []}, fn attrs, {:ok, acc} ->
          case repo.insert(Timeline.Event.changeset(%Timeline.Event{}, attrs)) do
            {:ok, event} -> {:cont, {:ok, acc ++ [event]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, %{locks: {result, _attrs, promoted}, events: events}} ->
        Enum.each(events, &Timeline.broadcast/1)
        announce(events, promoted)
        preload_result(result)

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp announce([], []), do: :ok

  defp announce(events, promoted) do
    repository_ids =
      (Enum.map(promoted, & &1.repository_id) ++ Enum.map(events, & &1.payload["repository_id"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(promoted, &broadcast(&1.repository_id, {:lock_granted, &1}))
    Enum.each(repository_ids, &broadcast(&1, {:locks_changed, &1}))
  end

  defp broadcast(repository_id, message),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(repository_id), message)

  defp preload_result({tag, %Claim{} = claim}), do: {tag, Repo.preload(claim, @preloads)}

  defp preload_result({:queued, claim, position, holder}),
    do: {:queued, Repo.preload(claim, @preloads), position, Repo.preload(holder, @preloads)}

  defp preload_result({:ok, tag, %Claim{} = claim}),
    do: {:ok, tag, Repo.preload(claim, @preloads)}

  defp preload_result({:error, {:held, claim}}),
    do: {:error, {:held, Repo.preload(claim, @preloads)}}

  defp preload_result(other), do: other

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
