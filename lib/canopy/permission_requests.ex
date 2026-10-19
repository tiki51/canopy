defmodule Canopy.PermissionRequests do
  @moduledoc """
  Permission prompts surfaced in the channel feed, from either engine.

  Like a question, a pending prompt blocks the agent's turn while the engine
  holds the tool call open. When the agent stops waiting the card is
  *detached*: it stays pending, and a late approval reaches the agent as a new
  message (it cannot apply to the call that was waiting).
  """

  import Ecto.Query, warn: false

  alias Canopy.GlobalPermissions
  alias Canopy.PermissionRequests.PermissionRequest
  alias Canopy.Repo
  alias Canopy.Timeline
  alias Ecto.Multi

  @preloads [agent_session: [:agent]]

  def get!(id), do: PermissionRequest |> Repo.get!(id) |> Repo.preload(@preloads)

  def get_by_opencode_id(opencode_permission_id) when is_binary(opencode_permission_id) do
    PermissionRequest
    |> Repo.get_by(opencode_permission_id: opencode_permission_id)
    |> Repo.preload(@preloads)
  end

  @doc """
  Stores a permission payload and records `permission_requested`. Recording
  the same engine permission id twice returns the existing row, so
  reconciliation after a reconnect is safe. With `reopen: true` (the engine
  still lists the prompt on replay) a row resolved or detached locally becomes
  a pending, attached card again.
  """
  def record(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    case attrs[:opencode_permission_id] && get_by_opencode_id(attrs[:opencode_permission_id]) do
      %PermissionRequest{} = existing ->
        if opts[:reopen] && (existing.status != "pending" or existing.detached_at),
          do: reopen(existing),
          else: {:ok, existing}

      _ ->
        Multi.new()
        |> Multi.insert(:request, PermissionRequest.changeset(%PermissionRequest{}, attrs))
        |> Timeline.multi_record(:event, &requested_event/1)
        |> commit()
    end
  end

  defp reopen(request) do
    Multi.new()
    |> Multi.update(
      :request,
      PermissionRequest.changeset(request, %{
        status: "pending",
        resolved_at: nil,
        detached_at: nil
      })
    )
    |> Timeline.multi_record(:event, &requested_event/1)
    |> commit()
  end

  defp requested_event(%{request: r}) do
    payload = %{
      "permission" => r.permission,
      "patterns" => r.patterns,
      "opencode_permission_id" => r.opencode_permission_id
    }

    # Codex: what the agent wants to do, for the timeline line's verb; other
    # engines' cards have none, and their events carry no key for it
    payload =
      case (r.metadata || %{})["action"] do
        nil -> payload
        action -> Map.put(payload, "action", action)
      end

    %{
      channel_id: r.channel_id,
      agent_id: agent_id_of(r),
      event_type: "permission_requested",
      ref_id: r.id,
      payload: payload
    }
  end

  @doc """
  Resolves a pending request with `:once`, `:always`, `:global`, or `:reject`
  and records the event. `:global` also grants the tool to the agent
  (`Canopy.GlobalPermissions`) in the same transaction, and the event names
  the grant; it is `{:error, :not_grantable}` or `{:error, :no_agent}` when
  no grant can be made. `delivered: "message"` with `message_id:` records that
  the approval was posted to the channel as a message mentioning the agent,
  because it had stopped waiting.
  """
  def resolve(request, reply, opts \\ [])

  def resolve(%PermissionRequest{} = request, reply, opts) when reply in [:global, "global"] do
    case grant_check(request) do
      {:ok, agent_id} ->
        Multi.new()
        |> GlobalPermissions.grant_multi(agent_id, request.permission,
          channel_id: request.channel_id
        )
        |> resolve_multi(request, reply, opts)
        |> commit()

      error ->
        error
    end
  end

  def resolve(%PermissionRequest{} = request, reply, opts),
    do: Multi.new() |> resolve_multi(request, reply, opts) |> commit()

  @doc """
  Whether Allow globally can grant this request's tool: `{:ok, agent_id}`,
  `{:error, :not_grantable}`, or `{:error, :no_agent}`.
  """
  def grant_check(%PermissionRequest{} = request) do
    cond do
      not GlobalPermissions.grantable?(request.permission) -> {:error, :not_grantable}
      agent_id = agent_id_of(request) -> {:ok, agent_id}
      true -> {:error, :no_agent}
    end
  end

  defp resolve_multi(multi, request, reply, opts) do
    multi
    |> Multi.update(
      :request,
      PermissionRequest.changeset(request, %{
        status: status_for(reply),
        resolved_at: DateTime.utc_now()
      })
    )
    |> Timeline.multi_record(:event, fn %{request: r} = changes ->
      payload =
        %{"permission" => r.permission, "status" => r.status}
        |> Map.merge(%{
          "delivered" => opts[:delivered],
          "message_id" => opts[:message_id],
          "grant_id" => changes[:grant] && changes.grant.id,
          "action" => (r.metadata || %{})["action"]
        })
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      %{
        channel_id: r.channel_id,
        agent_id: agent_id_of(r),
        event_type: "permission_resolved",
        ref_id: r.id,
        payload: payload
      }
    end)
  end

  @doc """
  Resolves a pending request the agent's grant now covers (another card was
  answered Allow globally) with status `"auto"`. It records the grant's use
  and a channel-level `permission_auto_approved` line naming the request, in
  the request's channel, with no `permission_resolved`.
  """
  def auto_resolve(%PermissionRequest{} = request, %GlobalPermissions.Grant{} = grant) do
    Multi.new()
    |> Multi.update(
      :request,
      PermissionRequest.changeset(request, %{status: "auto", resolved_at: DateTime.utc_now()})
    )
    |> GlobalPermissions.use_multi(grant, %{
      channel_id: request.channel_id,
      agent_id: grant.agent_id,
      permission: request.permission,
      patterns: request.patterns,
      request_id: request.id
    })
    |> commit()
  end

  @doc """
  Pending requests of the agent's sessions for `tool` (matched like a grant,
  ignoring case) that the agent still waits on, in every channel, leaving out
  once-only cards (no grant answers those). Options:
  `:channel_id` keeps one channel's.
  """
  def waiting_for_agent_tool(agent_id, tool, opts \\ []) do
    key = GlobalPermissions.normalize(tool)

    from(p in PermissionRequest,
      join: s in assoc(p, :agent_session),
      where: s.agent_id == ^agent_id and p.status == "pending" and is_nil(p.detached_at),
      where: fragment("lower(trim(?))", p.permission) == ^key,
      order_by: [asc: p.id],
      preload: ^@preloads
    )
    |> then(fn q ->
      if cid = opts[:channel_id], do: where(q, [p], p.channel_id == ^cid), else: q
    end)
    |> Repo.all()
    # a once-only card (a Codex plan agent's command) is never answered by a grant
    |> Enum.reject(&(get_in(&1.metadata || %{}, ["once_only"]) == true))
  end

  @doc """
  Marks a pending request as no longer waited on and records
  `permission_detached`. The card stays pending; a request that is already
  detached or resolved is returned unchanged.
  """
  def detach(%PermissionRequest{status: "pending", detached_at: nil} = request) do
    Multi.new()
    |> Multi.update(
      :request,
      PermissionRequest.changeset(request, %{detached_at: DateTime.utc_now()})
    )
    |> Timeline.multi_record(:event, fn %{request: r} ->
      %{
        channel_id: r.channel_id,
        agent_id: agent_id_of(r),
        event_type: "permission_detached",
        ref_id: r.id,
        payload: %{"permission" => r.permission, "patterns" => r.patterns}
      }
    end)
    |> commit()
  end

  def detach(%PermissionRequest{} = request), do: {:ok, request}

  def pending_for_channel(channel_id) do
    Repo.all(
      from p in PermissionRequest,
        where: p.channel_id == ^channel_id and p.status == "pending",
        order_by: [asc: p.id],
        preload: ^@preloads
    )
  end

  @doc "Pending requests an agent session is still waiting on (not detached)."
  def waiting_for_session(agent_session_id) do
    Repo.all(
      from p in PermissionRequest,
        where:
          p.agent_session_id == ^agent_session_id and p.status == "pending" and
            is_nil(p.detached_at),
        order_by: [asc: p.id],
        preload: ^@preloads
    )
  end

  @doc """
  Pending permission prompts agents on `engine` still wait on (not detached),
  in every channel of the repository, with their sessions preloaded.
  """
  def waiting_in_repository(repository_id, engine) do
    Repo.all(
      from p in PermissionRequest,
        join: c in assoc(p, :channel),
        join: s in assoc(p, :agent_session),
        where: c.repository_id == ^repository_id and s.engine == ^engine,
        where: p.status == "pending" and is_nil(p.detached_at),
        order_by: [asc: p.id],
        preload: ^@preloads
    )
  end

  @doc """
  Pending permission prompts per open channel id that still need the user, for
  the sidebar: every attached card, and detached ones younger than `fresh_since`.
  """
  def pending_counts(%DateTime{} = fresh_since) do
    from(p in PermissionRequest,
      join: c in assoc(p, :channel),
      where: p.status == "pending" and c.status != "archived",
      where: is_nil(p.detached_at) or p.detached_at > ^fresh_since,
      group_by: p.channel_id,
      select: {p.channel_id, count(p.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp status_for(:once), do: "once"
  defp status_for(:always), do: "always"
  defp status_for(:reject), do: "rejected"
  defp status_for(:global), do: "global"
  defp status_for("once"), do: "once"
  defp status_for("always"), do: "always"
  defp status_for("global"), do: "global"
  defp status_for("reject"), do: "rejected"
  defp status_for("rejected"), do: "rejected"

  @doc "The id of the agent whose session made the request, or nil."
  def agent_id_of(request) do
    case Repo.preload(request, :agent_session).agent_session do
      %{agent_id: agent_id} -> agent_id
      _ -> nil
    end
  end

  # A grant made (:grant) or used (:use) changes the agent page's list too.
  defp commit(multi) do
    case Repo.transaction(multi) do
      {:ok, %{request: request, event: event} = changes} ->
        Timeline.broadcast(event)

        if Map.has_key?(changes, :grant) or Map.has_key?(changes, :use),
          do: GlobalPermissions.notify(event.agent_id)

        {:ok, Repo.preload(request, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end
end
