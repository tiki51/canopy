defmodule Canopy.PermissionRequests do
  @moduledoc "OpenCode permission prompts surfaced in the channel feed."

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
  Stores a `permission.asked` payload and records `permission_requested`.
  Recording the same OpenCode permission id twice returns the existing row, so
  reconciliation after a reconnect is safe.
  """
  def record(attrs) do
    attrs = Map.new(attrs)

    case attrs[:opencode_permission_id] && get_by_opencode_id(attrs[:opencode_permission_id]) do
      %PermissionRequest{} = existing ->
        {:ok, existing}

      _ ->
        Multi.new()
        |> Multi.insert(:request, PermissionRequest.changeset(%PermissionRequest{}, attrs))
        |> Timeline.multi_record(:event, fn %{request: r} ->
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
        end)
        |> commit()
    end
  end

  @doc "Resolves a pending request with `:once`, `:always`, or `:reject` and records the event."
  def resolve(%PermissionRequest{} = request, reply) do
    status = status_for(reply)

    Multi.new()
    |> Multi.update(
      :request,
      PermissionRequest.changeset(request, %{status: status, resolved_at: DateTime.utc_now()})
    )
    |> Timeline.multi_record(:event, fn %{request: r} ->
      %{
        channel_id: r.channel_id,
        agent_id: agent_id_of(r),
        event_type: "permission_resolved",
        ref_id: r.id,
        payload: %{"permission" => r.permission, "status" => r.status}
      }
    end)
    |> commit()
  end

  def pending_for_channel(channel_id) do
    Repo.all(
      from p in PermissionRequest,
        where: p.channel_id == ^channel_id and p.status == "pending",
        order_by: [asc: p.id],
        preload: ^@preloads
    )
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
