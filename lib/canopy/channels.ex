defmodule Canopy.Channels do
  @moduledoc """
  Channels, their memberships, and ownership. `create/1` writes the channel, its
  task, and its memberships in one transaction.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents
  alias Canopy.Agents.Agent
  alias Canopy.Channels.{Channel, ChannelAgent}
  alias Canopy.Repo
  alias Canopy.Tasks.Task
  alias Canopy.Timeline
  alias Ecto.Multi

  @preloads [:repository, :owner, :task, agents: from(a in Agent, order_by: a.name)]

  def list_by_repository(repository_id) do
    Repo.all(
      from c in Channel,
        where: c.repository_id == ^repository_id,
        order_by: [asc: c.status, asc: c.name],
        preload: ^@preloads
    )
  end

  def list do
    Repo.all(from c in Channel, order_by: [asc: c.name], preload: ^@preloads)
  end

  def get!(id), do: Channel |> Repo.get!(id) |> Repo.preload(@preloads)

  def get(id), do: Channel |> Repo.get(id) |> Repo.preload(@preloads)

  @doc "Finds a channel by slug within a repository; a leading `#` is ignored."
  def get_by_name(repository_id, name) when is_binary(name) do
    name = name |> String.trim() |> String.trim_leading("#") |> String.downcase()

    Channel
    |> Repo.get_by(repository_id: repository_id, name: name)
    |> Repo.preload(@preloads)
  end

  @doc """
  Creates a channel with its task row and memberships.

  Accepted attrs: `:repository_id`, `:name`, `:topic`, `:owner_agent_id`,
  `:agent_ids` (members; the owner is always added), `:task_title`,
  `:task_description`. The task title defaults to the topic, then the name.
  """
  def create(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_atom_key(k), v} end)
    owner_id = attrs[:owner_agent_id]

    member_ids =
      (List.wrap(attrs[:agent_ids]) ++ List.wrap(owner_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Multi.new()
    |> Multi.insert(:channel, Channel.changeset(%Channel{}, attrs))
    |> Multi.insert(:task, fn %{channel: channel} ->
      Task.changeset(%Task{}, %{
        channel_id: channel.id,
        owner_agent_id: owner_id,
        title: attrs[:task_title] || attrs[:topic] || channel.name,
        description: attrs[:task_description]
      })
    end)
    |> Multi.run(:memberships, fn _repo, %{channel: channel} ->
      with {:ok, _} <- check_agents_exist(member_ids) do
        Enum.reduce_while(member_ids, {:ok, []}, fn agent_id, {:ok, acc} ->
          case insert_membership(channel.id, agent_id) do
            {:ok, membership} -> {:cont, {:ok, [membership | acc]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{channel: channel}} ->
        notify()
        {:ok, get!(channel.id)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @topic "channels"

  @doc "Subscribe to `{:channels, :changed}`, sent when a channel is created, archived, or reopened."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp notify, do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:channels, :changed})

  @doc """
  The direct-message channel between the user and one or more agents in a
  repository, created on first use and found by its exact set of agents after
  that. DMs are ordinary channels with `kind: "dm"`: the first agent given owns
  it and all of them are members, so routing and the runtime treat a DM like any
  other channel. The user is always in a DM; there is no agent-only DM.
  """
  def ensure_dm(repository_id, %Agent{} = agent), do: ensure_dm(repository_id, [agent])

  def ensure_dm(repository_id, [%Agent{} | _] = agents) do
    agents = Enum.uniq_by(agents, & &1.id)
    wanted = agents |> Enum.map(& &1.id) |> Enum.sort()

    repository_id
    |> list_dms()
    |> Enum.find(fn dm -> dm.agents |> Enum.map(& &1.id) |> Enum.sort() == wanted end)
    |> case do
      %Channel{} = channel -> {:ok, channel}
      nil -> create_dm(repository_id, agents)
    end
  end

  @doc "All DMs, newest first; scoped to a repository when given."
  def list_dms(repository_id \\ nil) do
    query = from c in Channel, where: c.kind == "dm", order_by: [desc: c.inserted_at]

    query =
      if repository_id, do: where(query, [c], c.repository_id == ^repository_id), else: query

    Repo.all(from c in query, preload: ^@preloads)
  end

  @doc ~S|"@backend, @reviewer": the agents of a DM, for titles and the sidebar.|
  def dm_label(%Channel{agents: agents}) when is_list(agents) and agents != [],
    do: Enum.map_join(agents, ", ", &("@" <> &1.name))

  def dm_label(%Channel{owner: %Agent{name: name}}), do: "@" <> name
  def dm_label(%Channel{name: name}), do: name

  defp create_dm(repository_id, [owner | _] = agents) do
    names = agents |> Enum.map(& &1.name) |> Enum.sort()
    base = String.slice("dm-" <> Enum.join(names, "-"), 0, 52)
    label = Enum.map_join(names, ", ", &("@" <> &1))

    name =
      if Repo.exists?(
           from c in Channel, where: c.repository_id == ^repository_id and c.name == ^base
         ),
         do:
           base <>
             "-" <> Base.encode32(:crypto.strong_rand_bytes(3), case: :lower, padding: false),
         else: base

    create(%{
      repository_id: repository_id,
      name: name,
      kind: "dm",
      owner_agent_id: owner.id,
      agent_ids: Enum.map(agents, & &1.id),
      topic: "Direct messages with #{label}",
      task_title: "Direct messages with #{label}"
    })
  end

  @doc "True for a direct-message channel."
  def dm?(%Channel{kind: "dm"}), do: true
  def dm?(_), do: false

  @doc "The repository id of a channel, or nil when it does not exist."
  def repository_id(id) when is_binary(id),
    do: Repo.one(from c in Channel, where: c.id == ^id, select: c.repository_id)

  @doc "Archives a channel and records `channel_archived`. Archiving twice is a no-op."
  def archive(%Channel{status: "archived"} = channel), do: {:ok, Repo.preload(channel, @preloads)}

  def archive(%Channel{} = channel), do: set_status(channel, "archived", "channel_archived")

  @doc "Reopens an archived channel and records `channel_reopened`."
  def reopen(%Channel{status: "open"} = channel), do: {:ok, Repo.preload(channel, @preloads)}

  def reopen(%Channel{} = channel), do: set_status(channel, "open", "channel_reopened")

  def archived?(%Channel{status: "archived"}), do: true
  def archived?(_), do: false

  defp set_status(channel, status, event_type) do
    with {:ok, channel} <- channel |> Ecto.Changeset.change(status: status) |> Repo.update() do
      {:ok, _} =
        Timeline.record(%{
          channel_id: channel.id,
          event_type: event_type,
          ref_id: channel.id,
          payload: %{}
        })

      notify()
      {:ok, Repo.preload(channel, @preloads, force: true)}
    end
  end

  def update(%Channel{} = channel, attrs) do
    attrs = Map.drop(Map.new(attrs), [:repository_id, "repository_id"])

    with {:ok, channel} <- channel |> Channel.changeset(attrs) |> Repo.update() do
      notify()
      {:ok, Repo.preload(channel, @preloads, force: true)}
    end
  end

  @doc """
  Adds an agent to a channel and records `member_added` on the timeline.
  Idempotent: adding a member again records nothing.
  """
  def add_agent(channel, agent) do
    channel_id = id_of(channel)
    agent_id = id_of(agent)

    with {:ok, _} <- check_agents_exist([agent_id]) do
      if member?(channel_id, agent_id) do
        {:ok, :already_member}
      else
        with {:ok, membership} <- insert_membership(channel_id, agent_id) do
          record_membership(channel_id, agent_id, "member_added")
          {:ok, membership}
        end
      end
    end
  end

  @doc """
  Removes an agent from a channel and records `member_removed`. The owner cannot
  be removed; hand the task off first. Returns the number of rows removed.
  """
  def remove_agent(channel, agent) do
    channel_id = id_of(channel)
    agent_id = id_of(agent)

    if owner_id(channel) == agent_id do
      {:error, :owner}
    else
      {count, _} =
        Repo.delete_all(
          from m in ChannelAgent, where: m.channel_id == ^channel_id and m.agent_id == ^agent_id
        )

      if count > 0, do: record_membership(channel_id, agent_id, "member_removed")
      {:ok, count}
    end
  end

  defp owner_id(%Channel{owner_agent_id: id}), do: id

  defp owner_id(channel_id) when is_binary(channel_id),
    do: Repo.one(from c in Channel, where: c.id == ^channel_id, select: c.owner_agent_id)

  defp record_membership(channel_id, agent_id, type) do
    {:ok, _} =
      Timeline.record(%{
        channel_id: channel_id,
        agent_id: agent_id,
        event_type: type,
        ref_id: agent_id,
        payload: %{"agent_id" => agent_id}
      })
  end

  @doc "Agents that could be added to the channel: active ones not already members."
  def addable_agents(channel) do
    member_ids = channel |> members() |> MapSet.new(& &1.id)
    Enum.reject(Agents.list_active(), &MapSet.member?(member_ids, &1.id))
  end

  def member?(channel, agent) do
    channel_id = id_of(channel)
    agent_id = id_of(agent)

    Repo.exists?(
      from m in ChannelAgent, where: m.channel_id == ^channel_id and m.agent_id == ^agent_id
    )
  end

  @doc "Returns the member agents of a channel, ordered by name."
  def members(channel) do
    channel_id = id_of(channel)

    Repo.all(
      from a in Agent,
        join: m in ChannelAgent,
        on: m.agent_id == a.id,
        where: m.channel_id == ^channel_id,
        order_by: [asc: a.name]
    )
  end

  @doc """
  Changes the channel owner and records an `owner_changed` event. `agent` may be
  nil to clear the owner. Passing the current owner is a no-op.
  """
  def set_owner(%Channel{} = channel, agent) do
    new_owner_id = if is_nil(agent), do: nil, else: id_of(agent)
    previous_owner_id = channel.owner_agent_id

    if new_owner_id == previous_owner_id do
      {:ok, Repo.preload(channel, @preloads)}
    else
      Multi.new()
      |> Multi.update(:channel, Channel.changeset(channel, %{owner_agent_id: new_owner_id}))
      |> Timeline.multi_record(:event, %{
        channel_id: channel.id,
        agent_id: new_owner_id,
        event_type: "owner_changed",
        ref_id: channel.id,
        payload: %{"from_agent_id" => previous_owner_id, "to_agent_id" => new_owner_id}
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{channel: channel, event: event}} ->
          Timeline.broadcast(event)
          {:ok, Repo.preload(channel, @preloads, force: true)}

        {:error, _step, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  def change(%Channel{} = channel, attrs \\ %{}), do: Channel.changeset(channel, attrs)

  # SQLite reports foreign key failures without a constraint name, which makes
  # Ecto raise instead of returning a changeset error, so check ids up front.
  defp check_agents_exist(agent_ids) do
    known = Repo.all(from a in Agent, where: a.id in ^agent_ids, select: a.id)

    case agent_ids -- known do
      [] ->
        {:ok, []}

      [missing | _] ->
        changeset =
          %ChannelAgent{}
          |> ChannelAgent.changeset(%{agent_id: missing})
          |> Ecto.Changeset.add_error(:agent_id, "does not exist")

        {:error, changeset}
    end
  end

  defp insert_membership(channel_id, agent_id) do
    %ChannelAgent{}
    |> ChannelAgent.changeset(%{channel_id: channel_id, agent_id: agent_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:channel_id, :agent_id])
  end

  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when is_binary(key), do: String.to_existing_atom(key)
end
