defmodule Canopy.Engine do
  @moduledoc """
  The execution engine contract: what the channel runtime needs from the
  harness that runs an agent's session (OpenCode today, Claude Code next).

  An engine owns the private session of each agent in a channel. Canopy asks it
  to start sessions, send prompts, abort, compact, and answer permission and
  question prompts, and listens for the normalized `Canopy.Engine.Event`s it
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
  and the permission and question prompts still open, as `:approval_required` /
  `:question_required` events. `:unknown` when the engine could not answer.
  """
  @type reconciliation :: %{
          busy: [String.t()] | :unknown,
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
  Creates a session for the agent; `opts` may carry `title:` and `parent:` (a
  session). Returns the attributes to store on the `agent_sessions` row:
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

  @callback reply_permission(
              ctx,
              engine_state,
              Canopy.PermissionRequests.PermissionRequest.t(),
              :once | :always | :reject
            ) :: :ok | {:error, term()}

  @doc "`{:error, :gone}` when the engine no longer holds the question."
  @callback reply_question(
              ctx,
              engine_state,
              Canopy.QuestionRequests.QuestionRequest.t(),
              {:answered, [[String.t()]]} | :rejected
            ) :: :ok | {:error, :gone} | {:error, term()}

  @callback reconcile(ctx, engine_state) :: reconciliation

  @doc "How the Costs page names the model an agent runs on."
  @callback model_label(agent) :: String.t()

  @doc "Context (tokens per model call) above which a session is compacted after its turn."
  @callback context_cap() :: pos_integer()

  # -- Dispatch ---------------------------------------------------------------

  @default_engines %{"opencode" => Canopy.Engine.OpenCode}

  @doc "Engine name => adapter module, from `config :canopy, :engines`."
  def engines, do: Application.get_env(:canopy, :engines, @default_engines)

  def names, do: engines() |> Map.keys() |> Enum.sort()

  def module!(name) when is_binary(name), do: Map.fetch!(engines(), name)

  @doc "The adapter for an agent or session (anything with an `engine` name)."
  def for(%{engine: name}), do: module!(name)

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
