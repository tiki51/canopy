defmodule Canopy.Teams do
  @moduledoc """
  Teams: named crews of agents, addressable as `@name` wherever agents are
  named. Only the user creates and edits them. A team stands for its active
  members at the moment it is used: adding one to a channel copies those
  members in, and a mention expands to them when the message is saved.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents.Agent
  alias Canopy.Repo
  alias Canopy.Teams.{Team, TeamMember}
  alias Ecto.Multi

  @preloads [:lead, members: from(a in Agent, order_by: a.name)]

  def list, do: Repo.all(from t in Team, order_by: [asc: t.name], preload: ^@preloads)

  def get!(id), do: Team |> Repo.get!(id) |> Repo.preload(@preloads)

  def get(id), do: Team |> Repo.get(id) |> Repo.preload(@preloads)

  @doc "Finds a team by slug; a leading `@` is ignored."
  def get_by_name(name) when is_binary(name) do
    name = name |> String.trim() |> String.trim_leading("@") |> String.downcase()
    Team |> Repo.get_by(name: name) |> Repo.preload(@preloads)
  end

  @doc "Every team name, alphabetical: what the composer offers after `@`."
  def names, do: Repo.all(from t in Team, order_by: [asc: t.name], select: t.name)

  @doc """
  Creates a team. `attrs` carries the team fields and `agent_ids`, the member
  set; the lead must be one of them.
  """
  def create(attrs), do: save(%Team{}, attrs)

  @doc """
  Updates a team; `agent_ids`, when given, replaces the member set in the
  same transaction.
  """
  def update(%Team{} = team, attrs), do: save(team, attrs)

  def delete(%Team{} = team) do
    with {:ok, team} <- Repo.delete(team) do
      notify()
      {:ok, team}
    end
  end

  @doc "A changeset for forms. Without `agent_ids` in `attrs`, the current members count."
  def change(%Team{} = team, attrs \\ %{}) do
    member_ids =
      if has_member_ids?(attrs), do: member_ids(attrs), else: current_member_ids(team)

    Team.changeset(team, attrs, member_ids)
  end

  defp save(team, attrs) do
    member_ids =
      if has_member_ids?(attrs), do: member_ids(attrs), else: current_member_ids(team)

    Multi.new()
    |> Multi.insert_or_update(:team, Team.changeset(team, attrs, member_ids))
    |> Multi.run(:members, fn repo, %{team: team} ->
      replace_members(repo, team.id, member_ids)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{team: team}} ->
        notify()
        {:ok, get!(team.id)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Members kept keep their row (and role); the rest are removed, new ones added.
  defp replace_members(repo, team_id, member_ids) do
    {_, _} =
      repo.delete_all(
        from m in TeamMember, where: m.team_id == ^team_id and m.agent_id not in ^member_ids
      )

    now = DateTime.utc_now()
    rows = Enum.map(member_ids, &%{team_id: team_id, agent_id: &1, inserted_at: now})
    {count, _} = repo.insert_all(TeamMember, rows, on_conflict: :nothing)
    {:ok, count}
  end

  defp has_member_ids?(attrs),
    do: Map.has_key?(attrs, "agent_ids") or Map.has_key?(attrs, :agent_ids)

  # Only ids of agents that exist count, in the order given.
  defp member_ids(attrs) do
    ids =
      (Map.get(attrs, "agent_ids") || Map.get(attrs, :agent_ids) || [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    known = MapSet.new(Repo.all(from a in Agent, where: a.id in ^ids, select: a.id))
    Enum.filter(ids, &MapSet.member?(known, &1))
  end

  defp current_member_ids(%Team{id: nil}), do: []

  defp current_member_ids(%Team{id: id}),
    do: Repo.all(from m in TeamMember, where: m.team_id == ^id, select: m.agent_id)

  @doc "The team's active members, by name. An inactive agent stays on its teams but is skipped."
  def active_members(%Team{members: members}) when is_list(members),
    do: members |> Enum.filter(& &1.active) |> Enum.sort_by(& &1.name)

  def active_members(%Team{} = team), do: team |> Repo.preload(@preloads) |> active_members()

  @doc "The teams an agent is on, alphabetical."
  def for_agent(agent_id) when is_binary(agent_id) do
    Repo.all(
      from t in Team,
        join: m in TeamMember,
        on: m.team_id == t.id,
        where: m.agent_id == ^agent_id,
        order_by: [asc: t.name],
        preload: ^@preloads
    )
  end

  @doc "Teams that would bring someone new into the channel: at least one active non-member."
  def addable(channel) do
    member_ids = channel |> Canopy.Channels.members() |> MapSet.new(& &1.id)

    Enum.filter(list(), fn team ->
      team |> active_members() |> Enum.any?(&(not MapSet.member?(member_ids, &1.id)))
    end)
  end

  @doc """
  The names of teams whose active members are all among `member_ids` (and
  that have at least one): the teams a channel already holds whole.
  """
  def complete_in(member_ids) when is_list(member_ids) do
    present = MapSet.new(member_ids)

    list()
    |> Enum.filter(fn team ->
      case active_members(team) do
        [] -> false
        members -> Enum.all?(members, &MapSet.member?(present, &1.id))
      end
    end)
    |> Enum.map(& &1.name)
  end

  @doc """
  Expands team names for mentions and tools:
  `%{name => %{team_id: id, agent_ids: [agent_id]}}` with active members only,
  sorted by name. Names that are not teams are absent.
  """
  def expand_names([]), do: %{}

  def expand_names(names) when is_list(names) do
    Repo.all(from t in Team, where: t.name in ^names, preload: ^@preloads)
    |> Map.new(fn team ->
      {team.name, %{team_id: team.id, agent_ids: Enum.map(active_members(team), & &1.id)}}
    end)
  end

  @doc """
  Agents and teams share the `@` namespace: a team may not take an agent's
  name, nor an agent a team's. Called from both changesets; checked only when
  the name changes and is otherwise valid. Resolution prefers the agent if a
  collision slips through anyway.
  """
  def validate_name_free(%Ecto.Changeset{} = changeset) do
    name = Ecto.Changeset.get_change(changeset, :name)

    if is_binary(name) and is_nil(changeset.errors[:name]) do
      {taken?, message} =
        case changeset.data do
          %Team{} ->
            {Repo.exists?(from a in Agent, where: a.name == ^name), "is already an agent's name"}

          _agent ->
            {Repo.exists?(from t in Team, where: t.name == ^name), "is already a team's name"}
        end

      if taken?, do: Ecto.Changeset.add_error(changeset, :name, message), else: changeset
    else
      changeset
    end
  end

  @topic "teams"

  @doc "Subscribe to `{:teams, :changed}`, sent when a team is created, edited, or deleted."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp notify, do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:teams, :changed})
end
