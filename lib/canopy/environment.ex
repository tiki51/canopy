defmodule Canopy.Environment do
  @moduledoc """
  The Settings page's Environment section: rerun the seeder, and reset Canopy
  to a fresh install (with a backup first).

  A reset runs in `Canopy.Environment.Resetter`, never in a LiveView. While it
  runs, `resetting?/0` is true: `Canopy.Runtime.Supervisor.ensure_channel/2`
  returns `{:error, :resetting}`, the MCP endpoint answers 503, and `seed/0`
  refuses. Progress and the outcome are broadcast on the `"environment"` topic:

      {:environment, {:reset_step, %{id, step, index, total: 4}}}
      {:environment, {:reset_done, result}}
      {:environment, {:reset_failed, failure}}

  See `Canopy.Environment.Resetter` for the order of the steps.
  """

  import Ecto.Query

  alias Canopy.Environment.{Backup, Resetter}
  alias Canopy.{Repo, Seeds}

  @topic "environment"
  @gate {__MODULE__, :resetting}

  @doc """
  Runs the seeder in the caller and returns its report (`Canopy.Seeds.run/0`).
  `{:error, :resetting}` while a reset runs; a reset that starts meanwhile
  waits for this to finish.
  """
  def seed do
    with :ok <- Resetter.seed_begin() do
      try do
        # test seam: holds a seed open while a reset starts
        if hook = Application.get_env(:canopy, :seed_hook), do: hook.()
        Seeds.run()
      after
        Resetter.seed_end()
      end
    end
  end

  @doc "What a reset would delete and keep, counted now, and where its backup would go."
  def preview do
    %{
      deleted: %{
        channels: count("channels", kind: "channel"),
        dms: count("channels", kind: "dm"),
        messages: count("messages"),
        agents: count("agents"),
        teams: count("teams"),
        playbooks: count("playbooks"),
        runs: count("playbook_runs"),
        tasks: count("tasks"),
        schedules: count(from(s in "schedules", where: s.kind in ["once", "recurring"])),
        watches: count("schedules", kind: "watch"),
        memories: count("agent_memories"),
        documents: count("documents"),
        document_bytes:
          Repo.one(from(d in "documents", select: coalesce(sum(d.byte_size), 0))) || 0,
        cost_usd: Canopy.Costs.total(nil).cost
      },
      kept: %{repositories: count("repositories")},
      backup_path: Backup.impl().path(NaiveDateTime.local_now())
    }
  end

  defp count(table, where \\ [])

  defp count(table, where) when is_binary(table),
    do: count(from(t in table, where: ^where))

  defp count(%Ecto.Query{} = query, _), do: Repo.aggregate(query, :count)

  @doc """
  Starts a reset and returns at once with its id. `opts` are for tests
  (`fail_at:`); the typed "reset" check is the UI's job.
  """
  def reset(opts \\ []), do: Resetter.reset(opts)

  @doc "`:idle`, or `{:running, progress}` for a tab that mounts mid-reset. Never blocks."
  def status, do: Resetter.status()

  @doc "The last reset's result or failure since boot, or nil. Never blocks."
  def last_reset, do: Resetter.last_reset()

  @doc "Whether a reset is running. Cheap: runtime and MCP gates call it."
  def resetting?, do: :persistent_term.get(@gate, false)

  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  @doc """
  The text a failure reason shows for an exception. For SQLite errors that is
  the driver's message alone ("database is locked"), without the SQL statement
  `Exqlite.Error.message/1` appends.
  """
  def error_message(%Exqlite.Error{message: message}), do: message
  def error_message(exception) when is_exception(exception), do: Exception.message(exception)

  @doc false
  def broadcast(message),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:environment, message})

  @doc false
  def raise_gate, do: :persistent_term.put(@gate, true)

  @doc false
  def lower_gate do
    # erasing a persistent term makes every process scan for it; skip it when unset
    if resetting?(), do: :persistent_term.erase(@gate)
    :ok
  end
end
