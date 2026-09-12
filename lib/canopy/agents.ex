defmodule Canopy.Agents do
  @moduledoc "Canopy agents: a name, a role prompt, and the OpenCode agent to run as."

  import Ecto.Query, warn: false

  alias Canopy.Agents.Agent
  alias Canopy.Repo

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
end
