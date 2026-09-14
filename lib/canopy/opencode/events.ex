defmodule Canopy.OpenCode.Events do
  @moduledoc """
  Normalizes raw OpenCode SSE events (decoded JSON maps) into `Canopy.Engine.Event`
  structs. Verified against OpenCode 1.18.11, which delivers tool and text telemetry
  through `message.part.updated` parts rather than the `session.next.*` events the
  OpenAPI spec advertises (see Phase 0 spike notes).

  `normalize/1` returns a list: empty for noise, usually one event, occasionally two.
  """

  alias Canopy.Engine.Event

  @spec normalize(map()) :: [Event.t()]
  def normalize(%{"type" => type} = raw) do
    props = Map.get(raw, "properties", %{})

    type
    |> do_normalize(props)
    |> List.wrap()
    |> Enum.map(fn %Event{} = event -> %Event{event | raw_type: type} end)
  end

  def normalize(_), do: []

  @doc "Extracts the OpenCode session id from a raw event, if it has one."
  def session_id(%{"properties" => props}) do
    props["sessionID"] ||
      get_in(props, ["info", "sessionID"]) ||
      get_in(props, ["part", "sessionID"]) ||
      get_in(props, ["info", "id"]) |> session_id_if_session(props)
  end

  def session_id(_), do: nil

  # session.updated carries the session itself under "info"
  defp session_id_if_session(id, %{"info" => %{"id" => id, "projectID" => _}}), do: id
  defp session_id_if_session(_, _), do: nil

  defp do_normalize("session.status", %{"sessionID" => sid, "status" => status}) do
    event(:agent_status, sid, %{status: status_atom(status), raw: status})
  end

  defp do_normalize("session.idle", %{"sessionID" => sid}), do: event(:agent_completed, sid, %{})

  defp do_normalize("session.error", %{"sessionID" => sid} = p),
    do: event(:agent_error, sid, %{error: Map.get(p, "error", %{})})

  defp do_normalize(type, %{"info" => %{"id" => sid} = info})
       when type in ["session.created", "session.updated"],
       do: event(:session_updated, sid, %{session: info})

  defp do_normalize("session.deleted", %{"info" => %{"id" => sid} = info}),
    do: event(:session_deleted, sid, %{session: info})

  defp do_normalize("message.updated", %{"info" => %{"sessionID" => sid} = info}) do
    base = event(:message_updated, sid, %{message: info})

    case info do
      %{"role" => "assistant", "cost" => cost, "time" => %{"completed" => _}} ->
        [
          base,
          event(:turn_usage, sid, %{
            message_id: info["id"],
            cost: cost,
            tokens: Map.get(info, "tokens", %{}),
            finish: Map.get(info, "finish")
          })
        ]

      _ ->
        base
    end
  end

  defp do_normalize("message.part.updated", %{"part" => %{"sessionID" => sid} = part}),
    do: part_event(part, sid)

  defp do_normalize("message.part.delta", %{"sessionID" => sid} = p) do
    event(:part_delta, sid, %{
      message_id: p["messageID"],
      part_id: p["partID"],
      field: p["field"],
      delta: p["delta"]
    })
  end

  defp do_normalize("file.edited", %{"file" => path}),
    do: event(:file_changed, nil, %{path: path})

  defp do_normalize("session.diff", %{"sessionID" => sid} = p),
    do: event(:diff, sid, %{files: Map.get(p, "diff", [])})

  defp do_normalize("permission.asked", %{"sessionID" => sid} = request),
    do: event(:approval_required, sid, %{request: request})

  defp do_normalize("permission.replied", %{"sessionID" => sid} = p),
    do: event(:approval_resolved, sid, %{request_id: p["requestID"], reply: p["reply"]})

  # OpenCode ships the question tool under both an original and a "v2" event
  # name; the payloads are identical, so both normalize to the same event.
  defp do_normalize(type, %{"sessionID" => sid} = request)
       when type in ["question.asked", "question.v2.asked"],
       do: event(:question_required, sid, %{request: request})

  defp do_normalize(type, %{"sessionID" => sid} = p)
       when type in ["question.replied", "question.v2.replied"],
       do:
         event(:question_resolved, sid, %{
           request_id: p["requestID"],
           answers: Map.get(p, "answers", [])
         })

  defp do_normalize(type, %{"sessionID" => sid} = p)
       when type in ["question.rejected", "question.v2.rejected"],
       do: event(:question_rejected, sid, %{request_id: p["requestID"]})

  defp do_normalize(_type, _props), do: []

  defp part_event(%{"type" => "tool"} = part, sid) do
    state = Map.get(part, "state", %{})
    status = Map.get(state, "status")

    common = %{
      call_id: part["callID"],
      tool: part["tool"],
      input: Map.get(state, "input", %{}),
      title: Map.get(state, "title"),
      message_id: part["messageID"],
      part_id: part["id"]
    }

    case status do
      s when s in ["pending", "running"] ->
        event(:tool_started, sid, Map.put(common, :status, String.to_atom(s)))

      "completed" ->
        event(
          :tool_completed,
          sid,
          Map.merge(common, %{
            status: :ok,
            output: Map.get(state, "output"),
            error: nil,
            metadata: Map.get(state, "metadata", %{}),
            time: Map.get(state, "time", %{})
          })
        )

      "error" ->
        event(
          :tool_completed,
          sid,
          Map.merge(common, %{
            status: :error,
            output: nil,
            error: Map.get(state, "error"),
            metadata: Map.get(state, "metadata", %{}),
            time: Map.get(state, "time", %{})
          })
        )

      _ ->
        []
    end
  end

  defp part_event(%{"type" => "text", "time" => %{"end" => _}} = part, sid) do
    event(:text_done, sid, %{
      message_id: part["messageID"],
      part_id: part["id"],
      text: part["text"]
    })
  end

  defp part_event(%{"type" => "step-finish"} = part, sid) do
    event(:step_completed, sid, %{
      message_id: part["messageID"],
      part_id: part["id"],
      reason: part["reason"],
      cost: part["cost"],
      tokens: Map.get(part, "tokens", %{}),
      snapshot: part["snapshot"]
    })
  end

  defp part_event(%{"type" => "patch"} = part, sid) do
    event(:patch, sid, %{
      message_id: part["messageID"],
      part_id: part["id"],
      hash: part["hash"],
      files: Map.get(part, "files", [])
    })
  end

  defp part_event(_part, _sid), do: []

  defp event(type, sid, data), do: %Event{type: type, session_id: sid, data: data}

  defp status_atom(%{"type" => "idle"}), do: :idle
  defp status_atom(%{"type" => "busy"}), do: :busy
  defp status_atom(%{"type" => "retry"}), do: :retry
  defp status_atom(_), do: :busy
end
