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

    # One DM per set of agents, whichever repository it currently works in;
    # asking for it in another repository moves it there.
    list_dms()
    |> Enum.find(fn dm -> dm.agents |> Enum.map(& &1.id) |> Enum.sort() == wanted end)
    |> case do
      %Channel{repository_id: ^repository_id} = channel -> {:ok, channel}
      %Channel{} = channel -> switch_repository(channel, repository_id, "user")
      nil -> create_dm(repository_id, agents)
    end
  end

  @doc """
  Moves a DM to another repository: the conversation stays, the agents' sessions
  are recreated there on their next turn (after any turn in flight). Records
  `repository_switched`. Channels other than DMs keep their repository.
  """
  def switch_repository(%Channel{kind: "dm"} = channel, repository_id, by) do
    cond do
      channel.repository_id == repository_id ->
        {:ok, channel}

      is_nil(Repo.get(Canopy.Repositories.Repository, repository_id)) ->
        {:error, :unknown_repository}

      true ->
        from =
          channel.repository || Repo.get(Canopy.Repositories.Repository, channel.repository_id)

        to = Repo.get(Canopy.Repositories.Repository, repository_id)

        with {:ok, channel} <-
               channel |> Channel.changeset(%{repository_id: repository_id}) |> Repo.update() do
          {:ok, _} =
            Timeline.record(%{
              channel_id: channel.id,
              event_type: "repository_switched",
              ref_id: channel.id,
              payload: %{"from" => from && from.name, "to" => to.name, "by" => by}
            })

          # with no runtime for the channel, nothing defers the reset
          if is_nil(Canopy.Runtime.Supervisor.whereis(channel.id)),
            do:
              Enum.each(
                Canopy.AgentSessions.list_for_channel(channel.id),
                &Canopy.AgentSessions.delete/1
              )

          notify()
          {:ok, Repo.preload(channel, @preloads, force: true)}
        end
    end
  end

  def switch_repository(%Channel{}, _repository_id, _by), do: {:error, :not_a_dm}

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

  @doc """
  Sets or clears (nil) the total dollars a channel may spend, and records
  `spend_limit_changed`. Only the user calls this: agents can set a limit when
  they create a channel, never change one. `by` is "user" or an agent name.
  """
  def set_spend_limit(%Channel{} = channel, limit, by \\ "user") do
    limit = normalize_limit(limit)

    with {:ok, updated} <-
           channel |> Channel.changeset(%{spend_limit: limit}) |> Repo.update() do
      if updated.spend_limit != channel.spend_limit do
        {:ok, _} =
          Timeline.record(%{
            channel_id: channel.id,
            event_type: "spend_limit_changed",
            ref_id: channel.id,
            payload: %{"limit" => updated.spend_limit, "by" => by}
          })

        notify()
      end

      {:ok, Repo.preload(updated, @preloads, force: true)}
    end
  end

  defp normalize_limit(nil), do: nil
  defp normalize_limit(""), do: nil
  defp normalize_limit(n) when is_number(n), do: n / 1

  defp normalize_limit(text) when is_binary(text) do
    case text |> String.trim() |> String.trim_leading("$") |> Float.parse() do
      {n, _} -> n
      :error -> text
    end
  end

  @doc "The channel's spend limit as stored now (nil for none), without the rest of the row."
  def spend_limit(channel_id) when is_binary(channel_id) do
    Repo.one(from(c in Channel, where: c.id == ^channel_id, select: c.spend_limit))
  end

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

      case status do
        "archived" -> Canopy.Schedules.pause_for_channel(channel.id, "the channel was archived")
        "open" -> Canopy.Schedules.resume_for_channel(channel.id)
      end

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
