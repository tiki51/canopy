defmodule Canopy.PermissionRequests do
  @moduledoc """
  Permission prompts surfaced in the channel feed, from either engine.

  Like a question, a pending prompt blocks the agent's turn while the engine
  holds the tool call open. When the agent stops waiting the card is
  *detached*: it stays pending, and a late approval reaches the agent as a new
  message (it cannot apply to the call that was waiting).
  """

  import Ecto.Query, warn: false

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
    %{
      channel_id: r.channel_id,
      agent_id: agent_id_of(r),
      event_type: "permission_requested",
      ref_id: r.id,
      payload: %{
        "permission" => r.permission,
        "patterns" => r.patterns,
        "opencode_permission_id" => r.opencode_permission_id
      }
    }
  end

  @doc """
  Resolves a pending request with `:once`, `:always`, or `:reject` and records
  the event. `delivered: "message"` with `message_id:` records that the
  approval was posted to the channel as a message mentioning the agent,
  because it had stopped waiting.
  """
  def resolve(%PermissionRequest{} = request, reply, opts \\ []) do
    status = status_for(reply)

    Multi.new()
    |> Multi.update(
      :request,
      PermissionRequest.changeset(request, %{status: status, resolved_at: DateTime.utc_now()})
    )
    |> Timeline.multi_record(:event, fn %{request: r} ->
      payload =
        %{"permission" => r.permission, "status" => r.status}
        |> Map.merge(%{"delivered" => opts[:delivered], "message_id" => opts[:message_id]})
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      %{
        channel_id: r.channel_id,
        agent_id: agent_id_of(r),
        event_type: "permission_resolved",
        ref_id: r.id,
        payload: payload
      }
    end)
    |> commit()
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
  defp status_for("once"), do: "once"
  defp status_for("always"), do: "always"
  defp status_for("reject"), do: "rejected"
  defp status_for("rejected"), do: "rejected"

  defp agent_id_of(request) do
    case Repo.preload(request, :agent_session).agent_session do
      %{agent_id: agent_id} -> agent_id
      _ -> nil
    end
  end

  defp commit(multi) do
    case Repo.transaction(multi) do
      {:ok, %{request: request, event: event}} ->
        Timeline.broadcast(event)
        {:ok, Repo.preload(request, @preloads, force: true)}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end
end
