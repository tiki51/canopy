defmodule Canopy.GlobalPermissions do
  @moduledoc """
  Tools an agent may use in every channel and repository without asking: the
  permission card's **Allow globally**. One grant per (agent, tool), matched
  on the tool name alone, until it is removed on the agent's page.

  The channel server consults `match/2` when an engine asks for a permission:
  with a grant it answers the engine with Once, records a
  `permission_auto_approved` line and shows no card. Every change is
  broadcast on `"global_permissions"` as `{:global_permissions, :changed,
  agent_id}`.
  """

  import Ecto.Query, warn: false

  alias Canopy.Channels.Channel
  alias Canopy.GlobalPermissions.Grant
  alias Canopy.Repo
  alias Canopy.Timeline
  alias Ecto.Multi

  @topic "global_permissions"

  # OpenCode's repeated-call guard (a grant would switch it off for good), the
  # question tools, which are answers rather than permissions, and Codex's
  # file-change and more-access requests, which are about paths and reach
  # rather than a tool (a global grant would cover any file, any access)
  @not_grantable ~w(doom_loop askuserquestion question file_change permissions)

  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  @doc "Tells subscribers the agent's grants (or their counts) changed."
  def notify(agent_id),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:global_permissions, :changed, agent_id})

  @doc "The match key for a tool name: trimmed and downcased."
  def normalize(tool) when is_binary(tool), do: tool |> String.trim() |> String.downcase()

  @doc "Whether the permission card offers Allow globally for this permission."
  @spec grantable?(String.t() | nil) :: boolean
  def grantable?(tool) when is_binary(tool), do: normalize(tool) not in ["" | @not_grantable]
  def grantable?(_tool), do: false

  @doc """
  Grants `tool` to the agent. Idempotent: an existing grant is returned
  unchanged, with its date and counts. Options: `:channel_id`, where it was
  granted.
  """
  @spec grant(String.t(), String.t(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def grant(agent_id, tool, opts \\ []) do
    case Multi.new() |> grant_multi(agent_id, tool, opts) |> Repo.transaction() do
      {:ok, %{grant: grant}} ->
        notify(agent_id)
        {:ok, grant}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  `grant/3` as a `:grant` step in the caller's multi. The caller calls
  `notify/1` after its commit.
  """
  @spec grant_multi(Multi.t(), String.t(), String.t(), keyword()) :: Multi.t()
  def grant_multi(%Multi{} = multi, agent_id, tool, opts \\ []) do
    Multi.run(multi, :grant, fn repo, _changes ->
      attrs = %{
        agent_id: agent_id,
        tool: normalize(tool),
        label: String.trim(tool),
        channel_id: opts[:channel_id],
        granted_at: DateTime.utc_now()
      }

      # SQLite returns no row on a conflict, so the grant is read back
      with {:ok, _} <-
             repo.insert(Grant.changeset(%Grant{}, attrs),
               on_conflict: :nothing,
               conflict_target: [:agent_id, :tool]
             ) do
        {:ok, repo.get_by!(Grant, agent_id: agent_id, tool: attrs.tool)}
      end
    end)
  end

  @doc "The agent's grant for `tool`, with its channel, or nil."
  @spec get(String.t(), String.t()) :: Grant.t() | nil
  def get(agent_id, tool) when is_binary(agent_id) and is_binary(tool) do
    Grant
    |> Repo.get_by(agent_id: agent_id, tool: normalize(tool))
    |> Repo.preload(:channel)
  end

  @doc "A grant by id, or nil."
  def get_by_id(id) when is_binary(id), do: Repo.get(Grant, id)

  @doc "The agent's grants, by tool, with their channels."
  @spec list_for_agent(String.t()) :: [Grant.t()]
  def list_for_agent(agent_id) do
    Repo.all(
      from g in Grant,
        where: g.agent_id == ^agent_id,
        order_by: [asc: g.tool],
        preload: [:channel]
    )
  end

  @doc """
  The grant that covers an agent's request for `tool`, or nil. Nil for no
  agent, and for a tool that is not `grantable?/1` even when a row exists.
  """
  @spec match(String.t() | nil, String.t() | nil) :: Grant.t() | nil
  def match(agent_id, tool) when is_binary(agent_id) and is_binary(tool) do
    if grantable?(tool), do: Repo.get_by(Grant, agent_id: agent_id, tool: normalize(tool))
  end

  def match(_agent_id, _tool), do: nil

  @doc """
  Removes a grant. Returns the deleted row, with every field, so Undo can
  `restore/1` it.
  """
  @spec revoke(Grant.t() | String.t()) :: {:ok, Grant.t()} | {:error, :not_found}
  def revoke(%Grant{id: id}), do: revoke(id)

  def revoke(id) when is_binary(id) do
    with %Grant{} = grant <- Grant |> Repo.get(id) |> Repo.preload(:channel),
         {:ok, deleted} <- Repo.delete(grant, stale_error_field: :id) do
      notify(deleted.agent_id)
      {:ok, deleted}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Undoes a removal: puts back the same row (id, date, channel, counts). When
  the tool was granted again meanwhile, returns that grant. A grant whose
  channel was deleted comes back with no channel.
  """
  @spec restore(Grant.t()) :: {:ok, Grant.t()} | {:error, term()}
  def restore(%Grant{} = grant) do
    case get(grant.agent_id, grant.tool) do
      %Grant{} = existing ->
        {:ok, existing}

      nil ->
        attrs = %{
          id: grant.id,
          agent_id: grant.agent_id,
          tool: grant.tool,
          label: grant.label,
          channel_id: grant.channel_id && Repo.get(Channel, grant.channel_id) && grant.channel_id,
          granted_at: grant.granted_at,
          use_count: grant.use_count,
          last_used_at: grant.last_used_at
        }

        # a restore racing a re-grant (or another restore) keeps whichever landed
        with {:ok, _} <- Repo.insert(Grant.changeset(%Grant{}, attrs), on_conflict: :nothing) do
          notify(grant.agent_id)
          {:ok, get(grant.agent_id, grant.tool)}
        end
    end
  end

  @doc """
  Records one auto-approval: the grant's count and last use, and a
  `permission_auto_approved` line, in one transaction; then broadcasts both.
  `attrs`: `:channel_id`, `:agent_id`, `:permission`, `:patterns`, and
  optionally `:thread_id`/`:in_channel` (the turn's thread scope).
  """
  @spec record_use(Grant.t(), map()) :: {:ok, Timeline.Event.t()} | {:error, term()}
  def record_use(%Grant{} = grant, attrs) do
    case Multi.new() |> use_multi(grant, attrs) |> Repo.transaction() do
      {:ok, %{event: event}} ->
        event = Timeline.broadcast(event)
        notify(grant.agent_id)
        {:ok, event}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  The use count bump (`:use`) and the `permission_auto_approved` line
  (`:event`) as steps in the caller's multi. `:request_id` in `attrs` names a
  card the grant closed; the line then carries it.
  """
  @spec use_multi(Multi.t(), Grant.t(), map()) :: Multi.t()
  def use_multi(%Multi{} = multi, %Grant{} = grant, attrs) do
    now = DateTime.utc_now()

    payload =
      %{
        "permission" => attrs.permission,
        "patterns" => attrs[:patterns] || [],
        "grant_id" => grant.id
      }
      |> then(&if id = attrs[:request_id], do: Map.put(&1, "request_id", id), else: &1)

    event =
      %{
        channel_id: attrs.channel_id,
        agent_id: attrs.agent_id,
        event_type: "permission_auto_approved",
        ref_id: grant.id,
        payload: payload
      }
      |> Map.merge(Map.take(attrs, [:thread_id, :in_channel]))

    multi
    |> Multi.update_all(:use, from(g in Grant, where: g.id == ^grant.id),
      inc: [use_count: 1],
      set: [last_used_at: now, updated_at: now]
    )
    |> Timeline.multi_record(:event, event)
  end
end
