defmodule Canopy.Engine do
  @moduledoc """
  The execution engine contract: what the channel runtime needs from the
  harness that runs an agent's session (OpenCode today, Claude Code next).

  An engine owns the private session of each agent in a channel. Canopy asks it
  to start sessions, send prompts, abort, compact, answer permission and
  question prompts, and (optionally) read a session's history back as a
  transcript, and listens for the normalized `Canopy.Engine.Event`s it
  broadcasts on the topics below. Everything else (routing, prompts, activity
  cards, costs, the MCP tools) is engine-neutral.

  Adapters are looked up by the `engine` name stored on agents and sessions,
  through `config :canopy, :engines`. Per-channel adapter state (an MCP
  registration memo, client options) is opaque to the runtime: `attach/2`
  creates it, the runtime hands it back on every call that needs it.

  Events travel on `Phoenix.PubSub` as `{:engine_event, %Canopy.Engine.Event{}}`:
  on `"engine:session:<id>"` when the event carries an engine session id, else
  on `"engine:repository:<id>"`. An engine whose event source reconnects
  broadcasts `{:engine_stream, :connected, repository_id}` on the repository
  topic so the runtime can reconcile.
  """

  alias Canopy.Engine.Event

  @type ctx :: %{
          repository: Canopy.Repositories.Repository.t(),
          channel: Canopy.Channels.Channel.t()
        }
  @type engine_state :: map()
  @type session :: Canopy.AgentSessions.AgentSession.t()
  @type agent :: Canopy.Agents.Agent.t()

  @typedoc """
  What to send: the wake text, the system text Canopy assembled for this turn,
  and the attachment plan (documents already materialised under the repository,
  each marked `:part` to ride along in the prompt or `:path` to be read from disk).
  """
  @type prompt :: %{
          text: String.t(),
          system: String.t(),
          attachments: [{Canopy.Documents.Document.t(), :part | :path}]
        }

  @typedoc """
  The engine's own view, for the turn watchdog: which engine sessions are busy,
  which of those are stuck retrying a failing model call (with the engine's
  message and attempt count), and the permission and question prompts still
  open, as `:approval_required` / `:question_required` events whose data
  carries `replay: true`. `:unknown` when the engine could not answer.
  """
  @type retrying :: %{
          session_id: String.t(),
          message: String.t() | nil,
          attempt: non_neg_integer() | nil
        }
  @type reconciliation :: %{
          busy: [String.t()] | :unknown,
          retrying: [retrying] | :unknown,
          permissions: [Event.t()] | :unknown,
          questions: [Event.t()] | :unknown
        }

  @doc "The engine's name, as stored in `agents.engine` and `agent_sessions.engine`."
  @callback name() :: String.t()

  @doc "Called when a channel process starts (or moves repository); returns the adapter's state."
  @callback attach(ctx, opts :: keyword()) :: engine_state

  @doc "Something the adapter may have memoised is stale."
  @callback invalidate(engine_state, reason :: :stream_reconnected | :mcp_token_rotated) ::
              engine_state

  @doc "Runs right before a prompt is sent (event source up, MCP registered, binary found)."
  @callback prepare(ctx, engine_state) :: engine_state

  @doc """
  Creates a session for the agent; `opts` may carry `title:`. Returns the
  attributes to store on the `agent_sessions` row:
  `engine_session_id`, plus whatever the engine needs later (`mcp_token`).
  """
  @callback create_session(ctx, engine_state, agent, opts :: keyword()) ::
              {:ok, %{required(:engine_session_id) => String.t(), optional(atom()) => term()}}
              | {:error, term()}

  @doc "Subscribes the caller to the session's events."
  @callback subscribe(session) :: :ok

  @doc "Sends a prompt; results arrive as events. Returns how many attachments rode along."
  @callback send_prompt(ctx, engine_state, session, agent, prompt) ::
              {:ok, %{attachments: non_neg_integer()}} | {:error, term()}

  @callback abort(ctx, engine_state, session) :: {:ok, term()} | {:error, term()}

  @doc """
  Compacts the session's history. `:ok` when it happened; `{:ok, :turn}` when the
  engine started a turn to do it (the runtime tracks that turn like any other);
  `{:error, :no_model}` when nothing can summarize.
  """
  @callback compact(ctx, engine_state, session, agent) :: :ok | {:ok, :turn} | {:error, term()}

  @doc "Answers a permission prompt. `{:error, :gone}` when the engine no longer holds it."
  @callback reply_permission(
              ctx,
              engine_state,
              Canopy.PermissionRequests.PermissionRequest.t(),
              :once | :always | :reject
            ) :: :ok | {:error, :gone} | {:error, term()}

  @doc """
  Answers a question. `{:error, :gone}` when the engine no longer holds it.
  `{:ok, :as_message}` when the engine could not take the answer in place (a
  free-text answer to a question that allows none): the adapter released the
  agent with a rejection, and the runtime delivers the answer as a new message.
  """
  @callback reply_question(
              ctx,
              engine_state,
              Canopy.QuestionRequests.QuestionRequest.t(),
              {:answered, [[String.t()]]} | :rejected
            ) :: :ok | {:ok, :as_message} | {:error, :gone} | {:error, term()}

  @callback reconcile(ctx, engine_state) :: reconciliation

  @doc """
  How the Costs page names the model an agent runs on: the effective model
  (`Canopy.Agents.effective_model/1`, the agent's own or its engine's default
  from Settings), so an inherited model and the same model chosen per agent
  share one label. The engine's own wording when neither is set.
  """
  @callback model_label(agent) :: String.t()

  @doc "Context (tokens per model call) above which a session is compacted after its turn."
  @callback context_cap() :: pos_integer()

  @doc """
  The MCP servers this engine gives agents in a repository, for the
  repository page (`Canopy.MCP.Inventory`): what it loads, what is configured
  but not loaded, and live status where the engine reports one. Needs no
  channel: client options come from Settings. Everything returned is
  redacted through `Canopy.MCP.Redact`.
  """
  @callback mcp_inventory(Canopy.Repositories.Repository.t(), opts :: keyword()) ::
              {:ok, Canopy.MCP.Inventory.Engine.t()} | {:error, term()}

  @typedoc """
  A message for a turn in flight: like `t:prompt/0` (the text, the turn's
  system text, the attachment plan), plus `ref`, Canopy's id for this
  delivery (a plain UUID).
  """
  @type steer :: %{
          text: String.t(),
          system: String.t(),
          attachments: [{Canopy.Documents.Document.t(), :part | :path}],
          ref: String.t()
        }

  @doc """
  Delivers a message into the session's running turn; the engine hands it to
  the model at its next tool or step boundary, and the turn carries on.
  `confirms: true` when the adapter will report, just before the turn's
  terminal event, which refs the turn never consumed (`:prompts_unconsumed`);
  `false` when it cannot tell (they count as consumed). `{:error,
  :not_running}` when no turn is running (the runtime queues the wake
  instead); `{:error, :unsupported}` when the engine version cannot steer.
  The runtime checks for this callback with `function_exported?/3`: an engine
  without it never steers.
  """
  @callback steer(ctx, engine_state, session, steer) ::
              {:ok, %{confirms: boolean()}}
              | {:error, :not_running | :unsupported | term()}

  @typedoc """
  Which engine session to read a transcript from. Not an AgentSession: a
  reset session's row is gone, but the engine may still have it. `directory`
  is the repository path the session ran in, when known.
  """
  @type transcript_ref :: %{engine_session_id: String.t(), directory: String.t() | nil}

  @typedoc """
  One page of a transcript, oldest entry first. `before` reads the entries
  just older than the page (nil at the session's start); `after` reads what
  comes after its last entry (the same cursor again once the page is empty,
  so following a live session keeps its place); `newer?` says whether such
  entries exist now. Cursors are opaque strings. `system_prompts` is the
  system text the session ran with, a new entry each time it changed:
  `canopy` (Canopy's text) and `engine` (the engine's own sections, when it
  records them). `total` and `compactions` count the whole session.
  """
  @type transcript_page :: %{
          entries: [Canopy.Engine.TranscriptEntry.t()],
          before: String.t() | nil,
          after: String.t() | nil,
          newer?: boolean(),
          system_prompts: [
            %{at: DateTime.t() | nil, canopy: String.t() | nil, engine: [String.t()] | nil}
          ],
          total: non_neg_integer(),
          compactions: non_neg_integer()
        }

  @doc """
  Reads a page of the session's history from the engine's own store: every
  prompt, the model's text, tool calls with their results, steps, and
  compactions, as `Canopy.Engine.TranscriptEntry`s. `ctx` may be nil (the
  transcript page has no channel process). Options: `limit` (default 50),
  `before: cursor`, `after: cursor`, `around: {:message_id, id} | {:at,
  DateTime.t()}` with `fallback_at:` for an unknown message id, else the
  newest page. Strings come back unredacted: `Canopy.Transcripts` redacts.
  `{:error, :not_found}` when the engine no longer has the session,
  `{:error, :unreachable}` when it cannot be asked.
  """
  @callback transcript(ctx | nil, transcript_ref, opts :: keyword()) ::
              {:ok, transcript_page}
              | {:error, :not_found | :unreachable | :unsupported | term()}

  @optional_callbacks mcp_inventory: 2, steer: 4, transcript: 3

  # -- Dispatch ---------------------------------------------------------------

  @default_engines %{"opencode" => Canopy.Engine.OpenCode}

  @doc "Engine name => adapter module, from `config :canopy, :engines`."
  def engines, do: Application.get_env(:canopy, :engines, @default_engines)

  def names, do: engines() |> Map.keys() |> Enum.sort()

  def module!(name) when is_binary(name), do: Map.fetch!(engines(), name)

  @labels %{"opencode" => "OpenCode", "claude_code" => "Claude Code"}

  @doc "The engine's name as people read it (`\"Claude Code\"`)."
  def label(name) when is_binary(name), do: Map.get(@labels, name, name)

  @doc "The adapter for an agent or session (anything with an `engine` name)."
  def for(%{engine: name}), do: module!(name)

  @doc """
  Reads a transcript page through the named engine's adapter (see
  `c:transcript/3`); `{:error, :unsupported}` when the engine is unknown or
  its adapter cannot read history.
  """
  def transcript(name, ctx, ref, opts \\ []) do
    with {:ok, mod} <- Map.fetch(engines(), name),
         true <- Code.ensure_loaded?(mod) and function_exported?(mod, :transcript, 3) do
      mod.transcript(ctx, ref, opts)
    else
      _ -> {:error, :unsupported}
    end
  end

  # -- Events -----------------------------------------------------------------

  def repository_topic(repository_id), do: "engine:repository:#{repository_id}"
  def session_topic(session_id), do: "engine:session:#{session_id}"

  def subscribe_repository(repository_id),
    do: Phoenix.PubSub.subscribe(Canopy.PubSub, repository_topic(repository_id))

  def subscribe_session(session_id),
    do: Phoenix.PubSub.subscribe(Canopy.PubSub, session_topic(session_id))

  @doc """
  Broadcasts an event: on its session's topic when it names one, else on the
  repository topic. One topic each, so a runtime subscribed to both (the
  repository for sessionless events like OpenCode's `file.edited`, every
  session it owns for the rest) sees each event exactly once.
  """
  def broadcast_event(repository_id, %Event{} = event, pubsub \\ Canopy.PubSub) do
    topic =
      case event.session_id do
        nil -> repository_topic(repository_id)
        session_id -> session_topic(session_id)
      end

    Phoenix.PubSub.broadcast(pubsub, topic, {:engine_event, event})
  end

  def broadcast_connected(repository_id, pubsub \\ Canopy.PubSub) do
    Phoenix.PubSub.broadcast(
      pubsub,
      repository_topic(repository_id),
      {:engine_stream, :connected, repository_id}
    )
  end
end
