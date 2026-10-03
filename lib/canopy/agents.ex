defmodule Canopy.Agents do
  @moduledoc "Canopy agents: a name, a role prompt, and the OpenCode agent to run as."

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

  # -- Models and defaults ------------------------------------------------------

  @doc """
  The model the agent runs on, and where the choice came from: its own model
  (`:agent`), else its engine's default from Settings (`:default`), else nils
  (`:engine`: no model is sent and the engine picks). The agent's own fields
  are never rewritten; nil keeps meaning "inherit".
  """
  def effective_model(%{engine: engine} = agent, setting \\ nil) do
    case agent do
      %{model_id: model} when is_binary(model) and model != "" ->
        %{model_provider: agent.model_provider, model_id: model, source: :agent}

      _ ->
        case Settings.default_model(engine, setting) do
          %{model_id: model} = default when is_binary(model) ->
            Map.put(default, :source, :default)

          _ ->
            %{model_provider: nil, model_id: nil, source: :engine}
        end
    end
  end

  @doc """
  The effort the agent runs at, as `%{effort: e, source: s}`, resolved like
  `effective_model/1`: its own, else the engine's default, else nil (the
  engine picks; OpenCode has no effort setting).
  """
  def effective_effort(%{engine: engine} = agent, setting \\ nil) do
    case Map.get(agent, :effort) do
      effort when is_binary(effort) and effort != "" ->
        %{effort: effort, source: :agent}

      _ ->
        case Settings.default_effort(engine, setting) do
          effort when is_binary(effort) -> %{effort: effort, source: :default}
          _ -> %{effort: nil, source: :engine}
        end
    end
  end

  # -- Model routing (experimental) ---------------------------------------------

  @doc """
  The model and effort a wake runs on, per profile, as
  `%{model_provider, model_id, effort, source}`.

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

  def effective_profile(%{engine: _} = agent, :main, setting) do
    model = effective_model(agent, setting)
    %{effort: effort} = effective_effort(agent, setting)

    %{
      model_provider: model.model_provider,
      model_id: model.model_id,
      effort: effort,
      source: model.source
    }
  end

  def effective_profile(%{engine: engine} = agent, :light, setting) do
    setting = setting || Settings.get()
    default = Settings.light_profile(engine, setting)
    # only Claude Code has an effort setting; OpenCode routes the model only
    efforts? = engine == "claude_code"

    own_model = present(Map.get(agent, :light_model_id))
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

  @doc "Active agents of an engine that inherit its default model (`:default`) or name their own (`:own`)."
  def model_usage(engine), do: usage(engine, :model_id)

  @doc "Active agents of an engine that inherit its default effort (`:default`) or set their own (`:own`)."
  def effort_usage(engine), do: usage(engine, :effort)

  defp usage(engine, field) do
    counts =
      Repo.all(
        from a in Agent,
          where: a.engine == ^engine and a.active == true,
          group_by: is_nil(field(a, ^field)),
          select: {is_nil(field(a, ^field)), count(a.id)}
      )
      |> Map.new()

    %{default: Map.get(counts, true, 0), own: Map.get(counts, false, 0)}
  end

  @doc """
  Puts every active agent of the engine on its default model by clearing
  their own. Returns how many changed. Only ever runs when the user asks.
  """
  def inherit_default_model(engine),
    do: inherit(engine, :model_id, model_provider: nil, model_id: nil)

  @doc "Puts every active agent of the engine on its default effort. Returns how many changed."
  def inherit_default_effort(engine), do: inherit(engine, :effort, effort: nil)

  @doc """
  How many active agents among `names` are still on `engine` with no model of
  their own: the ones `move_to_engine/3` would move from it.
  """
  def movable_count(names, engine) when is_list(names) and is_binary(engine),
    do: Repo.aggregate(movable(names, engine), :count)

  @doc """
  Moves the active agents among `names` that are still on `from_engine` with
  no model of their own to `to_engine`, where they inherit its default model
  and effort. Agents the user configured are left alone. Returns how many moved.
  """
  def move_to_engine(names, from_engine, to_engine) when is_list(names) do
    true = to_engine in Canopy.Engine.names()

    {count, _} =
      Repo.update_all(movable(names, from_engine),
        # a light model belongs to the old engine too
        set: [
          engine: to_engine,
          model_provider: nil,
          light_model_provider: nil,
          light_model_id: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0, do: Settings.broadcast_defaults_changed()

    {:ok, count}
  end

  defp movable(names, engine) do
    from a in Agent,
      where: a.name in ^names and a.engine == ^engine and a.active == true and is_nil(a.model_id)
  end

  defp inherit(engine, field, set) do
    {count, _} =
      Repo.update_all(
        from(a in Agent,
          where: a.engine == ^engine and a.active == true and not is_nil(field(a, ^field))
        ),
        set: set ++ [updated_at: DateTime.utc_now()]
      )

    if count > 0, do: Settings.broadcast_defaults_changed()

    {:ok, count}
  end
end
