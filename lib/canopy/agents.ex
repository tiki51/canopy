defmodule Canopy.Agents do
  @moduledoc "Canopy agents: a name, a role prompt, and the OpenCode agent to run as."

  import Ecto.Query, warn: false

  alias Canopy.Agents.Agent
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
        set: [engine: to_engine, model_provider: nil, updated_at: DateTime.utc_now()]
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
