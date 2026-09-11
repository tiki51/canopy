defmodule Canopy.Schedules do
  @moduledoc """
  Scheduled agent tasks: an instruction an agent wrote for its future self, and
  when Canopy should wake it with that instruction. Backed by Oban jobs so a
  schedule survives Canopy restarts.
  """

  import Ecto.Query

  alias Canopy.{Agents, Channels, Repo, Runtime, Timeline}
  alias Canopy.Runtime.Prompts
  alias Canopy.Schedules.{Schedule, When, Worker}

  @preloads [:channel, :agent, :created_by]
  @max_active_per_agent_channel 20
  @overdue_grace_s 6 * 60 * 60
  @topic "schedules"

  # -- Reading ------------------------------------------------------------------

  def get!(id), do: Schedule |> Repo.get!(id) |> Repo.preload(@preloads)
  def get(id), do: Schedule |> Repo.get(id) |> Repo.preload(@preloads)

  @doc "Schedules in a channel, soonest first; `status:` filters (default active and paused)."
  def list_for_channel(channel_id, opts \\ []) do
    statuses = Keyword.get(opts, :status, ["active", "paused"])

    Repo.all(
      from s in Schedule,
        where: s.channel_id == ^channel_id and s.status in ^statuses,
        order_by: [asc: s.next_run_at],
        preload: ^@preloads
    )
  end

  @doc "An agent's schedules across channels, soonest first."
  def list_for_agent(agent_id, opts \\ []) do
    statuses = Keyword.get(opts, :status, ["active", "paused"])

    Repo.all(
      from s in Schedule,
        where: s.agent_id == ^agent_id and s.status in ^statuses,
        order_by: [asc: s.next_run_at],
        preload: ^@preloads
    )
  end

  @doc "Active schedule counts keyed by agent id, for the sidebar."
  def active_counts_by_agent do
    Repo.all(
      from s in Schedule,
        where: s.status == "active",
        group_by: s.agent_id,
        select: {s.agent_id, count(s.id)}
    )
    |> Map.new()
  end

  # -- Creating -----------------------------------------------------------------

  @doc """
  Creates a schedule and its job. Attrs: `:channel_id`, `:agent_id`,
  `:created_by_agent_id`, `:instruction`, and `:when` (see `Canopy.Schedules.When`).
  """
  def create(attrs) when is_map(attrs) do
    now = Map.get(attrs, :now) || DateTime.utc_now()

    with {:ok, timing} <- parse_when(Map.get(attrs, :when), now),
         :ok <- check_cap(attrs[:agent_id], attrs[:channel_id]),
         {:ok, schedule} <- insert(attrs, timing),
         {:ok, _job} <- enqueue(schedule) do
      record(schedule, "schedule_created", %{})
      notify(schedule)
      {:ok, get!(schedule.id)}
    end
  end

  defp parse_when(value, now) do
    case When.parse(value, now) do
      {:error, reason} -> {:error, reason}
      timing -> {:ok, timing}
    end
  end

  defp check_cap(agent_id, channel_id) do
    count =
      Repo.one(
        from s in Schedule,
          where: s.agent_id == ^agent_id and s.channel_id == ^channel_id and s.status == "active",
          select: count(s.id)
      )

    if count >= @max_active_per_agent_channel,
      do:
        {:error,
         "@agent already has #{@max_active_per_agent_channel} active schedules in this channel"},
      else: :ok
  end

  defp insert(attrs, timing) do
    base = Map.take(attrs, [:channel_id, :agent_id, :created_by_agent_id, :instruction])

    timing_attrs =
      case timing do
        {:once, at} -> %{kind: "once", run_at: at, next_run_at: at}
        {:recurring, cron, first} -> %{kind: "recurring", cron: cron, next_run_at: first}
      end

    %Schedule{}
    |> Schedule.changeset(Map.merge(base, timing_attrs))
    |> Repo.insert()
    |> case do
      {:ok, schedule} -> {:ok, schedule}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp enqueue(%Schedule{id: id, next_run_at: at}) do
    %{schedule_id: id} |> Worker.new(scheduled_at: at) |> Oban.insert()
  end

  # -- Changing -----------------------------------------------------------------

  @doc "Cancels a schedule and its pending job. Idempotent."
  def cancel(%Schedule{status: "cancelled"} = schedule, _reason), do: {:ok, schedule}

  def cancel(%Schedule{} = schedule, reason) do
    with {:ok, schedule} <- set_status(schedule, "cancelled", reason) do
      drop_jobs(schedule)
      record(schedule, "schedule_cancelled", %{"reason" => reason})
      notify(schedule)
      {:ok, schedule}
    end
  end

  @doc "Pauses every active schedule in a channel (archive) or for an agent (deactivation)."
  def pause_for_channel(channel_id, reason),
    do: pause_where(dynamic([s], s.channel_id == ^channel_id), reason)

  @doc "Pauses every active schedule (a global hold)."
  def pause_all(reason), do: pause_where(dynamic([s], s.status == "active"), reason)

  @doc "Resumes schedules paused with a reason starting with `prefix` (lifting a hold)."
  def resume_where_reason_starts(prefix) do
    like = prefix <> "%"

    from(s in Schedule, where: s.status == "paused" and like(s.status_reason, ^like))
    |> Repo.all()
    |> Enum.each(&resume/1)

    :ok
  end

  def pause_for_agent(agent_id, reason),
    do: pause_where(dynamic([s], s.agent_id == ^agent_id), reason)

  defp pause_where(condition, reason) do
    from(s in Schedule, where: s.status == "active", where: ^condition)
    |> Repo.all()
    |> Enum.each(fn schedule ->
      {:ok, schedule} = set_status(schedule, "paused", reason)
      drop_jobs(schedule)
      record(schedule, "schedule_paused", %{"reason" => reason})
      notify(schedule)
    end)

    :ok
  end

  @doc "Resumes a channel's paused schedules (reopen), skipping past one-offs."
  def resume_for_channel(channel_id) do
    from(s in Schedule, where: s.channel_id == ^channel_id and s.status == "paused")
    |> Repo.all()
    |> Enum.each(&resume/1)

    :ok
  end

  def resume(%Schedule{} = schedule) do
    now = DateTime.utc_now()

    next =
      case schedule do
        %{kind: "once", run_at: at} ->
          if DateTime.compare(at, now) == :gt, do: {:ok, at}, else: :past

        %{kind: "recurring", cron: cron} ->
          When.next_run(cron, now)
      end

    case next do
      {:ok, at} ->
        {:ok, schedule} =
          schedule
          |> Schedule.changeset(%{status: "active", status_reason: nil, next_run_at: at})
          |> Repo.update()

        {:ok, _} = enqueue(schedule)
        record(schedule, "schedule_resumed", %{})
        notify(schedule)
        {:ok, schedule}

      :past ->
        {:ok, schedule} = set_status(schedule, "done", "its time passed while paused")
        record(schedule, "schedule_skipped", %{"reason" => "its time passed while paused"})
        notify(schedule)
        {:ok, schedule}

      {:error, reason} ->
        set_status(schedule, "cancelled", reason)
    end
  end

  # -- Firing -------------------------------------------------------------------

  @doc "Runs a schedule now: called by the Oban worker."
  def fire(id) do
    if Canopy.Hold.active?(), do: :ok, else: do_fire_if_active(get(id))
  end

  defp do_fire_if_active(schedule) do
    case schedule do
      nil -> :ok
      %Schedule{status: "active"} = schedule -> do_fire(schedule, DateTime.utc_now())
      %Schedule{} -> :ok
    end
  end

  defp do_fire(schedule, now) do
    cond do
      Channels.archived?(schedule.channel) ->
        skip(schedule, "the channel is archived")

      not schedule.agent.active ->
        skip(schedule, "@#{schedule.agent.name} is deactivated")

      schedule.kind == "recurring" and overdue?(schedule, now) ->
        record(schedule, "schedule_skipped", %{
          "reason" => "overdue by more than #{div(@overdue_grace_s, 3600)} hours",
          "run_at" => DateTime.to_iso8601(schedule.next_run_at)
        })

        advance(schedule, now)

      true ->
        {:ok, _} = Runtime.ensure_channel(schedule.channel_id)

        Runtime.wake_scheduled(
          schedule.channel_id,
          schedule.agent_id,
          Prompts.scheduled(%{
            channel: schedule.channel.name,
            schedule_id: schedule.id,
            instruction: schedule.instruction,
            kind: schedule.kind
          })
        )

        record(schedule, "schedule_fired", %{
          "run_at" => DateTime.to_iso8601(schedule.next_run_at)
        })

        {:ok, schedule} =
          schedule
          |> Schedule.changeset(%{last_run_at: now, run_count: schedule.run_count + 1})
          |> Repo.update()

        advance(schedule, now)
    end
  end

  defp overdue?(%{next_run_at: at}, now), do: DateTime.diff(now, at, :second) > @overdue_grace_s

  defp skip(schedule, reason) do
    {:ok, schedule} = set_status(schedule, "paused", reason)
    record(schedule, "schedule_skipped", %{"reason" => reason})
    notify(schedule)
    :ok
  end

  # after a run: a one-off is done; a recurring schedule gets its next job
  defp advance(%Schedule{kind: "once"} = schedule, _now) do
    {:ok, schedule} = set_status(schedule, "done", nil)
    drop_jobs(schedule)
    notify(schedule)
    :ok
  end

  # the next occurrence after the run that just fired (or after now, if later)
  defp advance(%Schedule{kind: "recurring", cron: cron} = schedule, now) do
    from =
      if DateTime.compare(schedule.next_run_at, now) == :gt, do: schedule.next_run_at, else: now

    case When.next_run(cron, from) do
      {:ok, next} ->
        {:ok, schedule} = schedule |> Schedule.changeset(%{next_run_at: next}) |> Repo.update()
        {:ok, _} = enqueue(schedule)
        notify(schedule)
        :ok

      {:error, reason} ->
        {:ok, _} = set_status(schedule, "cancelled", reason)
        :ok
    end
  end

  # -- Helpers ------------------------------------------------------------------

  defp set_status(schedule, status, reason) do
    schedule
    |> Schedule.changeset(%{status: status, status_reason: reason})
    |> Repo.update()
  end

  defp drop_jobs(%Schedule{id: id}) do
    Oban.cancel_all_jobs(
      from j in Oban.Job,
        where: j.worker == "Canopy.Schedules.Worker",
        where: fragment("json_extract(?, '$.schedule_id') = ?", j.args, ^id),
        where: j.state in ["scheduled", "available", "retryable"]
    )
  end

  defp record(schedule, type, extra) do
    {:ok, _} =
      Timeline.record(%{
        channel_id: schedule.channel_id,
        agent_id: schedule.agent_id,
        event_type: type,
        ref_id: schedule.id,
        payload:
          Map.merge(
            %{
              "schedule_id" => schedule.id,
              "agent_id" => schedule.agent_id,
              "instruction" => String.slice(schedule.instruction, 0, 160),
              "kind" => schedule.kind,
              "cron" => schedule.cron,
              "created_by_agent_id" => schedule.created_by_agent_id
            },
            extra
          )
      })
  end

  @doc "Subscribe to `{:schedules, :changed, channel_id}`."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp notify(%Schedule{channel_id: channel_id}),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:schedules, :changed, channel_id})

  # -- Describing ---------------------------------------------------------------

  @doc "A readable form of a cron line for the common shapes, else the line itself."
  def describe_cron(cron) when is_binary(cron) do
    case String.split(cron) do
      [m, h, "*", "*", "*"] when m != "*" and h != "*" ->
        "every day at #{clock(h, m)}"

      [m, h, "*", "*", "1-5"] when m != "*" and h != "*" ->
        "every weekday at #{clock(h, m)}"

      [m, h, "*", "*", dow] when m != "*" and h != "*" ->
        "every #{day_names(dow)} at #{clock(h, m)}"

      ["*/" <> n, "*", "*", "*", "*"] ->
        "every #{n} minutes"

      ["0", "*/" <> n, "*", "*", "*"] ->
        "every #{n} hours"

      [m, "*", "*", "*", "*"] when m != "*" ->
        "every hour at :#{pad(m)}"

      _ ->
        "on `#{cron}`"
    end
  end

  def describe_cron(_), do: nil

  defp clock(h, m), do: pad(h) <> ":" <> pad(m)
  defp pad(n) when byte_size(n) == 1, do: "0" <> n
  defp pad(n), do: n

  @days %{
    "0" => "Sunday",
    "1" => "Monday",
    "2" => "Tuesday",
    "3" => "Wednesday",
    "4" => "Thursday",
    "5" => "Friday",
    "6" => "Saturday",
    "7" => "Sunday"
  }

  defp day_names(spec) do
    spec
    |> String.split(",")
    |> Enum.map(&Map.get(@days, &1, &1))
    |> Enum.join(" and ")
  end

  @doc "\"in 2h\", \"in 3d\", \"now\", \"2h ago\" for a time relative to now."
  def relative(%DateTime{} = at, now \\ DateTime.utc_now()) do
    diff = DateTime.diff(at, now, :second)
    {abs_diff, suffix} = if diff >= 0, do: {diff, ""}, else: {-diff, " ago"}
    prefix = if diff >= 0, do: "in ", else: ""

    text =
      cond do
        abs_diff < 45 -> nil
        abs_diff < 3600 -> "#{div(abs_diff + 30, 60)}m"
        abs_diff < 86_400 -> "#{div(abs_diff + 1800, 3600)}h"
        true -> "#{div(abs_diff + 43_200, 86_400)}d"
      end

    if text, do: prefix <> text <> suffix, else: "now"
  end

  @doc "Local wall-clock text for a time, e.g. \"Wed 10 Sep 09:00\"."
  def local_text(%DateTime{} = at),
    do: at |> When.to_local_naive() |> Calendar.strftime("%a %d %b %H:%M")

  def local_text(_), do: "—"

  @doc "Whether `actor` may cancel or create on behalf of `agent` in `channel`."
  def permitted?(%{id: actor_id}, %{owner_agent_id: owner_id}, agent_id),
    do: actor_id == agent_id or actor_id == owner_id

  def agent_name(agent_id), do: (Agents.get(agent_id) || %{name: "agent"}).name
end
