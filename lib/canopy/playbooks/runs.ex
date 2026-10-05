defmodule Canopy.Playbooks.Runs do
  @moduledoc """
  Runs of playbooks. The coordinator agent drives a run with the tools it
  already has (delegate, hand off, message); Canopy records where the run is,
  enforces the rules that need enforcing, and puts the run's state into the
  coordinator's prompts (`Canopy.Runtime.ChannelServer`), so nothing about
  the run lives only in a session.

  Rules:

    * one run in progress per channel (a partial unique index);
    * only the coordinator (or the user) advances a run; the coordinator, the
      channel owner, or the user cancels it;
    * a step with `approval: user` is held for the user's Approve when the
      coordinator advances past it. Only the user completes or waives it: an
      agent can neither skip it nor jump past it while it is unapproved, and
      going back before an approved gate makes it need approval again;
    * a run keeps its snapshot of the playbook's text;
    * the coordinator role follows an accepted handoff from the coordinator.

  Every transition re-reads the run inside an immediate transaction and
  commits only against the version its caller saw (`lock_version`, an
  optimistic lock): a transition based on a run that changed meanwhile (a
  reassignment, a cancel, another advance) fails with a reason the caller
  sees. Each one commits with its timeline events (which wake nobody: the
  router has no rule for them) and then broadcasts
  `{:playbook_runs, :changed, channel_id}`. A run whose step goes quiet for
  the playbook's `stall_after` gets one nudge (`Canopy.Playbooks.StallWorker`).
  """

  import Ecto.Query, warn: false

  alias Canopy.{Agents, Channels, Repo, Runtime, Teams, Timeline}
  alias Canopy.Agents.Agent
  alias Canopy.Channels.Channel
  alias Canopy.Playbooks
  alias Canopy.Playbooks.{Definition, Playbook, Run, StallWorker, Step}
  alias Canopy.Runtime.Prompts
  alias Ecto.Multi

  @topic "playbook_runs"
  @preloads [
    :coordinator,
    :started_by,
    :playbook,
    channel: [:repository],
    steps: [delegations: [:to_agent]]
  ]
  @result_excerpt 300
  @max_brief 8_000

  # -- Reading ------------------------------------------------------------------

  def get(id), do: Run |> Repo.get(id) |> preload()
  def get!(id), do: Run |> Repo.get!(id) |> preload()

  @doc "The channel's run in progress (active or awaiting approval), or nil."
  def active_for_channel(channel_id) when is_binary(channel_id) do
    channel_id |> live_query() |> Repo.one() |> preload()
  end

  defp live_query(channel_id),
    do: where(Run, [r], r.channel_id == ^channel_id and r.status in ^Run.live_statuses())

  @doc "The status of the channel's run in progress (`active`, `awaiting_approval`), or nil."
  def live_status(channel_id) when is_binary(channel_id) do
    channel_id |> live_query() |> select([r], r.status) |> Repo.one()
  end

  @doc "A channel's runs, newest first."
  def list_for_channel(channel_id, limit \\ 20) do
    Repo.all(
      from r in Run,
        where: r.channel_id == ^channel_id,
        order_by: [desc: r.id],
        limit: ^limit,
        preload: ^@preloads
    )
  end

  @doc "Channel id => status of its run in progress, for the sidebar (archived channels left out)."
  def live_by_channel do
    Repo.all(
      from r in Run,
        join: c in Channel,
        on: c.id == r.channel_id,
        where: r.status in ^Run.live_statuses() and c.status == "open",
        select: {r.channel_id, r.status}
    )
    |> Map.new()
  end

  @doc "The run's current step row, or nil."
  def current_step(%Run{current_step: id, steps: steps}) when is_list(steps),
    do: Enum.find(steps, &(&1.step_id == id))

  def current_step(%Run{} = run), do: run |> preload() |> current_step()

  @doc "Whether the playbook's text changed since the run started."
  def definition_changed?(%Run{playbook: %Playbook{body: body}, definition: definition}),
    do: body != definition

  def definition_changed?(_run), do: false

  defp preload(nil), do: nil
  defp preload(run), do: Repo.preload(run, @preloads, force: true)

  @doc """
  Who coordinates a run the user starts without naming anyone: the
  playbook's own `coordinator` when that agent is active, else the channel's
  owner when active. Nil when neither is.
  """
  def default_coordinator(playbook_or_definition, channel) do
    definition =
      case playbook_or_definition do
        %Definition{} = d ->
          d

        %Playbook{} = playbook ->
          case Playbooks.definition(playbook) do
            {:ok, d} -> d
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    named = definition && definition.coordinator && Agents.get_by_name(definition.coordinator)
    owner = channel && channel.owner_agent_id && Agents.get(channel.owner_agent_id)

    Enum.find([named, owner], &match?(%Agent{active: true}, &1))
  end

  # -- Starting -----------------------------------------------------------------

  @doc """
  Starts a run. Attrs:

    * `:playbook` — the `%Playbook{}` (enabled)
    * `:channel` — where it was asked for; the run happens there, or in a new
      channel on the same repository when the playbook says `channel: new` or
      `:channel_name` is given
    * `:coordinator` — the agent that coordinates it
    * `:started_by_agent_id` — nil when the user (or a watch) started it
    * `:brief` — what the run is about
    * `:assign` — role overrides: `%{role => agent name}` or `"fix=@fullstack, test=@qa"`
    * `:trigger` — for a run a watch started

  The roster: an `assign` override wins, then a team member whose role label
  on the playbook's team is the role, then a team member named like the role,
  then the playbook's `roles` default. Every agent must be active; a role
  nobody fills fails the start with a message naming it. Missing roster
  agents (the whole team, when the playbook has one) join the channel; a DM
  never gains members, so a run there needs everyone in it already.

  Everything is checked before anything is written; a new channel, its task,
  and the run then commit in one transaction, which also re-checks that the
  playbook still exists, unchanged and enabled. Returns `{:ok, run,
  new_channel?}` or `{:error, reason}`.
  """
  def start(attrs) do
    playbook = Map.fetch!(attrs, :playbook)
    origin = Map.fetch!(attrs, :channel)
    coordinator = Map.fetch!(attrs, :coordinator)
    by = Map.get(attrs, :started_by_agent_id)
    trigger = Map.get(attrs, :trigger)

    with :ok <- check_enabled(playbook),
         {:ok, definition} <- parse(playbook),
         {:ok, brief} <- check_brief(Map.get(attrs, :brief)),
         :ok <- check_active(coordinator, "the coordinator"),
         {:ok, overrides} <- parse_assign(Map.get(attrs, :assign), definition),
         team = definition.team && Teams.get_by_name(definition.team),
         {:ok, roster} <- resolve_roster(definition, team, overrides),
         new? = definition.channel == "new" or present?(Map.get(attrs, :channel_name)),
         :ok <- check_target(origin, new?, roster, team, coordinator),
         {:ok, %{run: run} = changes} <-
           commit_start(attrs, playbook, definition, origin, new?, brief, roster, team) do
      broadcast_events(changes)
      if new?, do: Channels.notify_changed()
      unless new?, do: join_roster(run.channel_id, team, roster, coordinator, by)
      after_change(run)

      # The coordinator learns of the run: an agent that started it here is
      # in its own turn already; anyone else (the user, a watch) or a new
      # channel needs a wake. Only the user's own start resets the chatter budget.
      if new? or is_nil(by) do
        wake(run, Prompts.playbook_started(started_args(run, definition, new?)),
          reset: is_nil(by) and is_nil(trigger)
        )
      end

      {:ok, get!(run.id), new?}
    end
  end

  defp check_enabled(%Playbook{enabled: true}), do: :ok

  defp check_enabled(%Playbook{name: name}),
    do: {:error, "#{name} is disabled; the user enables it on the Playbooks page"}

  defp parse(%Playbook{} = playbook) do
    case Playbooks.definition(playbook) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, reasons} ->
        {:error, "#{playbook.name} does not parse: " <> Enum.join(reasons, "; ")}
    end
  end

  defp check_brief(brief) do
    case brief && String.trim(brief) do
      text when is_binary(text) and text != "" ->
        if String.length(text) > @max_brief,
          do: {:error, "the brief is too long (at most #{@max_brief} characters)"},
          else: {:ok, text}

      _ ->
        {:error, "brief is empty: say what this run is about"}
    end
  end

  defp check_active(%Agent{active: true}, _what), do: :ok
  defp check_active(%Agent{name: name}, what), do: {:error, "#{what} @#{name} is deactivated"}
  defp check_active(nil, what), do: {:error, "#{what} is missing"}

  @doc """
  Reads role overrides, `"fix=@fullstack, test=@qa"` or a map, against the
  playbook's roles. Returns `{:ok, %{role => agent name}}`.
  """
  def parse_assign(nil, _definition), do: {:ok, %{}}
  def parse_assign("", _definition), do: {:ok, %{}}

  def parse_assign(text, definition) when is_binary(text) do
    text
    |> String.split([",", "\n", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      case Regex.run(~r/\A([a-z0-9][\w-]*)\s*[=:]\s*@?([A-Za-z0-9][\w-]*)\z/, pair) do
        [_, role, agent] ->
          {:cont, {:ok, Map.put(acc, role, String.downcase(agent))}}

        nil ->
          {:halt, {:error, "assign: write role=@agent, comma separated (got #{inspect(pair)})"}}
      end
    end)
    |> case do
      {:ok, map} -> parse_assign(map, definition)
      error -> error
    end
  end

  def parse_assign(%{} = map, definition) do
    roles = Definition.owner_roles(definition)

    map
    |> Enum.reject(fn {_role, agent} -> agent in [nil, ""] end)
    |> Enum.reduce_while({:ok, %{}}, fn {role, agent}, {:ok, acc} ->
      role = to_string(role)

      if role in roles,
        do: {:cont, {:ok, Map.put(acc, role, String.trim_leading(agent, "@"))}},
        else:
          {:halt,
           {:error,
            "assign: #{definition.name} has no role #{role} (its roles: #{Enum.join(roles, ", ")})"}}
    end)
  end

  @doc """
  The roster for a definition: `{:ok, %{role => agent_id}}` or an error that
  names the role nobody fills (or the deactivated agent that would).
  """
  def resolve_roster(%Definition{} = definition, team, overrides \\ %{}) do
    {members, labels} = team_members(team)

    definition
    |> Definition.owner_roles()
    |> Enum.reduce_while({:ok, %{}}, fn role, {:ok, acc} ->
      case fill_role(role, definition, team, members, labels, overrides) do
        {:ok, agent} -> {:cont, {:ok, Map.put(acc, role, agent.id)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Who fills each role of a definition when a run starts with no overrides,
  decided the way `resolve_roster/3` decides it, for a page to show before
  the start: `[%{role, agent, source}]`, where `source` says why ("from
  @team", "playbook default") and `agent` is nil when nobody does.
  """
  def roster_preview(%Definition{} = definition) do
    team = definition.team && Teams.get_by_name(definition.team)
    {members, labels} = team_members(team)

    definition
    |> Definition.owner_roles()
    |> Enum.map(fn role ->
      case role_candidate(role, definition, members, labels, %{}) do
        {:agent, agent} ->
          %{role: role, agent: agent, source: "from @#{team.name}"}

        {:named, name} ->
          case Agents.get_by_name(name) do
            %Agent{active: true} = agent ->
              %{role: role, agent: agent, source: "playbook default"}

            _ ->
              %{role: role, agent: nil, source: "@#{name} isn't available"}
          end

        :none ->
          %{role: role, agent: nil, source: "nobody fills it yet"}
      end
    end)
  end

  defp team_members(nil), do: {[], %{}}
  defp team_members(team), do: {Teams.active_members(team), Teams.member_roles(team)}

  defp fill_role(role, definition, team, members, labels, overrides) do
    case role_candidate(role, definition, members, labels, overrides) do
      {:agent, agent} ->
        {:ok, agent}

      {:named, name} ->
        case Agents.get_by_name(name) do
          nil -> {:error, "no agent @#{name} for role #{role}; fix it with assign"}
          %Agent{active: false} -> {:error, "@#{name} (role #{role}) is deactivated; use assign"}
          agent -> {:ok, agent}
        end

      :none ->
        where = if team, do: " (not on @#{team.name})", else: ""

        {:error, "nobody fills role #{role}#{where}; start again with assign: \"#{role}=@agent\""}
    end
  end

  # Who a role falls to: an override, a team member whose role label is the
  # role, a team member named like it, then the playbook's default.
  defp role_candidate(role, definition, members, labels, overrides) do
    cond do
      name = overrides[role] -> {:named, name}
      agent = Enum.find(members, &(labels[&1.id] == role)) -> {:agent, agent}
      agent = Enum.find(members, &(&1.name == role)) -> {:agent, agent}
      name = definition.roles[role] -> {:named, name}
      true -> :none
    end
  end

  # Where the run happens: the channel it was asked for (checked here), or a
  # new one on the same repository (created when the run commits).
  defp check_target(_origin, true, _roster, _team, _coordinator), do: :ok

  defp check_target(origin, false, roster, team, coordinator) do
    cond do
      Channels.archived?(origin) ->
        {:error, "##{origin.name} is archived"}

      active = active_for_channel(origin.id) ->
        {:error, already_running(origin, active)}

      Channels.dm?(origin) and not dm_has?(origin, roster, team, coordinator) ->
        {:error,
         "a DM keeps its agents and this run needs others (the coordinator or the roster); start it with channel_name to run it in a new channel"}

      true ->
        :ok
    end
  end

  defp dm_has?(dm, roster, team, coordinator) do
    members = dm |> Channels.members() |> MapSet.new(& &1.id)
    team_ids = if team, do: Enum.map(Teams.active_members(team), & &1.id), else: []
    Enum.all?([coordinator.id | Map.values(roster) ++ team_ids], &MapSet.member?(members, &1))
  end

  defp already_running(channel, run) do
    "##{channel.name} already has a playbook run in progress (#{run.playbook_name}, #{run.id}); " <>
      "finish or cancel it first, or start in a new channel with channel_name"
  end

  @doc """
  A new run's channel name: the one `given` (trimmed, without `#`), or a
  free one on the repository made from the playbook's name and the brief's
  first words (`channel_name_base/2`), `-2` and on when taken. With no
  repository yet, the base as it is.
  """
  def channel_name(repository_id, given, playbook_name, brief) do
    if present?(given) do
      given
      |> String.trim()
      |> String.trim_leading("#")
      |> String.downcase()
      |> String.slice(0, 50)
      |> String.trim("-")
    else
      free_channel_name(repository_id, channel_name_base(playbook_name, brief))
    end
  end

  @doc "The playbook's name and the brief's first four words, as a channel name (not checked for being free)."
  def channel_name_base(playbook_name, brief) do
    words =
      (brief || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, " ")
      |> String.split()
      |> Enum.take(4)

    [playbook_name | words] |> Enum.join("-") |> String.slice(0, 50) |> String.trim("-")
  end

  @doc "`base`, or `base-2` and on: the first name no channel on the repository has."
  def free_channel_name(nil, base), do: base

  def free_channel_name(repository_id, base) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&is_nil(Channels.get_by_name(repository_id, &1)))
  end

  # The playbook re-checked, the new channel (if any), the run and its steps,
  # and their timeline lines: one immediate transaction, so a failure leaves
  # nothing behind and a delete of the playbook cannot slip in between.
  defp commit_start(attrs, playbook, definition, origin, new?, brief, roster, team) do
    coordinator = attrs.coordinator

    Multi.new()
    |> Multi.run(:playbook, fn repo, _ ->
      case repo.get(Playbook, playbook.id) do
        %Playbook{enabled: true, body: body} = current when body == playbook.body ->
          {:ok, current}

        %Playbook{enabled: true} ->
          {:error, "#{playbook.name} changed while the run was starting; start it again"}

        %Playbook{} ->
          {:error, "#{playbook.name} is disabled; the user enables it on the Playbooks page"}

        nil ->
          {:error, "#{playbook.name} no longer exists"}
      end
    end)
    |> Multi.run(:channel, fn _repo, _ ->
      if new? do
        name =
          channel_name(origin.repository_id, Map.get(attrs, :channel_name), playbook.name, brief)

        case Channels.create(%{
               repository_id: origin.repository_id,
               name: name,
               topic: "#{playbook.name}: " <> String.slice(single_line(brief), 0, 200),
               owner_agent_id: coordinator.id,
               agent_ids: Map.values(roster),
               team_ids: if(team, do: [team.id], else: []),
               task_title: String.slice(single_line(brief), 0, 120),
               task_description: brief
             }) do
          {:ok, channel} ->
            {:ok, channel}

          {:error, changeset} ->
            {:error,
             "could not create the channel: " <> Canopy.MCP.Tool.changeset_reason(changeset)}
        end
      else
        {:ok, origin}
      end
    end)
    |> Multi.merge(fn %{channel: channel} ->
      run_multi(playbook, definition, channel, coordinator, brief, roster, attrs)
    end)
    |> Repo.transaction(mode: :immediate)
    |> case do
      {:ok, changes} ->
        {:ok, changes}

      {:error, :run, %Ecto.Changeset{} = changeset, %{channel: channel}} ->
        if Keyword.has_key?(changeset.errors, :channel_id) do
          {:error,
           already_running(
             channel,
             active_for_channel(channel.id) || %{playbook_name: "?", id: "?"}
           )}
        else
          {:error, "could not start: " <> Canopy.MCP.Tool.changeset_reason(changeset)}
        end

      {:error, _step, %Ecto.Changeset{} = changeset, _} ->
        {:error, "could not start: " <> Canopy.MCP.Tool.changeset_reason(changeset)}

      {:error, _step, reason, _} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp run_multi(playbook, definition, channel, coordinator, brief, roster, attrs) do
    by = Map.get(attrs, :started_by_agent_id)
    now = DateTime.utc_now()
    [first | _] = definition.steps

    run_changeset =
      Run.changeset(%Run{}, %{
        playbook_id: playbook.id,
        playbook_name: playbook.name,
        definition: playbook.body,
        channel_id: channel.id,
        coordinator_agent_id: coordinator.id,
        started_by_agent_id: by,
        brief: brief,
        roster: roster,
        status: "active",
        current_step: first.id,
        trigger: Map.get(attrs, :trigger),
        stall_after_minutes: definition.stall_after,
        last_activity_at: now
      })

    definition.steps
    |> Enum.with_index(1)
    |> Enum.reduce(Multi.insert(Multi.new(), :run, run_changeset), fn {step, position}, multi ->
      Multi.insert(multi, {:step, step.id}, fn %{run: run} ->
        first? = position == 1

        Step.changeset(%Step{}, %{
          run_id: run.id,
          step_id: step.id,
          position: position,
          title: step.title,
          owner_roles: step.owner,
          owner_ids: owner_ids(step.owner, roster),
          approval: step.approval,
          optional: step.optional,
          status: if(first?, do: "active", else: "pending"),
          round: if(first?, do: 1, else: 0),
          started_at: if(first?, do: now)
        })
      end)
    end)
    |> Timeline.multi_record(:started_event, fn %{run: run} ->
      event(run, by, "playbook_started", %{
        "steps" => length(definition.steps),
        "coordinator_agent_id" => run.coordinator_agent_id,
        "brief" => String.slice(single_line(brief), 0, @result_excerpt),
        "trigger" => run.trigger
      })
    end)
    |> Timeline.multi_record(:step_event, fn %{run: run} ->
      step_event(run, by, first, 1, 1, length(definition.steps), roster)
    end)
  end

  defp owner_ids(roles, roster),
    do: roles |> Enum.map(&Map.get(roster, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  # The whole team joins in one line; anyone else missing joins on their own.
  # A DM was checked to have them all already.
  defp join_roster(channel_id, team, roster, coordinator, by) do
    channel = Channels.get!(channel_id)

    unless Channels.dm?(channel) do
      if team, do: Channels.add_team(channel, team, by || "user")

      (Map.values(roster) ++ [coordinator.id])
      |> Enum.uniq()
      |> Enum.each(fn id ->
        unless Channels.member?(channel, id), do: Channels.add_agent(channel, id)
      end)
    end
  end

  # -- Transitions ------------------------------------------------------------------

  # Runs `build.(fresh)` against the run as it is now, inside an immediate
  # transaction, and only when it is the version the caller saw. `build`
  # returns `{:ok, multi, what}` (the multi updates the run as `:run`, through
  # `update_run/3`) or `{:error, reason}`.
  defp transition(%Run{id: id, lock_version: seen}, build) do
    Multi.new()
    |> Multi.run(:plan, fn _repo, _ ->
      case get(id) do
        nil ->
          {:error, "run #{id} no longer exists"}

        %Run{lock_version: ^seen} = fresh ->
          case build.(fresh) do
            {:ok, multi, what} -> {:ok, {multi, what}}
            {:error, reason} -> {:error, reason}
          end

        fresh ->
          {:error, stale(fresh)}
      end
    end)
    |> Multi.merge(fn %{plan: {multi, _what}} -> multi end)
    |> Repo.transaction(mode: :immediate)
    |> case do
      {:ok, %{plan: {_multi, what}} = changes} ->
        broadcast_events(changes)
        run = get!(id)
        after_change(run)
        {:ok, run, what}

      {:error, :plan, reason, _} ->
        {:error, reason}

      {:error, :run, %Ecto.Changeset{errors: errors} = changeset, _} ->
        if Keyword.has_key?(errors, :lock_version),
          do: {:error, stale(get(id))},
          else: {:error, Canopy.MCP.Tool.changeset_reason(changeset)}

      {:error, _step, %Ecto.Changeset{} = changeset, _} ->
        {:error, Canopy.MCP.Tool.changeset_reason(changeset)}

      {:error, _step, reason, _} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp stale(nil), do: "the run no longer exists"

  defp stale(%Run{} = run) do
    where = if run.current_step, do: ", on step #{run.current_step}", else: ""

    "run #{run.id} changed meanwhile (it is now #{run.status}#{where}, coordinated by " <>
      "#{if run.coordinator, do: "@" <> run.coordinator.name, else: "nobody"}); " <>
      "read it again with canopy_playbook_get before you try again"
  end

  # Every write to a run goes through here: the version must still be the one read.
  defp run_update(%Run{} = run, attrs) do
    run |> Run.changeset(attrs) |> Ecto.Changeset.optimistic_lock(:lock_version)
  end

  defp update_run(multi, run, attrs),
    do: Multi.update(multi, :run, run_update(run, attrs), stale_error_field: :lock_version)

  # -- Advancing ----------------------------------------------------------------

  @doc """
  Moves a run on. `actor` is `{:agent, agent_id}` (the coordinator only) or
  `:user`. Options: `:result` (kept on the step), `:next` (any step id;
  default the following step), `:skip` (allowed for an optional step, or with
  a result saying why; an approval step only by the user).

  Advancing past an approval step holds it for the user (`{:ok, run,
  :awaiting_approval}`), remembering a requested `next` for when it is
  approved; going back from one leaves it pending. An agent cannot move the
  run past an approval step that is not approved. Completing the last step
  completes the run (`{:ok, run, :completed}`); otherwise `{:ok, run,
  {:step, step_id}}` with that step now active.
  """
  def advance(%Run{} = run, actor, opts \\ []) do
    result = opts |> Keyword.get(:result) |> blank_to_nil()
    skip? = Keyword.get(opts, :skip, false) == true
    requested = opts |> Keyword.get(:next) |> blank_to_nil()

    transition(run, fn run ->
      with :ok <- check_live(run),
           :ok <- check_not_waiting(run),
           :ok <- check_coordinator(run, actor, "advance"),
           {:ok, current} <- fetch_current(run),
           {:ok, next} <- next_step(run, current, requested),
           :ok <- check_skip(current, skip?, result, actor),
           backward? = next != nil and next.position <= current.position,
           holding? = current.approval and not skip? and not backward?,
           :ok <- check_gates(run, current, next, actor, holding?) do
        if holding? do
          request_approval(run, current, result, requested && next, actor)
        else
          status =
            cond do
              skip? -> "skipped"
              current.approval -> "pending"
              true -> "done"
            end

          move_on(run, current, status, result, next, actor)
        end
      end
    end)
  end

  defp fetch_current(run) do
    case current_step(run) do
      nil -> {:error, "run #{run.id} has no current step"}
      step -> {:ok, step}
    end
  end

  defp check_live(%Run{} = run) do
    if Run.live?(run), do: :ok, else: {:error, "run #{run.id} is #{run.status}"}
  end

  defp check_not_waiting(%Run{status: "awaiting_approval"} = run) do
    {:error,
     "run #{run.id} is waiting for the user's approval of #{run.current_step}; end your turn, Canopy wakes you with their answer"}
  end

  defp check_not_waiting(_run), do: :ok

  defp check_coordinator(_run, :user, _verb), do: :ok

  defp check_coordinator(%Run{coordinator_agent_id: id}, {:agent, id}, _verb) when is_binary(id),
    do: :ok

  defp check_coordinator(run, {:agent, _id}, verb) do
    who = if run.coordinator, do: "@" <> run.coordinator.name, else: "its coordinator"

    {:error,
     "only #{who} can #{verb} #{run.playbook_name} (#{run.id}); report through your delegation instead"}
  end

  defp next_step(run, current, nil) do
    {:ok, Enum.find(run.steps, &(&1.position == current.position + 1))}
  end

  defp next_step(run, _current, id) when is_binary(id) do
    case Enum.find(run.steps, &(&1.step_id == String.trim(id))) do
      nil ->
        {:error,
         "no step #{id} in #{run.playbook_name}; steps: " <>
           Enum.map_join(run.steps, ", ", & &1.step_id)}

      step ->
        {:ok, step}
    end
  end

  defp check_skip(_step, false, _result, _actor), do: :ok

  # an approval step is the user's: only they may waive it
  defp check_skip(%Step{approval: true} = step, true, _result, {:agent, _}),
    do:
      {:error,
       "step #{step.step_id} needs the user's approval and cannot be skipped; advance to hold it for them"}

  defp check_skip(%Step{optional: true}, true, _result, _actor), do: :ok
  defp check_skip(_step, true, result, _actor) when is_binary(result), do: :ok

  defp check_skip(step, true, _result, _actor),
    do:
      {:error, "step #{step.step_id} is not optional; give the reason for skipping it in result"}

  # An agent cannot move the run past an approval step that is not approved
  # (or waived by the user): no such step may lie before where the run goes
  # (or, when it completes, anywhere). The current step counts only when the
  # run leaves it without holding it for approval.
  defp check_gates(_run, _current, _next, :user, _holding?), do: :ok

  defp check_gates(run, current, next, {:agent, _}, holding?) do
    limit = if next, do: next.position, else: length(run.steps) + 1

    blocking =
      Enum.find(run.steps, fn s ->
        s.approval and not cleared?(s) and s.position < limit and
          (s.id != current.id or not holding?)
      end)

    case blocking do
      nil ->
        :ok

      gate ->
        {:error,
         "step #{gate.step_id} (\"#{gate.title}\") needs the user's approval before the run can move past it; " <>
           "go to it with next: \"#{gate.step_id}\" and advance from there to hold it for them"}
    end
  end

  # approved, or waived (skipped) by the user
  defp cleared?(%Step{status: "done", approved_at: %DateTime{}}), do: true
  defp cleared?(%Step{status: "skipped"}), do: true
  defp cleared?(_step), do: false

  defp request_approval(run, step, result, next, actor) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> update_run(run, %{status: "awaiting_approval", last_activity_at: now})
      |> Multi.update(
        :step,
        Step.changeset(step, %{
          status: "awaiting_approval",
          result: result,
          approval_next: next && next.step_id
        })
      )
      |> Timeline.multi_record(:event, fn _ ->
        event(run, actor_id(actor), "playbook_approval_requested", %{
          "step" => step.step_id,
          "title" => step.title,
          "result" => excerpt(result),
          "next" => next && next.step_id
        })
      end)

    {:ok, multi, :awaiting_approval}
  end

  # Advancing to the step already current enters it again (another round).
  defp move_on(run, %Step{id: id} = current, _status, result, %Step{id: id}, actor) do
    now = DateTime.utc_now()
    round = current.round + 1

    multi =
      Multi.new()
      |> update_run(run, %{last_activity_at: now, nudged_at: nil})
      |> Multi.update(
        :current,
        Step.changeset(current, %{
          status: "active",
          round: round,
          result: result || current.result,
          started_at: now
        })
      )
      |> Timeline.multi_record(:event, fn _ ->
        step_event(run, actor_id(actor), current, round, current.position, length(run.steps), nil)
      end)

    {:ok, multi, {:step, current.step_id}}
  end

  # Marks `current` with `status` and activates `next`, or completes the run
  # when there is none. Going back makes the approval steps after the target
  # need approval again: what they approved is being redone.
  defp move_on(run, current, status, result, next, actor) do
    now = DateTime.utc_now()
    total = length(run.steps)

    multi =
      Multi.new()
      |> Multi.update(
        :current,
        Step.changeset(current, %{
          status: status,
          result: result || current.result,
          completed_at: if(status in ["done", "skipped"], do: now)
        })
      )
      |> Timeline.multi_record(:done_event, fn _ ->
        event(run, actor_id(actor), done_type(status), %{
          "step" => current.step_id,
          "title" => current.title,
          "result" => excerpt(result),
          "next" => next && next.step_id,
          "next_title" => next && next.title,
          "next_owner_ids" => next && next.owner_ids
        })
      end)

    multi =
      if next && next.position < current.position do
        Multi.update_all(
          multi,
          :reopen_gates,
          from(s in Step,
            where:
              s.run_id == ^run.id and s.approval == true and s.position > ^next.position and
                s.id != ^current.id and s.status in ["done", "skipped"]
          ),
          set: [status: "pending", approved_at: nil, completed_at: nil, approval_next: nil]
        )
      else
        multi
      end

    case next do
      nil ->
        multi =
          multi
          |> update_run(run, %{
            status: "completed",
            current_step: nil,
            outcome: result,
            finished_at: now,
            last_activity_at: now
          })
          |> Timeline.multi_record(:event, fn _ ->
            event(run, actor_id(actor), "playbook_completed", %{"outcome" => excerpt(result)})
          end)

        {:ok, multi, :completed}

      next ->
        round = next.round + 1

        multi =
          multi
          |> Multi.update(
            :next,
            Step.changeset(next, %{
              status: "active",
              round: round,
              started_at: now,
              completed_at: nil,
              approved_at: nil
            })
          )
          |> update_run(run, %{current_step: next.step_id, last_activity_at: now, nudged_at: nil})
          |> Timeline.multi_record(:event, fn _ ->
            step_event(run, actor_id(actor), next, round, next.position, total, nil)
          end)

        {:ok, multi, {:step, next.step_id}}
    end
  end

  defp done_type("skipped"), do: "playbook_step_skipped"
  defp done_type(_status), do: "playbook_step_completed"

  # -- Approval -----------------------------------------------------------------

  @doc """
  The user approves the step held for approval: it is done, the run moves to
  the step the coordinator asked for (else the following one, or completes),
  and the coordinator is woken with the answer. A user action, so it resets
  the channel's chatter budget.
  """
  def approve(%Run{} = run, note \\ nil) do
    note = blank_to_nil(note)
    approved = current_step(run)

    run
    |> transition(fn run ->
      with :ok <- check_awaiting(run),
           {:ok, step} <- fetch_current(run) do
        next =
          Enum.find(run.steps, &(&1.step_id == step.approval_next)) ||
            Enum.find(run.steps, &(&1.position == step.position + 1))

        approve_multi(run, step, next, note)
      end
    end)
    |> case do
      {:ok, run, what} ->
        wake(run, Prompts.playbook_approved(approval_args(run, approved, note, what)),
          reset: true
        )

        {:ok, run, what}

      error ->
        error
    end
  end

  defp approve_multi(run, step, next, note) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.update(
        :current,
        Step.changeset(step, %{
          status: "done",
          approved_at: now,
          completed_at: now,
          approval_next: nil
        })
      )
      |> Timeline.multi_record(:approval_event, fn _ ->
        event(run, nil, "playbook_approval_resolved", %{
          "step" => step.step_id,
          "title" => step.title,
          "approved" => true,
          "note" => note
        })
      end)

    case next do
      nil ->
        multi =
          multi
          |> update_run(run, %{
            status: "completed",
            current_step: nil,
            outcome: step.result,
            finished_at: now,
            last_activity_at: now
          })
          |> Timeline.multi_record(:event, fn _ ->
            event(run, nil, "playbook_completed", %{"outcome" => excerpt(step.result)})
          end)

        {:ok, multi, :completed}

      next ->
        multi =
          multi
          |> Multi.update(
            :next,
            Step.changeset(next, %{status: "active", round: next.round + 1, started_at: now})
          )
          |> update_run(run, %{
            status: "active",
            current_step: next.step_id,
            last_activity_at: now,
            nudged_at: nil
          })
          |> Timeline.multi_record(:event, fn _ ->
            step_event(run, nil, next, next.round + 1, next.position, length(run.steps), nil)
          end)

        {:ok, multi, {:step, next.step_id}}
    end
  end

  @doc """
  The user asks for changes on the step held for approval: it is active
  again, and the coordinator is woken with the note to advance (`next:`) to
  the step that fits it. Resets the chatter budget.
  """
  def request_changes(%Run{} = run, note) do
    with {:ok, note} <- required_note(note),
         {:ok, run, what} <-
           transition(run, fn run ->
             with :ok <- check_awaiting(run),
                  {:ok, step} <- fetch_current(run) do
               multi =
                 Multi.new()
                 |> update_run(run, %{
                   status: "active",
                   last_activity_at: DateTime.utc_now(),
                   nudged_at: nil
                 })
                 |> Multi.update(
                   :current,
                   Step.changeset(step, %{status: "active", approval_next: nil})
                 )
                 |> Timeline.multi_record(:event, fn _ ->
                   event(run, nil, "playbook_approval_resolved", %{
                     "step" => step.step_id,
                     "title" => step.title,
                     "approved" => false,
                     "note" => note
                   })
                 end)

               {:ok, multi, :changes_requested}
             end
           end) do
      wake(
        run,
        Prompts.playbook_changes_requested(approval_args(run, current_step(run), note, what)),
        reset: true
      )

      {:ok, run, what}
    end
  end

  defp check_awaiting(%Run{status: "awaiting_approval"}), do: :ok
  defp check_awaiting(run), do: {:error, "run #{run.id} is not waiting for approval"}

  defp required_note(note) do
    case blank_to_nil(note) do
      nil -> {:error, "say what should change"}
      text -> {:ok, text}
    end
  end

  # -- Cancelling and the coordinator ---------------------------------------------

  @doc """
  Cancels a run. `actor` is `{:agent, id}` (the coordinator or the channel
  owner) or `:user`.
  """
  def cancel(%Run{} = run, actor, reason) do
    reason = blank_to_nil(reason)

    transition(run, fn run ->
      with :ok <- check_live(run),
           :ok <- check_canceller(run, actor) do
        multi =
          Multi.new()
          |> update_run(run, %{
            status: "cancelled",
            outcome: reason,
            finished_at: DateTime.utc_now()
          })
          |> Timeline.multi_record(:event, fn _ ->
            event(run, actor_id(actor), "playbook_cancelled", %{
              "reason" => reason,
              "step" => run.current_step
            })
          end)

        {:ok, multi, :cancelled}
      end
    end)
  end

  defp check_canceller(_run, :user), do: :ok
  defp check_canceller(%Run{coordinator_agent_id: id}, {:agent, id}) when is_binary(id), do: :ok

  defp check_canceller(%Run{channel: %Channel{owner_agent_id: id}}, {:agent, id})
       when is_binary(id),
       do: :ok

  defp check_canceller(run, {:agent, _}),
    do:
      {:error,
       "only the coordinator or the channel owner can cancel #{run.playbook_name} (#{run.id})"}

  @doc """
  Hands the run to another coordinator; `by` is "user" (the run panel). The
  new coordinator joins the channel when it is not a member, except in a DM,
  which keeps its agents. A user's reassignment wakes the new coordinator
  with the current step, unless that step waits on the user's approval.
  (An accepted handoff moves the role inside the handoff's own transaction:
  `follow_handoff_multi/2`.)
  """
  def reassign(%Run{} = run, %Agent{} = agent, by) do
    channel = Channels.get!(run.channel_id)

    with :ok <- check_active(agent, "the new coordinator"),
         :ok <- check_dm_member(channel, agent) do
      if run.coordinator_agent_id == agent.id do
        {:ok, preload(run), :unchanged}
      else
        unless Channels.member?(channel, agent), do: Channels.add_agent(channel, agent)
        do_reassign(run, agent, by)
      end
    end
  end

  defp do_reassign(run, agent, by) do
    result =
      transition(run, fn run ->
        with :ok <- check_live(run) do
          multi =
            Multi.new()
            |> update_run(run, %{
              coordinator_agent_id: agent.id,
              last_activity_at: DateTime.utc_now(),
              nudged_at: nil
            })
            |> Timeline.multi_record(:event, fn _ ->
              event(run, agent.id, "playbook_coordinator_changed", %{
                "from_agent_id" => run.coordinator_agent_id,
                "to_agent_id" => agent.id,
                "by" => by
              })
            end)

          {:ok, multi, :reassigned}
        end
      end)

    with {:ok, run, :reassigned} <- result do
      if by == "user" and run.status == "active", do: wake_reassigned(run)
      result
    end
  end

  defp check_dm_member(channel, agent) do
    if Channels.dm?(channel) and not Channels.member?(channel, agent),
      do: {:error, "a DM keeps its agents: @#{agent.name} is not in this one"},
      else: :ok
  end

  defp wake_reassigned(run) do
    step = current_step(run)

    section =
      with {:ok, definition} <- Playbooks.definition(run),
           %Step{} <- step do
        Definition.step_section(definition, step.step_id)
      else
        _ -> nil
      end

    wake(
      run,
      Prompts.playbook_reassigned(%{
        channel: run.channel.name,
        playbook: run.playbook_name,
        run_id: run.id,
        brief: run.brief,
        step: step && step.step_id,
        title: step && step.title,
        position: step && step.position,
        total: length(run.steps),
        owners: if(step && step.owner_ids != [], do: owner_names(step), else: []),
        section: section
      }),
      reset: true
    )
  end

  @doc """
  Adds to an accepted handoff's transaction: when the handoff comes from the
  coordinator of the channel's run in progress, the role moves to its target
  in the same commit, or, when the target cannot coordinate (deactivated),
  a timeline line says the run stays with its coordinator. Returns the multi;
  after commit, pass `changes.playbook_follow` to `after_follow/1`.
  """
  def follow_handoff_multi(multi, %{channel_id: channel_id, from_agent_id: from, to_agent_id: to}) do
    Multi.run(multi, :playbook_follow, fn repo, _ ->
      with true <- is_binary(from) and is_binary(to),
           %Run{coordinator_agent_id: ^from} = run <- repo.one(live_query(channel_id)) do
        follow(repo, run, from, repo.get(Agent, to))
      else
        _ -> {:ok, nil}
      end
    end)
  end

  defp follow(repo, run, from, %Agent{active: true} = agent) do
    with {:ok, moved} <-
           run
           |> run_update(%{
             coordinator_agent_id: agent.id,
             last_activity_at: DateTime.utc_now(),
             nudged_at: nil
           })
           |> repo.update(stale_error_field: :lock_version),
         {:ok, event} <-
           repo.insert(
             Timeline.Event.changeset(
               %Timeline.Event{},
               event(run, agent.id, "playbook_coordinator_changed", %{
                 "from_agent_id" => from,
                 "to_agent_id" => agent.id,
                 "by" => "handoff"
               })
             )
           ) do
      {:ok, %{run: moved, event: event}}
    end
  end

  defp follow(repo, run, from, agent) do
    reason = if agent, do: "@#{agent.name} is deactivated", else: "the new owner is gone"

    with {:ok, event} <-
           repo.insert(
             Timeline.Event.changeset(
               %Timeline.Event{},
               event(run, from, "playbook_coordinator_kept", %{
                 "from_agent_id" => from,
                 "to_agent_id" => agent && agent.id,
                 "reason" => reason
               })
             )
           ) do
      {:ok, %{run: nil, event: event}}
    end
  end

  @doc "After a handoff commits: the line, the panel, and the stall clock."
  def after_follow(nil), do: :ok

  def after_follow(%{event: event} = follow) do
    Timeline.broadcast(event)

    case follow do
      %{run: %Run{} = run} -> after_change(run)
      _ -> notify(event.channel_id)
    end
  end

  # -- Activity and stalls -----------------------------------------------------------

  @doc """
  A coordinator's turn in the channel is run activity: the stall clock
  restarts and a nudge already sent is cleared. Called by the channel server
  for every turn that starts, except the turn a nudge itself starts.
  """
  def note_coordinator_turn(channel_id, agent_id) do
    case Repo.one(
           from r in Run,
             where:
               r.channel_id == ^channel_id and r.status == "active" and
                 r.coordinator_agent_id == ^agent_id
         ) do
      nil -> :ok
      run -> touch(run)
    end
  end

  @doc "A delegation made for a step changed: activity on that step's run."
  def note_delegation(%{playbook_step_id: step_id}) when is_binary(step_id) do
    case Repo.one(
           from r in Run,
             join: s in Step,
             on: s.run_id == r.id,
             where: s.id == ^step_id and r.status == "active"
         ) do
      nil ->
        :ok

      run ->
        touch(run)
        notify(run.channel_id)
    end
  end

  def note_delegation(_delegation), do: :ok

  # Activity is not a transition: it moves the stall clock without touching
  # the version a coordinator's next transition is checked against.
  defp touch(%Run{} = run) do
    now = DateTime.utc_now()

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [last_activity_at: now, nudged_at: nil]
    )

    case StallWorker.enqueue(%{run | last_activity_at: now, nudged_at: nil}) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  @doc """
  Nudges the coordinator of a run whose current step has been quiet for its
  `stall_after`: once per stall (until activity resumes), never while the
  step waits on the user, and counted against the chatter budget like any
  agent wake. The nudge is claimed atomically: `nudged_at` is set only if
  the run is still active on the same step, with the same coordinator and
  last activity, and no nudge yet, and in the same transaction as its
  timeline line. Returns `{:nudged, run}`, `{:wait, due_at}`, or `:skip`.
  """
  def check_stall(%Run{} = run, now \\ DateTime.utc_now()) do
    run = preload(run)

    cond do
      run.status != "active" or is_nil(run.stall_after_minutes) or not is_nil(run.nudged_at) ->
        :skip

      is_nil(run.coordinator) or not run.coordinator.active or Channels.archived?(run.channel) ->
        :skip

      DateTime.compare(stall_due(run), now) == :gt ->
        {:wait, stall_due(run)}

      true ->
        nudge(run, now)
    end
  end

  @doc "When the run's current stall is due (last activity plus `stall_after`)."
  def stall_due(%{last_activity_at: at, stall_after_minutes: minutes})
      when is_integer(minutes) do
    DateTime.add(at || DateTime.utc_now(), minutes * 60, :second)
  end

  def stall_due(_run), do: nil

  defp nudge(run, now) do
    step = current_step(run)
    quiet = max(DateTime.diff(now, run.last_activity_at || now, :second), 0)

    claim =
      from(r in Run,
        where:
          r.id == ^run.id and r.status == "active" and r.current_step == ^run.current_step and
            r.coordinator_agent_id == ^run.coordinator_agent_id and is_nil(r.nudged_at) and
            r.last_activity_at == ^run.last_activity_at
      )

    Multi.new()
    |> Multi.update_all(:claim, claim, set: [nudged_at: now])
    |> Multi.run(:claimed, fn _repo, %{claim: {count, _}} ->
      if count == 1, do: {:ok, true}, else: {:error, :moved_on}
    end)
    |> Timeline.multi_record(
      :event,
      event(run, run.coordinator_agent_id, "playbook_stalled", %{
        "step" => step && step.step_id,
        "title" => step && step.title,
        "round" => step && step.round,
        "quiet_s" => quiet
      })
    )
    |> Repo.transaction(mode: :immediate)
    |> case do
      {:ok, %{event: event}} ->
        Timeline.broadcast(event)

        wake(
          run,
          Prompts.playbook_stalled(%{
            playbook: run.playbook_name,
            run_id: run.id,
            step: step && step.step_id,
            title: step && step.title,
            duration: duration_text(quiet)
          }),
          reset: false,
          trigger: "playbook_nudge",
          check: {run.id, step && step.step_id, step && step.round}
        )

        notify(run.channel_id)
        {:nudged, get!(run.id)}

      {:error, :claimed, :moved_on, _} ->
        :skip
    end
  end

  @doc """
  Whether a nudge for `{run_id, step_id, round}` still applies: the run is
  active on that step and round. Checked just before the nudge's prompt
  goes out, so one that waited behind other turns is dropped once the run
  moved on.
  """
  def nudge_current?({run_id, step_id, round}) do
    Repo.exists?(
      from r in Run,
        join: s in Step,
        on: s.run_id == r.id and s.step_id == r.current_step,
        where:
          r.id == ^run_id and r.status == "active" and r.current_step == ^step_id and
            s.round == ^round
    )
  end

  @doc "\"45 min\", \"2 h 5 min\" for a span in seconds."
  def duration_text(seconds) when seconds < 3600, do: "#{max(div(seconds, 60), 1)} min"

  def duration_text(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if m == 0, do: "#{h} h", else: "#{h} h #{m} min"
  end

  # -- Prompt text -----------------------------------------------------------------

  @doc """
  The note appended to every prompt to the coordinator in a channel with a
  run in progress, read when the prompt goes out: where the run is and how
  to move it on. Nil for any other agent, and when there is no run.
  """
  def prompt_note(channel_id, agent_id) do
    case channel_id |> live_query() |> Repo.one() do
      %Run{coordinator_agent_id: ^agent_id} = run when is_binary(agent_id) ->
        Prompts.playbook_in_progress(note_args(preload(run)))

      _ ->
        nil
    end
  end

  defp note_args(run) do
    step = current_step(run)
    delegations = if step, do: round_delegations(step), else: []
    done = Enum.count(delegations, &(&1.status in ["completed", "failed", "cancelled"]))

    %{
      playbook: run.playbook_name,
      run_id: run.id,
      status: run.status,
      step: step && step.step_id,
      title: step && step.title,
      position: step && step.position,
      total: length(run.steps),
      round: step && step.round,
      # nobody but the coordinator: its own step
      owners: if(step && step.owner_ids != [], do: owner_names(step), else: []),
      delegations: {done, length(delegations)}
    }
  end

  @doc "The step's delegations made since it was last entered (this round's)."
  def round_delegations(%Step{delegations: delegations, started_at: started})
      when is_list(delegations) do
    Enum.filter(delegations, fn d ->
      is_nil(started) or DateTime.compare(d.inserted_at, started) != :lt
    end)
  end

  def round_delegations(_step), do: []

  defp started_args(run, definition, new?) do
    run = preload(run)
    step = current_step(run)

    starter =
      cond do
        run.started_by -> "@" <> run.started_by.name
        is_map(run.trigger) and map_size(run.trigger) > 0 -> "a GitHub watch"
        true -> "the user"
      end

    %{
      new_channel?: new?,
      starter: starter,
      channel: run.channel.name,
      playbook: run.playbook_name,
      run_id: run.id,
      brief: run.brief,
      step: step.step_id,
      title: step.title,
      owners: if(step.owner_ids == [], do: [], else: owner_names(step)),
      section: Definition.step_section(definition, step.step_id),
      guidance: Definition.guidance(definition)
    }
  end

  defp approval_args(run, step, note, what) do
    next = current_step(run)

    %{
      channel: run.channel.name,
      playbook: run.playbook_name,
      run_id: run.id,
      step: step && step.step_id,
      title: step && step.title,
      note: note,
      completed?: what == :completed,
      next: next && next.step_id
    }
  end

  @doc "The step's owners as `@name`s; the coordinator's own steps name the coordinator."
  def owner_names(%Step{owner_ids: [], owner_roles: roles}) do
    if "coordinator" in roles, do: ["the coordinator"], else: []
  end

  def owner_names(%Step{owner_ids: ids}) do
    Enum.map(ids, fn id -> "@" <> (Agents.get(id) || %{name: "agent"}).name end)
  end

  # -- Helpers -----------------------------------------------------------------------

  defp broadcast_events(changes) do
    changes
    |> Enum.filter(fn {_key, value} -> match?(%Timeline.Event{}, value) end)
    |> Enum.sort_by(fn {_key, event} -> event.id end)
    |> Enum.each(fn {_key, event} -> Timeline.broadcast(event) end)
  end

  defp after_change(%Run{} = run) do
    StallWorker.enqueue(run)
    notify(run.channel_id)
  end

  defp wake(%Run{coordinator_agent_id: nil}, _text, _opts), do: :ok

  defp wake(%Run{} = run, text, opts) do
    Runtime.wake_playbook(run.channel_id, run.coordinator_agent_id, text, opts)
  end

  defp event(run, agent_id, type, payload) do
    %{
      channel_id: run.channel_id,
      agent_id: agent_id,
      event_type: type,
      ref_id: run.id,
      payload: Map.merge(%{"run_id" => run.id, "playbook" => run.playbook_name}, payload)
    }
  end

  defp step_event(run, by, step, round, position, total, roster) do
    owner_ids =
      case step do
        %Step{owner_ids: ids} -> ids
        %{owner: roles} -> owner_ids(roles, roster)
      end

    {id, title} =
      case step do
        %Step{step_id: id, title: title} -> {id, title}
        %{id: id, title: title} -> {id, title}
      end

    event(run, by, "playbook_step_started", %{
      "step" => id,
      "title" => title,
      "round" => round,
      "position" => position,
      "total" => total,
      "owner_ids" => owner_ids
    })
  end

  defp actor_id({:agent, id}), do: id
  defp actor_id(:user), do: nil

  defp excerpt(nil), do: nil
  defp excerpt(text), do: text |> single_line() |> String.slice(0, @result_excerpt)

  defp single_line(text), do: Canopy.MCP.Format.single_line(text)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "Subscribe to `{:playbook_runs, :changed, channel_id}`."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp notify(channel_id),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:playbook_runs, :changed, channel_id})
end
