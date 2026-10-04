defmodule Canopy.Agents do
  @moduledoc """
  Canopy agents: a name, a role prompt, the engine that runs them (their own,
  or the default engine from Settings), and that engine's settings.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents.{Agent, RoutingPause}
  alias Canopy.{Repo, Settings}

  def list do
    Repo.all(from a in Agent, order_by: [asc: a.name])
  end

  def list_active do
    Repo.all(from a in Agent, where: a.active == true, order_by: [asc: a.name])
  end

  @doc "Distinct group labels in use, alphabetical."
  def groups do
    Repo.all(
      from a in Agent,
        where: not is_nil(a.group),
        distinct: true,
        order_by: a.group,
        select: a.group
    )
  end

  @doc """
  Splits agents into `[{group, agents}]` for display: groups alphabetically,
  agents in their given order, the ungrouped last under `nil`. When no agent
  has a group the single entry is `{nil, agents}`.
  """
  def grouped(agents) when is_list(agents) do
    {grouped, loose} = Enum.split_with(agents, &is_binary(&1.group))

    groups =
      grouped
      |> Enum.group_by(& &1.group)
      |> Enum.sort_by(fn {group, _} -> String.downcase(group) end)

    if loose == [], do: groups, else: groups ++ [{nil, loose}]
  end

  def get!(id), do: Repo.get!(Agent, id)

  def get(id), do: Repo.get(Agent, id)

  @doc "Finds an agent by slug; a leading `@` is ignored."
  def get_by_name(name) when is_binary(name) do
    name = name |> String.trim() |> String.trim_leading("@") |> String.downcase()
    Repo.get_by(Agent, name: name)
  end

  @doc "Returns `%{name => id}` for the given names (missing names are absent)."
  def ids_by_names(names) when is_list(names) do
    Repo.all(from a in Agent, where: a.name in ^names, select: {a.name, a.id})
    |> Map.new()
  end

  def create(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def update(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def deactivate(%Agent{} = agent) do
    with {:ok, agent} <- agent |> Ecto.Changeset.change(active: false) |> Repo.update() do
      Canopy.Schedules.pause_for_agent(agent.id, "@#{agent.name} was deactivated")
      Canopy.Locks.release_agent(agent.id, "@#{agent.name} was deactivated")
      {:ok, agent}
    end
  end

  def change(%Agent{} = agent, attrs \\ %{}), do: Agent.changeset(agent, attrs)

  # -- Engines, models and defaults ----------------------------------------------

  @doc """
  The engine the agent runs on: its own, else the default engine from
  Settings (`Canopy.Settings.default_engine/1`, never nil). Like a blank
  model, a nil engine means "follow the default"; it is never rewritten.
  Accepts plain maps (no `engine` key reads as the default too).
  """
  def effective_engine(agent, setting \\ nil) do
    case Map.get(agent, :engine) do
      engine when is_binary(engine) and engine != "" -> engine
      _ -> Settings.default_engine(setting)
    end
  end

  @doc """
  The model the agent runs on, and where the choice came from: its own model
  (`:agent`), else its engine's default from Settings (`:default`), else nils
  (`:engine`: no model is sent and the engine picks). The agent's own fields
  are never rewritten; nil keeps meaning "inherit". A model of its own that
  its effective engine cannot run (left from another engine, when the default
  engine changed under it) is passed over for the default, without being
  cleared, so switching back restores it.
  """
  def effective_model(agent, setting \\ nil) do
    setting = setting || Settings.get()
    engine = effective_engine(agent, setting)
    provider = Map.get(agent, :model_provider)

    case Map.get(agent, :model_id) do
      model when is_binary(model) and model != "" ->
        if fits?(engine, provider, model),
          do: %{model_provider: provider, model_id: model, source: :agent},
          else: default_model(engine, setting)

      _ ->
        default_model(engine, setting)
    end
  end

  defp default_model(engine, setting) do
    case Settings.default_model(engine, setting) do
      %{model_id: model} = default when is_binary(model) ->
        Map.put(default, :source, :default)

      _ ->
        %{model_provider: nil, model_id: nil, source: :engine}
    end
  end

  defp fits?(engine, provider, model), do: Agent.model_fits?(engine, provider, model)

  @doc """
  The effort the agent runs at, as `%{effort: e, source: s}`, resolved like
  `effective_model/1`: its own, else the engine's default, else nil (the
  engine picks; OpenCode has no effort setting).
  """
  def effective_effort(agent, setting \\ nil) do
    case Map.get(agent, :effort) do
      effort when is_binary(effort) and effort != "" ->
        %{effort: effort, source: :agent}

      _ ->
        setting = setting || Settings.get()

        case Settings.default_effort(effective_engine(agent, setting), setting) do
          effort when is_binary(effort) -> %{effort: effort, source: :default}
          _ -> %{effort: nil, source: :engine}
        end
    end
  end

  # -- Model routing (experimental) ---------------------------------------------

  @doc """
  The model and effort a wake runs on, per profile, as
  `%{model_provider, model_id, effort, source}`, for the agent's effective
  engine (`effective_engine/2`).

  `:main` is today's resolution: `effective_model/2` with `effective_effort/2`
  (`source` is the model's).

  `:light` is the agent's light fields, else its engine's light default from
  Settings; no third step, since the engine's own default is never a light
  model. A light profile may name only a model (the effort is then the
  engine's own pick) or only an effort (the main model is kept). It is nil
  when nothing is set, or when it comes out equal to `:main`: routing is then
  a no-op and every wake runs on main. `source` is `:agent` when any light
  field is the agent's own, else `:default`.

  Teams carry no models, so there is no team step (Model Routing plan, open
  question on team-level light models: the step would go between the agent
  and Settings, as for the main model, once teams get one).
  """
  def effective_profile(agent, profile, setting \\ nil)

  def effective_profile(agent, :main, setting) do
    model = effective_model(agent, setting)
    %{effort: effort} = effective_effort(agent, setting)

    %{
      model_provider: model.model_provider,
      model_id: model.model_id,
      effort: effort,
      source: model.source
    }
  end

  def effective_profile(agent, :light, setting) do
    setting = setting || Settings.get()
    engine = effective_engine(agent, setting)
    default = Settings.light_profile(engine, setting)
    # only Claude Code has an effort setting; OpenCode routes the model only
    efforts? = engine == "claude_code"

    # like the main model, a light model left from another engine is passed over
    own_model =
      with model when is_binary(model) <- present(Map.get(agent, :light_model_id)),
           true <- fits?(engine, Map.get(agent, :light_model_provider), model) do
        model
      else
        _ -> nil
      end

    own_effort = efforts? && present(Map.get(agent, :light_effort))

    {provider, model} =
      if own_model,
        do: {Map.get(agent, :light_model_provider), own_model},
        else: {default.model_provider, default.model_id}

    effort = own_effort || (efforts? && default.effort) || nil

    if is_nil(model) and is_nil(effort) do
      nil
    else
      main = effective_profile(agent, :main, setting)
      main = if efforts?, do: main, else: %{main | effort: nil}

      light =
        if model,
          do: %{model_provider: provider, model_id: model, effort: effort},
          else: %{model_provider: main.model_provider, model_id: main.model_id, effort: effort}

      if Map.take(main, [:model_provider, :model_id, :effort]) == light,
        do: nil,
        else: Map.put(light, :source, if(own_model || own_effort, do: :agent, else: :default))
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc "Whether wakes of the agent may run on a light profile: routing is on and one resolves."
  def routed?(agent, setting \\ nil),
    do:
      Map.get(agent, :routing_enabled) == true and
        effective_profile(agent, :light, setting) != nil

  @doc "The routing rules paused for an agent, newest first."
  def routing_pauses(agent_id) do
    Repo.all(
      from p in RoutingPause,
        where: p.agent_id == ^agent_id and not is_nil(p.paused_at),
        order_by: [desc: p.paused_at]
    )
  end

  @doc "The wake kinds paused for an agent (`\"*\"` stands for every kind)."
  def paused_kinds(agent_id) do
    agent_id |> routing_pauses() |> MapSet.new(& &1.wake_kind)
  end

  @doc """
  When the escalation window for an agent's wake kind starts: the last time
  its rule was resumed, or nil (all history).
  """
  def routing_window_start(agent_id, wake_kind) do
    Repo.one(
      from p in RoutingPause,
        where: p.agent_id == ^agent_id and p.wake_kind == ^wake_kind,
        select: p.resumed_at
    )
  end

  @doc """
  Pauses routing for an agent's `wake_kind` (`"*"` for every kind), with a
  reason the agent page shows. A rule already paused keeps its first reason.
  Broadcasts `{:settings, :light_profiles_changed}` so the pages refresh.
  """
  def pause_routing(agent_id, wake_kind, reason) when is_binary(wake_kind) do
    now = DateTime.utc_now()

    result =
      case Repo.get_by(RoutingPause, agent_id: agent_id, wake_kind: wake_kind) do
        %RoutingPause{paused_at: %DateTime{}} = paused ->
          {:ok, paused}

        %RoutingPause{} = resumed ->
          resumed
          |> Ecto.Changeset.change(paused_at: now, reason: reason)
          |> Repo.update()

        nil ->
          %RoutingPause{agent_id: agent_id, wake_kind: wake_kind, reason: reason, paused_at: now}
          |> Repo.insert()
      end

    with {:ok, _} <- result, do: broadcast_routing_changed()
    result
  end

  @doc """
  Resumes a paused rule. The row stays with `resumed_at`, so the escalation
  window that decides the next pause starts now. `{:error, :not_paused}`
  when there was nothing to resume.
  """
  def resume_routing(agent_id, wake_kind) do
    case Repo.get_by(RoutingPause, agent_id: agent_id, wake_kind: wake_kind) do
      %RoutingPause{paused_at: %DateTime{}} = pause ->
        result =
          pause
          |> Ecto.Changeset.change(paused_at: nil, resumed_at: DateTime.utc_now())
          |> Repo.update()

        with {:ok, _} <- result, do: broadcast_routing_changed()
        result

      _ ->
        {:error, :not_paused}
    end
  end

  defp broadcast_routing_changed,
    do:
      Phoenix.PubSub.broadcast(
        Canopy.PubSub,
        Settings.topic(),
        {:settings, :light_profiles_changed}
      )

  @doc """
  Active agents that follow the default engine (`:default`) or name their
  own (`:own`).
  """
  def engine_usage do
    counts =
      Repo.all(
        from a in Agent,
          where: a.active == true,
          group_by: is_nil(a.engine),
          select: {is_nil(a.engine), count(a.id)}
      )
      |> Map.new()

    %{default: Map.get(counts, true, 0), own: Map.get(counts, false, 0)}
  end

  @doc """
  Puts every active agent on the default engine by clearing its own. An
  agent that changes engine this way loses its model and light model, as
  switching engine on its form does (a model belongs to one engine); one
  already on the default's engine keeps them. Each keeps its reach on both
  engines (read-only stays read-only). Returns how many changed. Only ever
  runs when the user asks.
  """
  def inherit_default_engine do
    default = Settings.default_engine()
    now = DateTime.utc_now()
    agents = Repo.all(from a in Agent, where: a.active == true and not is_nil(a.engine))

    {:ok, _} =
      Repo.transaction(fn ->
        for agent <- agents do
          agent
          |> Ecto.Changeset.change(inherit_engine_changes(agent, default))
          |> Ecto.Changeset.put_change(:updated_at, now)
          |> Repo.update!()
        end
      end)

    count = length(agents)
    if count > 0, do: Settings.broadcast_defaults_changed()

    {:ok, count}
  end

  # The agent's own engine cleared, with its reach written to both engines'
  # fields (as the agent changeset keeps them for agents on the default), and
  # its models dropped when it changes engine.
  defp inherit_engine_changes(agent, default) do
    reach =
      case Agent.execution_mode(agent) do
        :plan ->
          [opencode_agent: "plan", permission_mode: "plan"]

        :build ->
          [
            opencode_agent:
              if(agent.opencode_agent == "plan", do: "build", else: agent.opencode_agent),
            permission_mode:
              if(agent.permission_mode == "plan", do: "default", else: agent.permission_mode)
          ]

        nil ->
          []
      end

    models =
      if agent.engine == default,
        do: [],
        else: [model_provider: nil, model_id: nil, light_model_provider: nil, light_model_id: nil]

    [engine: nil] ++ reach ++ models
  end

  @doc """
  Active agents running on `engine` (their own, or the default) that inherit
  its default model (`:default`) or name their own (`:own`). A model left
  from another engine counts as inheriting, since it is passed over.
  """
  def model_usage(engine) do
    setting = Settings.get()

    engine
    |> active_on(setting)
    |> Enum.frequencies_by(
      &if(effective_model(&1, setting).source == :agent, do: :own, else: :default)
    )
    |> usage_counts()
  end

  @doc "Active agents running on `engine` that inherit its default effort (`:default`) or set their own (`:own`)."
  def effort_usage(engine) do
    engine
    |> active_on(Settings.get())
    |> Enum.frequencies_by(&if(is_nil(&1.effort), do: :default, else: :own))
    |> usage_counts()
  end

  defp usage_counts(frequencies),
    do: %{default: Map.get(frequencies, :default, 0), own: Map.get(frequencies, :own, 0)}

  # The active agents whose effective engine is `engine`.
  defp active_on(engine, setting) do
    default? = Settings.default_engine(setting) == engine

    Repo.all(
      from a in Agent,
        where: a.active == true and (a.engine == ^engine or (^default? and is_nil(a.engine)))
    )
  end

  @doc """
  Puts every active agent running on the engine on its default model by
  clearing their own. Returns how many changed. Only ever runs when the user asks.
  """
  def inherit_default_model(engine),
    do: inherit(engine, :model_id, model_provider: nil, model_id: nil)

  @doc "Puts every active agent running on the engine on its default effort. Returns how many changed."
  def inherit_default_effort(engine), do: inherit(engine, :effort, effort: nil)

  defp inherit(engine, field, set) do
    ids =
      engine
      |> active_on(Settings.get())
      |> Enum.reject(&is_nil(Map.fetch!(&1, field)))
      |> Enum.map(& &1.id)

    {count, _} =
      Repo.update_all(
        from(a in Agent, where: a.id in ^ids),
        set: set ++ [updated_at: DateTime.utc_now()]
      )

    if count > 0, do: Settings.broadcast_defaults_changed()

    {:ok, count}
  end
end
