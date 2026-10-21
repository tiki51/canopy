defmodule Canopy.EnginePauses do
  @moduledoc """
  Engines paused at a usage or billing limit. Replaces the global hold.

  When a turn reports a limit (`data.limit` on its `:agent_error`, or an
  error `limit_error?/1` recognises), the channel server engages a pause for
  that turn's engine. Only that engine stops. Its agents move to their
  fallback model (`Canopy.Fallback`) or wait: their wakes are dropped with a
  line in the channel, and an Auto `once` schedule nudges them a minute
  after the reset.

  Every lift goes through `resume/2`: at the reset (`LiftWorker`, or the
  Auto schedule, whichever runs first), on Resume now and on Release. It
  resumes the schedules the pause paused, nudges the agents that waited,
  writes one `engine_resumed` line per channel the pause touched and
  broadcasts `{:engine_pauses, :changed}` on `"engine_pauses"`.

  `engine_pause_agents` records each (agent, channel) the pause touched, as
  `waiting` or `fallback`, and whether its line was written (`noted`).
  """

  import Ecto.Query

  alias Canopy.{Agents, Channels, Engine, Repo, Runtime, Schedules, Timeline}
  alias Canopy.EnginePauses.{LiftWorker, Pause, PauseAgent}
  alias Canopy.Schedules.Schedule

  require Logger

  @topic "engine_pauses"
  # a reset this close (or already past) is treated as unknown: a lift that
  # fires at once would nudge, hit the limit again and re-pause in a loop
  @min_reset_s 60
  # the lift and the nudge run this long after the reset
  @nudge_after_s 60

  @type limit :: %{
          required(:kind) => String.t(),
          required(:reason) => String.t(),
          optional(:resets_at) => DateTime.t() | nil,
          optional(:detail) => String.t() | nil
        }

  @type entry :: %{
          id: String.t(),
          engine: String.t(),
          kind: String.t(),
          reason: String.t(),
          detail: String.t() | nil,
          resets_at: DateTime.t() | nil,
          paused_at: DateTime.t(),
          waiting: non_neg_integer(),
          on_fallback: non_neg_integer()
        }

  # -- Reading ------------------------------------------------------------------

  @doc """
  The active pauses: those with no reset time first, then by reset time.
  Each carries how many distinct agents wait and how many are on a fallback.
  """
  @spec list() :: [entry]
  def list do
    pauses = Repo.all(from p in Pause, where: is_nil(p.lifted_at))
    counts = counts(Enum.map(pauses, & &1.id))

    pauses
    |> Enum.sort_by(fn p ->
      case p.resets_at do
        nil -> {0, 0}
        at -> {1, DateTime.to_unix(at, :microsecond)}
      end
    end)
    |> Enum.map(&entry(&1, counts))
  end

  @doc "The engine's active pause as a `list/0` entry, or nil."
  @spec get(String.t()) :: entry | nil
  def get(engine) when is_binary(engine) do
    case active(engine) do
      nil -> nil
      pause -> entry(pause, counts([pause.id]))
    end
  end

  def get(_engine), do: nil

  @doc "Whether the engine is paused."
  def paused?(engine) when is_binary(engine),
    do: Repo.exists?(from p in Pause, where: p.engine == ^engine and is_nil(p.lifted_at))

  def paused?(_engine), do: false

  @doc "The engine's active pause row, or nil."
  def active(engine) when is_binary(engine),
    do: Repo.one(from p in Pause, where: p.engine == ^engine and is_nil(p.lifted_at))

  @doc "A pause row by id (lifted or not), or nil."
  def get_pause(id) when is_binary(id), do: Repo.get(Pause, id)
  def get_pause(_id), do: nil

  defp counts([]), do: %{}

  defp counts(ids) do
    Repo.all(
      from a in PauseAgent,
        where: a.pause_id in ^ids,
        group_by: [a.pause_id, a.state],
        select: {a.pause_id, a.state, count(a.agent_id, :distinct)}
    )
    |> Enum.reduce(%{}, fn {id, state, n}, acc -> Map.put(acc, {id, state}, n) end)
  end

  defp entry(%Pause{} = p, counts) do
    %{
      id: p.id,
      engine: p.engine,
      kind: p.kind,
      reason: p.reason,
      detail: p.detail,
      resets_at: p.resets_at,
      paused_at: p.paused_at,
      waiting: Map.get(counts, {p.id, "waiting"}, 0),
      on_fallback: Map.get(counts, {p.id, "fallback"}, 0)
    }
  end

  @doc "When waiting agents are nudged: a minute after the reset, or nil."
  def nudge_at(%{resets_at: nil}), do: nil
  def nudge_at(%{resets_at: at}), do: DateTime.add(at, @nudge_after_s, :second)

  # -- Engaging -----------------------------------------------------------------

  @doc """
  Pauses `engine` at `limit`. Idempotent: with a pause already active, a
  later (or newly known) reset time updates it, re-times the lift and the
  Auto nudges, and broadcasts.

  A `resets_at` already past or under a minute away counts as unknown, so
  the pause lasts until Release (or a later limit reports a real time).
  So does a billing limit's: a rate window resetting doesn't add credit,
  so lifting then would only nudge, fail and pause again. Schedules of agents that now have to wait are paused with the pause's
  `schedule_reason`.
  """
  @spec engage(String.t(), limit, DateTime.t()) :: {:ok, Pause.t()}
  def engage(engine, limit, now \\ DateTime.utc_now()) when is_binary(engine) do
    resets_at =
      if Map.get(limit, :kind) == "billing", do: nil, else: clamp(Map.get(limit, :resets_at), now)

    case active(engine) do
      nil ->
        reason = Map.get(limit, :reason) || "usage limit"

        attrs = %{
          engine: engine,
          kind: Map.get(limit, :kind) || "billing",
          reason: reason,
          detail: limit |> Map.get(:detail) |> truncate(),
          resets_at: resets_at,
          schedule_reason: "paused: #{Engine.label(engine)} #{reason}",
          paused_at: now
        }

        case %Pause{} |> Pause.changeset(attrs) |> Repo.insert() do
          {:ok, pause} ->
            enqueue_lift(pause)
            pause_waiting_schedules(pause)
            broadcast()
            {:ok, pause}

          # another channel engaged it first
          {:error, _} ->
            {:ok, active(engine)}
        end

      pause ->
        if resets_at && later?(resets_at, pause.resets_at) do
          {:ok, pause} =
            pause
            |> Ecto.Changeset.change(
              resets_at: resets_at,
              kind: Map.get(limit, :kind) || pause.kind,
              detail: limit |> Map.get(:detail) |> truncate() || pause.detail
            )
            |> Repo.update()

          enqueue_lift(pause)
          retime_nudges(pause)
          broadcast()
          {:ok, pause}
        else
          {:ok, pause}
        end
    end
  end

  @doc """
  `resets_at` as a pause takes it: nil when unknown, past, or under a
  minute away.
  """
  def clamp(nil, _now), do: nil

  def clamp(%DateTime{} = at, now) do
    if DateTime.diff(at, now, :second) > @min_reset_s, do: at, else: nil
  end

  def clamp(_at, _now), do: nil

  defp later?(_new, nil), do: true
  defp later?(new, old), do: DateTime.compare(new, old) == :gt

  defp truncate(nil), do: nil
  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 2_000)
  defp truncate(other), do: other |> inspect() |> truncate()

  defp enqueue_lift(%Pause{resets_at: nil}), do: :ok
  defp enqueue_lift(%Pause{} = pause), do: enqueue_lift(pause, nudge_at(pause))

  defp enqueue_lift(%Pause{id: id}, at) do
    {:ok, _} =
      %{pause_id: id}
      |> LiftWorker.new(scheduled_at: at, replace: [scheduled: [:scheduled_at]])
      |> Oban.insert()

    :ok
  end

  # Once and recurring schedules of agents that now wait for this engine;
  # Auto schedules and watches are left alone (a watch is skipped lazily).
  defp pause_waiting_schedules(%Pause{} = pause) do
    from(s in Schedule,
      where: s.status == "active" and s.kind in ["once", "recurring"] and is_nil(s.source),
      preload: [:agent]
    )
    |> Repo.all()
    |> Enum.filter(&waits_on?(&1.agent, pause.engine))
    |> Enum.each(&Schedules.pause(&1, pause.schedule_reason))
  end

  @doc "Whether `agent` routes to `{:wait, _}` on `engine`'s pause right now."
  def waits_on?(nil, _engine), do: false

  def waits_on?(agent, engine) do
    Agents.effective_engine(agent) == engine and
      match?({:wait, _}, Canopy.Fallback.route(agent))
  end

  # -- Agents a pause touches ------------------------------------------------------

  @doc """
  Records that `agent_id` is `state` (`"waiting"` or `"fallback"`) on the
  pause in a channel. `{:note, row}` when this state's timeline line has
  yet to be written (a new row, a flipped state, or one not noted yet),
  marking it written; `{:noted, row}` when it already is.
  """
  def mark(%{id: pause_id}, agent_id, channel_id, state) when state in ["waiting", "fallback"] do
    now = DateTime.utc_now()

    case Repo.get_by(PauseAgent, pause_id: pause_id, agent_id: agent_id, channel_id: channel_id) do
      nil ->
        %PauseAgent{
          pause_id: pause_id,
          agent_id: agent_id,
          channel_id: channel_id,
          state: state,
          noted: true
        }
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint([:pause_id, :agent_id, :channel_id])
        |> Repo.insert()
        |> case do
          {:ok, row} ->
            broadcast()
            {:note, row}

          # inserted meanwhile (another channel's server touched the same row)
          {:error, _} ->
            mark(%{id: pause_id}, agent_id, channel_id, state)
        end

      %PauseAgent{state: ^state, noted: true} = row ->
        {:noted, row}

      %PauseAgent{} = row ->
        flipped? = row.state != state

        {:ok, row} =
          row
          |> Ecto.Changeset.change(state: state, noted: true, updated_at: now)
          |> Repo.update()

        if flipped?, do: broadcast()
        {:note, row}
    end
  end

  @doc "Lets the row's next note write a line again (`mark/4` returns `:note`)."
  def unnote(%PauseAgent{} = row) do
    {:ok, row} = row |> Ecto.Changeset.change(noted: false) |> Repo.update()
    row
  end

  @doc """
  An agent's fallback turn hit its target's limit: its `fallback` rows on
  `primary_engine`'s pause become `waiting`, in every channel, so it is
  counted once. Each flipped row gets its nudge, and its line is written
  again on the next note there.
  """
  def flip_to_waiting(primary_engine, agent_id) do
    case active(primary_engine) do
      nil ->
        :ok

      pause ->
        rows =
          Repo.all(
            from a in PauseAgent,
              where: a.pause_id == ^pause.id and a.agent_id == ^agent_id and a.state == "fallback"
          )

        Enum.each(rows, fn row ->
          {:ok, row} =
            row |> Ecto.Changeset.change(state: "waiting", noted: false) |> Repo.update()

          ensure_nudge(pause, row)
        end)

        if rows != [], do: broadcast()
        :ok
    end
  end

  @doc """
  Gives a waiting row its Auto nudge schedule, when the pause knows its
  reset time and the row has none active yet. Returns the row.
  """
  def ensure_nudge(%Pause{resets_at: nil}, row), do: row

  def ensure_nudge(%Pause{} = pause, %PauseAgent{state: "waiting"} = row) do
    case row.schedule_id && Schedules.get(row.schedule_id) do
      %Schedule{status: "active"} ->
        row

      _ ->
        case Schedules.create_auto(%{
               channel_id: row.channel_id,
               agent_id: row.agent_id,
               instruction: nudge_text(pause, "reset"),
               run_at: nudge_at(pause),
               source_ref: pause.id
             }) do
          {:ok, schedule} ->
            {:ok, row} = row |> Ecto.Changeset.change(schedule_id: schedule.id) |> Repo.update()
            row

          {:error, reason} ->
            Logger.warning("engine pause #{pause.id}: no nudge schedule: #{inspect(reason)}")
            row
        end
    end
  end

  def ensure_nudge(_pause, row), do: row

  defp retime_nudges(%Pause{} = pause) do
    at = nudge_at(pause)

    from(a in PauseAgent, where: a.pause_id == ^pause.id and a.state == "waiting")
    |> Repo.all()
    |> Enum.each(fn row ->
      case row.schedule_id && Schedules.get(row.schedule_id) do
        %Schedule{status: "active"} = schedule -> Schedules.retime(schedule, at)
        _ -> ensure_nudge(pause, row)
      end
    end)
  end

  # -- Lifting ------------------------------------------------------------------

  @doc """
  Lifts the engine's pause: `by` is `"reset"` (the reset time came) or
  `"user"` (Resume now, Release). Resumes the schedules it paused, ends its
  Auto nudges, then (after the commit) writes one `engine_resumed` line per
  channel it touched, nudges each agent that waited and broadcasts.
  Resuming an engine that isn't paused is `:ok`; of two concurrent calls,
  only the first lifts and nudges.
  """
  @spec resume(String.t(), String.t()) :: :ok
  def resume(engine, by \\ "user") when by in ["reset", "user"] do
    case active(engine) do
      nil -> :ok
      pause -> lift(pause, by)
    end
  end

  defp lift(%Pause{} = pause, by) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        {count, _} =
          Repo.update_all(
            from(p in Pause, where: p.id == ^pause.id and is_nil(p.lifted_at)),
            set: [lifted_at: now, lifted_by: by, updated_at: now]
          )

        if count == 0, do: Repo.rollback(:lifted)

        Schedules.resume_where_reason(pause.schedule_reason)
        cancel_lift(pause)

        rows =
          Repo.all(from a in PauseAgent, where: a.pause_id == ^pause.id, preload: [:schedule])

        Enum.each(rows, fn
          # paused too: an archived channel's, which unarchiving would otherwise fire late
          %{schedule: %Schedule{status: status} = schedule} when status in ["active", "paused"] ->
            Schedules.finish_auto(schedule)

          _ ->
            :ok
        end)

        rows
      end)

    case result do
      {:ok, rows} ->
        after_lift(pause, by, rows)
        broadcast()
        :ok

      {:error, :lifted} ->
        :ok
    end
  end

  defp cancel_lift(%Pause{id: id}) do
    Oban.cancel_all_jobs(
      from j in Oban.Job,
        where: j.worker == "Canopy.EnginePauses.LiftWorker",
        where: fragment("json_extract(?, '$.pause_id') = ?", j.args, ^id),
        where: j.state in ["scheduled", "available", "retryable"]
    )
  end

  defp after_lift(pause, by, rows) do
    text = nudge_text(pause, by)

    rows
    |> Enum.group_by(& &1.channel_id)
    |> Enum.each(fn {channel_id, rows} ->
      # an archived channel wakes nobody, as its schedules don't fire
      archived? = channel_id |> Channels.get() |> Channels.archived?()

      waiting =
        if archived?,
          do: [],
          else:
            rows
            |> Enum.filter(&(&1.state == "waiting"))
            |> Enum.map(& &1.agent_id)
            |> Enum.uniq()

      returned =
        rows |> Enum.filter(&(&1.state == "fallback")) |> Enum.map(& &1.agent_id) |> Enum.uniq()

      record(channel_id, nil, "engine_resumed", pause, %{
        "by" => by,
        "returned" => Enum.map(returned, &%{"agent_id" => &1, "model" => primary_model(&1)}),
        "nudged" => waiting
      })

      Enum.each(waiting, &nudge(channel_id, &1, text))

      rows
      |> Enum.filter(&(&1.agent_id in waiting and match?(%Schedule{}, &1.schedule)))
      |> Enum.each(&Schedules.record_auto_fired(&1.schedule))
    end)
  end

  defp nudge(channel_id, agent_id, text) do
    Runtime.wake_scheduled(channel_id, agent_id, text)
  rescue
    error ->
      Logger.warning("engine pause: couldn't nudge #{agent_id}: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("engine pause: couldn't nudge #{agent_id}: #{inspect(reason)}")
      :ok
  end

  defp primary_model(agent_id) do
    case Agents.get(agent_id) do
      nil ->
        nil

      agent ->
        case Agents.effective_model(agent) do
          %{model_provider: p, model_id: m} when is_binary(p) and is_binary(m) -> "#{p}/#{m}"
          %{model_id: m} -> m
        end
    end
  end

  @doc """
  The nudge an agent that waited gets: after the reset, or after the user
  resumed the engine.
  """
  def nudge_text(%{engine: engine, reason: reason}, "reset"),
    do:
      "Your #{Engine.label(engine)} #{reason} has reset. " <>
        "Check the channel and carry on with any open work."

  def nudge_text(%{engine: engine}, _by),
    do:
      "#{Engine.label(engine)} has been resumed. Check the channel and carry on with any open work."

  @doc """
  An Auto nudge schedule came due: lifts its pause as a reset. `false` when
  that pause is already lifted, so the schedule fires as a plain one.
  """
  def fire_auto(%Schedule{source: "auto", source_ref: pause_id}) do
    case get_pause(pause_id) do
      %Pause{lifted_at: nil, engine: engine} ->
        resume(engine, "reset")
        true

      _ ->
        false
    end
  end

  @doc """
  Re-enqueues the lift of every active pause with a reset time, at
  `max(resets_at, now) + 60 s`: an environment reset deletes the pending
  jobs (`Canopy.Environment.Clear`).
  """
  def reschedule_all(now \\ DateTime.utc_now()) do
    from(p in Pause, where: is_nil(p.lifted_at) and not is_nil(p.resets_at))
    |> Repo.all()
    |> Enum.each(fn pause ->
      from = if DateTime.compare(pause.resets_at, now) == :gt, do: pause.resets_at, else: now
      enqueue_lift(pause, DateTime.add(from, @nudge_after_s, :second))
    end)

    :ok
  end

  # -- Timeline -----------------------------------------------------------------

  @doc "Records an `engine_*` line, with the pause's shared payload keys."
  def record(channel_id, agent_id, type, %Pause{} = pause, extra) do
    Timeline.record(%{
      channel_id: channel_id,
      agent_id: agent_id,
      event_type: type,
      ref_id: pause.id,
      payload: Map.merge(base_payload(type, pause), extra)
    })
  end

  defp base_payload("engine_resumed", pause),
    do: %{"pause_id" => pause.id, "engine" => pause.engine}

  defp base_payload("engine_fallback", pause) do
    %{
      "pause_id" => pause.id,
      "kind" => pause.kind,
      "reason" => pause.reason,
      "resets_at" => iso(pause.resets_at)
    }
  end

  defp base_payload("engine_wake_dropped", pause) do
    %{
      "pause_id" => pause.id,
      "engine" => pause.engine,
      "resets_at" => iso(pause.resets_at),
      "nudge_at" => iso(nudge_at(pause))
    }
  end

  defp base_payload(_type, pause) do
    %{
      "pause_id" => pause.id,
      "engine" => pause.engine,
      "kind" => pause.kind,
      "reason" => pause.reason,
      "resets_at" => iso(pause.resets_at),
      "nudge_at" => iso(nudge_at(pause))
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # -- Detecting ----------------------------------------------------------------

  @doc """
  The limit an error the adapter didn't recognise stands for, when
  `limit_error?/1` says it is one: billing, until Release.
  """
  def generic_limit(error) do
    if limit_error?(error),
      do: %{kind: "billing", reason: "usage limit", resets_at: nil, detail: error_text(error)},
      else: nil
  end

  defp error_text(text) when is_binary(text), do: text

  defp error_text(%{} = error) do
    case error do
      %{"data" => %{"message" => m}} when is_binary(m) -> m
      %{"message" => m} when is_binary(m) -> m
      %{"name" => n} when is_binary(n) -> n
      _ -> inspect(error)
    end
  end

  @doc """
  A reset time an engine reports as epoch seconds (or milliseconds, when it
  is that large), as an integer, float or string; nil for anything else.
  """
  @spec epoch(term()) :: DateTime.t() | nil
  def epoch(n) when is_integer(n) and n > 1_000_000_000_000, do: epoch(div(n, 1000))

  def epoch(n) when is_integer(n) and n > 0 do
    case DateTime.from_unix(n) do
      {:ok, at} -> DateTime.add(at, 0, :microsecond)
      _ -> nil
    end
  end

  def epoch(n) when is_float(n), do: epoch(trunc(n))

  def epoch(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} -> epoch(int)
      _ -> nil
    end
  end

  def epoch(_), do: nil

  @doc """
  Whether an engine error is a limit worth pausing for: an exhausted
  balance or quota, a payment-required response, (Claude Code) a low credit
  balance or a reached session, weekly, subscription or spend limit, or
  (Codex) a reached plan usage limit or API quota. Claude Code's per-turn
  budget cap and fast-mode limit are not, nor are Codex's rate limits,
  overload and sign-in errors.

  Takes the error's message, or the engine's error map
  (`%{"name" => n, "data" => %{"message" => m}}`), whose Codex error name
  decides when it is one Canopy knows.
  """
  def limit_error?(reason) when is_binary(reason) do
    opencode_limit?(reason) or claude_code_limit?(reason) or codex_limit?(reason)
  end

  # Only a Codex error name decides on an error map. Any other map (Claude
  # Code's, OpenCode's, an unknown Codex name) is false here, and its message
  # is checked as text by the caller's first-line check.
  def limit_error?(%{} = error), do: codex_limit?(error) == true

  def limit_error?(_), do: false

  defp opencode_limit?(reason) do
    Regex.match?(
      ~r/insufficient[ _](balance|quota|credit|funds)|credit_balance_exhausted|no credits remaining|payment required|billing|out of credits|\b402\b/i,
      reason
    )
  end

  # wording from the claude CLI (2.1.x); 2.1.283 says "You've hit your
  # session limit · resets 4:50am (America/Los_Angeles)"
  defp claude_code_limit?(reason) do
    Regex.match?(
      ~r/credit balance (is )?too low|usage limit reached|hit your ((session |weekly |opus |sonnet )?limit|monthly spend limit)|reached your (weekly )?usage limit|out of extra usage/i,
      reason
    )
  end

  # Codex (0.163 `CodexErrorInfo`): the plan's usage limit or the API quota
  # is a limit; rate limits and overload are retried by Codex, and a
  # signed-out Codex is a turn error, so those are not. Other names are
  # `:unknown`, and the message decides through the caller's text check.
  @codex_limits ~w(usageLimitExceeded insufficient_quota)
  @codex_not_limits ~w(rateLimitExceeded serverOverloaded unauthorized)

  defp codex_limit?(%{"name" => name}) when name in @codex_limits, do: true
  defp codex_limit?(%{"name" => name}) when name in @codex_not_limits, do: false

  defp codex_limit?(%{"name" => name}) when is_binary(name) do
    if String.ends_with?(name, "ConnectionFailed"), do: false, else: :unknown
  end

  defp codex_limit?(%{}), do: :unknown

  defp codex_limit?(reason) when is_binary(reason),
    do: Regex.match?(~r/hit your usage limit|\busageLimitExceeded\b/i, reason)

  # -- PubSub -------------------------------------------------------------------

  @doc "Subscribes to `{:engine_pauses, :changed}`."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  @doc false
  def broadcast, do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:engine_pauses, :changed})
end
