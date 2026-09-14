defmodule Canopy.Engine.Event do
  @moduledoc """
  A normalized execution event. Everything Canopy learns from an engine's
  execution stream (OpenCode's SSE feed, Claude Code's stream-json output) is
  reduced to one of these so the rest of the app never sees a wire format.

  `type` is one of:

    * `:agent_status`      data: `%{status: :idle | :busy | :retry, raw: map}`
    * `:agent_completed`   data: `%{}`
    * `:agent_error`       data: `%{error: map}`
    * `:session_updated`   data: `%{session: map}`
    * `:session_deleted`   data: `%{session: map}`
    * `:message_updated`   data: `%{message: map}`
    * `:turn_usage`        data: `%{message_id, cost, tokens, finish}` (assistant message completed)
    * `:tool_started`      data: `%{call_id, tool, status, input, title, message_id, part_id}`
    * `:tool_completed`    data: `%{call_id, tool, status: :ok | :error, input, title, output, error, metadata, time, message_id, part_id}`
    * `:text_done`         data: `%{message_id, part_id, text}`
    * `:part_delta`        data: `%{message_id, part_id, field, delta}` (resolved to `:text_delta` by the stream)
    * `:text_delta`        data: `%{message_id, part_id, delta}`
    * `:step_completed`    data: `%{message_id, reason, cost, tokens, snapshot}`
    * `:patch`             data: `%{message_id, hash, files}`
    * `:file_changed`      data: `%{path}`
    * `:diff`              data: `%{files: [map]}`
    * `:approval_required` data: `%{request: map}` (id, permission, patterns, metadata with diff, tool)
    * `:approval_resolved` data: `%{request_id, reply}`
    * `:question_required` data: `%{request: map}` (id, questions with options, tool)
    * `:question_resolved` data: `%{request_id, answers}`
    * `:question_rejected` data: `%{request_id}`

  `session_id` is the engine's own session id (`agent_sessions.engine_session_id`);
  `raw_type` names the wire event it came from, for debugging only.
  """

  @enforce_keys [:type, :data]
  defstruct [:type, :session_id, :raw_type, data: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          session_id: String.t() | nil,
          raw_type: String.t() | nil,
          data: map()
        }
end
