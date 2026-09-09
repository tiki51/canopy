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
    agent
    |> Ecto.Changeset.change(active: false)
    |> Repo.update()
  end

  def change(%Agent{} = agent, attrs \\ %{}), do: Agent.changeset(agent, attrs)
end
